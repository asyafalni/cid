#!/usr/bin/env bash
# A big migration through the annotation platform's own path (the
# acceptance test for routine bulk imports): REVS revisions (default
# 10,000,000: items and 1.5 boxes each) written as cid_writer in batches,
# each one transaction under the branch's shared write lock with its
# batch key in revision_batches, ids minted by the database. The server
# commits after every million, as a pipeline stage would.
#
# Prints progress per batch. Stop it at any point and run it again: the
# batches already written are skipped by their keys, nothing lands twice,
# and the import carries on from where it stopped.
#
# Needs: docker compose -f docker-compose.test.yml up -d --wait, and a
# build. From the repository root:
#   tests/bench/ingest_10m.sh               # 10M revisions
#   REVS=500000 tests/bench/ingest_10m.sh   # a smaller run
set -euo pipefail

REVS=${REVS:-10000000}
BATCH=${BATCH:-50000}                # revisions per transaction
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

"$CID" admin serve --port "$PORT" >/tmp/cid-bench-ingest.log 2>&1 &
SERVE=$!
trap 'kill $SERVE 2>/dev/null || true; wait $SERVE 2>/dev/null || true' EXIT
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
PER_COMMIT=$((COMMIT_EVERY / BATCH))
done_keys=$(psql -c "SELECT count(*) FROM revision_batches WHERE dataset_id = '$DS'")
[ "$done_keys" -gt 0 ] && echo "Resuming: $done_keys of $BATCHES batches already written."

commit() {
  local s=$(date +%s%N) out
  out=$(curl -s -o /tmp/cid-bench-commit -w '%{http_code}' -H "$AUTH" -H 'content-type: application/json' -X POST "$API/commit" \
    -d '{"branch":"main","message":"import stage","author":"agent:import"}')
  printf '  commit: HTTP %s in %d ms\n' "$out" $((($(date +%s%N) - s) / 1000000))
}

start=$(date +%s%N); written=0
for b in $(seq 0 $((BATCHES - 1))); do
  key="ingest-$b"
  if [ -z "$(psql -c "SELECT 1 FROM revision_batches WHERE dataset_id = '$DS' AND batch_key = '$key'")" ]; then
    lo=$((b * ITEMS)); hi=$((lo + ITEMS - 1))
    # A batch that committed after the check above (an interrupted run's
    # last transaction finishing) is refused by its key: already written.
    if ! out=$(psql 2>&1 >/dev/null <<SQL
BEGIN;
SELECT pg_advisory_xact_lock_shared(hashtextextended('$DS' || '/main', 0));
SET LOCAL ROLE cid_writer;
INSERT INTO revision_batches (dataset_id, batch_key) VALUES ('$DS', '$key');
INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, split, author)
  SELECT '$DS', 'main', 'cam' || (i % 50) || '/' || lpad(i::text, 9, '0') || '.jpg', 'add',
         md5('$DS/' || i)::uuid, sha256(convert_to('$DS/' || i, 'UTF8')),
         CASE WHEN i % 10 = 0 THEN 'val' ELSE 'train' END, 'agent:import'
  FROM generate_series($lo, $hi) i;
INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver)
  SELECT '$DS', 'main', cid_rev(), md5('$DS/' || i)::uuid, 'create', 'box',
         (ARRAY['person', 'car', 'truck', 'bike'])[1 + (i + k) % 4],
         jsonb_build_object('x', i % 600, 'y', k * 40, 'w', 32, 'h', 64), 'agent:import', 'policy-v1'
  FROM generate_series($lo, $hi) i, generate_series(1, 2) k
  WHERE k = 1 OR i % 2 = 0;
COMMIT;
SQL
    ); then
      case "$out" in *revision_batches_pkey*) ;; *) echo "$out" >&2; exit 1 ;; esac
    else
      written=$((written + BATCH))
    fi
  fi
  n=$((b + 1))
  now=$(date +%s%N); secs=$(((now - start) / 1000000000))
  rate=$((written / (secs > 0 ? secs : 1)))
  eta='-'; [ "$rate" -gt 0 ] && eta="~$(((BATCHES - n) * BATCH / rate))s"
  printf '\r  batch %d/%d  %d revisions  %ds elapsed  %d/s  %s left   ' "$n" "$BATCHES" $((n * BATCH)) "$secs" "$rate" "$eta"
  if [ $((n % PER_COMMIT)) -eq 0 ] || [ "$n" -eq "$BATCHES" ]; then echo; commit; fi
done
total=$(((($(date +%s%N) - start)) / 1000000000))
echo "Done: $REVS revisions in ${total}s ($written written by this run)."
psql -c "SELECT 'rows: ' || (SELECT count(*) FROM item_revisions WHERE dataset_id = '$DS') || ' items, ' || (SELECT count(*) FROM annotation_revisions WHERE dataset_id = '$DS') || ' boxes, ' || (SELECT count(*) FROM commits WHERE dataset_id = '$DS') || ' commits'"
