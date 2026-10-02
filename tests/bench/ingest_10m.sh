#!/usr/bin/env bash
# A big migration through the annotation platform's own path (the
# acceptance test for routine bulk imports): REVS revisions (default
# 10,000,000: items and 1.5 boxes each) written as cid_writer in batches,
# each one transaction under the branch's shared write lock with its
# batch key in revision_batches, ids minted by the database. The server
# commits after every million, as a pipeline stage would.
#
# WORKERS writers (default 4) run at once, each on a connection of its
# own: the shared write lock lets writers proceed together, and only a
# commit waits for them. Each streams its share of the batches through
# one psql session, as an importer holding its connection would.
#
# Each batch is one statement that writes only if its key is new (the
# pattern the platform should use): stop the import at any point and run
# it again, and the batches already written are skipped, nothing lands
# twice, and it carries on from where it stopped.
#
# Needs: docker compose -f docker-compose.test.yml up -d --wait, and a
# build. From the repository root:
#   tests/bench/ingest_10m.sh                       # 10M revisions
#   REVS=500000 WORKERS=2 tests/bench/ingest_10m.sh # a smaller run
set -euo pipefail

REVS=${REVS:-10000000}
BATCH=${BATCH:-50000}                # revisions per transaction
WORKERS=${WORKERS:-4}
COMMIT_EVERY=${COMMIT_EVERY:-1000000}
NAME=${NAME:-bench/datasets/ingest-$REVS}
PORT=${PORT:-7180}
CID=${CID:-./zig-out/bin/cid}
TOKEN=bench-token
export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'
export CID_S3_ENDPOINT=http://127.0.0.1:8333 CID_S3_ACCESS_KEY=cid-test-key CID_S3_SECRET_KEY=cid-test-secret
export CID_TOKEN=$TOKEN CID_BROWSE_DIR=/tmp/cid-bench-ingest
AUTH="Authorization: Bearer $TOKEN"
API=http://127.0.0.1:$PORT/v0/datasets/$NAME/-
psql() { docker compose -f docker-compose.test.yml exec -T timescaledb psql -qtA -U cid -d cid_test -v ON_ERROR_STOP=1 "$@"; }
PROGRESS=$(mktemp -d)

"$CID" admin serve --port "$PORT" >/tmp/cid-bench-ingest.log 2>&1 &
SERVE=$!
WORKER_PIDS=()
cleanup() {
  for p in "${WORKER_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  kill "$SERVE" 2>/dev/null || true; wait "$SERVE" 2>/dev/null || true
  rm -rf "$PROGRESS"
}
trap cleanup EXIT
for _ in $(seq 100); do curl -sf "http://127.0.0.1:$PORT/v0/ping" >/dev/null && break; sleep 0.1; done

if [ -z "$(psql -c "SELECT 1 FROM datasets WHERE name = '$NAME'")" ]; then
  curl -sf -H "$AUTH" -H 'content-type: application/json' -X POST "http://127.0.0.1:$PORT/v0/datasets" \
    -d "{\"name\":\"$NAME\",\"kind\":\"annotated\",\"git_url\":\"g@h:ingest.git\"}" >/dev/null
fi
DS=$(psql -c "SELECT dataset_id FROM datasets WHERE name = '$NAME'")

# Each batch: BATCH revisions, 2 of every 5 an item, 3 a box on one.
# Annotation ids are UUIDv7, time-ordered, as the platform mints them: the
# (dataset, branch, annotation_id) index then grows at its end. Random ids
# would land all over a large index (7.7 s a batch against 0.95 at 10M).
ITEMS=$((BATCH * 2 / 5))
BATCHES=$(((REVS + BATCH - 1) / BATCH))
done_before=$(psql -c "SELECT count(*) FROM revision_batches WHERE dataset_id = '$DS' AND batch_key LIKE 'ingest-%'")
[ "$done_before" -gt 0 ] && echo "Resuming: $done_before of $BATCHES batches already written."

# One batch: the key, the items and their boxes in a single statement. If
# the key is already there (written by an earlier, interrupted run) the
# statement writes nothing at all.
batch_sql() {
  local b=$1 lo=$(($1 * ITEMS)) hi=$(($1 * ITEMS + ITEMS - 1))
  cat <<SQL
BEGIN;
SELECT pg_advisory_xact_lock_shared(hashtextextended('$DS' || '/main', 0));
SET LOCAL ROLE cid_writer;
WITH fresh AS (
  INSERT INTO revision_batches (dataset_id, batch_key) VALUES ('$DS', 'ingest-$b') ON CONFLICT DO NOTHING RETURNING 1
), items AS (
  INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, split, author)
  SELECT '$DS', 'main', 'cam' || (i % 50) || '/' || lpad(i::text, 9, '0') || '.jpg', 'add',
         md5('$DS/' || i)::uuid, sha256(convert_to('$DS/' || i, 'UTF8')),
         CASE WHEN i % 10 = 0 THEN 'val' ELSE 'train' END, 'agent:import'
  FROM generate_series($lo, $hi) i WHERE EXISTS (SELECT 1 FROM fresh)
)
INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver)
SELECT '$DS', 'main', cid_rev(), md5('$DS/' || i)::uuid, 'create', 'box',
       (ARRAY['person', 'car', 'truck', 'bike'])[1 + (i + k) % 4],
       jsonb_build_object('x', i % 600, 'y', k * 40, 'w', 32, 'h', 64), 'agent:import', 'policy-v1'
FROM generate_series($lo, $hi) i, generate_series(1, 2) k
WHERE (k = 1 OR i % 2 = 0) AND EXISTS (SELECT 1 FROM fresh);
COMMIT;
\\echo done $b
SQL
}

worker() { # this worker's share of the batches, through one connection
  local w=$1 b
  for ((b = w; b < BATCHES; b += WORKERS)); do batch_sql "$b"; done |
    psql >"$PROGRESS/$w" 2>"$PROGRESS/$w.err" || { echo "worker $w failed: $(cat "$PROGRESS/$w.err")" >&2; exit 1; }
}

commit() {
  local s=$(date +%s%N) out
  out=$(curl -s -o /tmp/cid-bench-commit -w '%{http_code}' -H "$AUTH" -H 'content-type: application/json' -X POST "$API/commit" \
    -d '{"branch":"main","message":"import stage","author":"agent:import"}')
  printf '\n  commit: HTTP %s in %d ms\n' "$out" $((($(date +%s%N) - s) / 1000000))
}

start=$(date +%s%N)
for w in $(seq 0 $((WORKERS - 1))); do worker "$w" & WORKER_PIDS+=($!); done

# Progress: batches finished across the workers, once a second; a server
# commit each time another COMMIT_EVERY revisions are in.
next_commit=$COMMIT_EVERY
while :; do
  n=$(cat "$PROGRESS"/[0-9]* 2>/dev/null | grep -c '^done' || true)
  secs=$((($(date +%s%N) - start) / 1000000000))
  rate=$((n * BATCH / (secs > 0 ? secs : 1)))
  eta='-'; [ "$rate" -gt 0 ] && eta="~$(((BATCHES - n) * BATCH / rate))s"
  printf '\r  %d/%d batches  %d revisions  %ds elapsed  %d/s  %s left   ' "$n" "$BATCHES" $((n * BATCH)) "$secs" "$rate" "$eta"
  if [ $((n * BATCH)) -ge "$next_commit" ] && [ "$n" -lt "$BATCHES" ]; then commit; next_commit=$((next_commit + COMMIT_EVERY)); fi
  alive=0; for p in "${WORKER_PIDS[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
  [ "$alive" -eq 0 ] && break
  sleep 1
done
for p in "${WORKER_PIDS[@]}"; do wait "$p"; done
commit
total=$((($(date +%s%N) - start) / 1000000000))
echo "Done: $REVS revisions in ${total}s with $WORKERS workers."
psql -c "SELECT 'rows: ' || (SELECT count(*) FROM item_revisions WHERE dataset_id = '$DS') || ' items, ' || (SELECT count(*) FROM annotation_revisions WHERE dataset_id = '$DS') || ' boxes, ' || (SELECT count(*) FROM commits WHERE dataset_id = '$DS') || ' commits'"
