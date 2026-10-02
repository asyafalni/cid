#!/usr/bin/env bash
# Browse at 1M items, through the real server (CLAUDE.md, performance
# budgets; docs/dashboard.md, UX budgets). Seeds an annotated dataset of
# N items (default 1,000,000) with 1.5 boxes each straight into the test
# database, the way the annotation platform writes revisions, then
# commits and releases it through the API and times what the dashboard
# asks for: the release (manifest and browse index), then browse pages
# and their thumbnails.
#
# Needs: docker compose -f docker-compose.test.yml up -d --wait, and the
# server build (zig build -Dduckdb). From the repository root:
#   tests/bench/browse_1m.sh             # seed once, then measure
#   N=100000 tests/bench/browse_1m.sh    # a smaller run
# The dataset stays for reruns (and for a browser at /d/<name>).
set -euo pipefail

N=${N:-1000000}
NAME=${NAME:-bench/datasets/items-$N}
PORT=${PORT:-7179}
CID=${CID:-./zig-out/bin/cid}
BROWSE_DIR=${BROWSE_DIR:-/tmp/cid-bench-browse}
TOKEN=bench-token
export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'
export CID_S3_ENDPOINT=http://127.0.0.1:8333 CID_S3_ACCESS_KEY=cid-test-key CID_S3_SECRET_KEY=cid-test-secret
export CID_TOKEN=$TOKEN CID_BROWSE_DIR=$BROWSE_DIR
AUTH="Authorization: Bearer $TOKEN"
API=http://127.0.0.1:$PORT/v0/datasets/$NAME/-
psql() { docker compose -f docker-compose.test.yml exec -T timescaledb psql -qtA -U cid -d cid_test -v ON_ERROR_STOP=1 "$@"; }

start() { # a fresh server and an empty browse cache, so each phase's peak is its own
  rm -rf "$BROWSE_DIR"
  "$CID" admin serve --port "$PORT" >>/tmp/cid-bench-serve.log 2>&1 &
  SERVE=$!
  for _ in $(seq 100); do curl -sf "http://127.0.0.1:$PORT/v0/ping" >/dev/null && break; sleep 0.1; done
}
stop() { kill "$SERVE" 2>/dev/null || true; wait "$SERVE" 2>/dev/null || true; }
trap stop EXIT
: >/tmp/cid-bench-serve.log
peak() { awk '/VmHWM/ { printf "%.0f MB", $2 / 1024 }' "/proc/$SERVE/status"; }
timed() { # label, then curl arguments: wall time, size, status
  local label=$1; shift
  curl -s -o /tmp/cid-bench-body -w '%{http_code} %{time_total} %{size_download}\n' -H "$AUTH" "$@" |
    awk -v l="$label" '{ printf "  %-46s %6.0f ms %9d B  HTTP %s\n", l, $2 * 1000, $3, $1 }'
}
start
echo "Server started: peak memory $(peak)"
if [ -z "$(psql -c "SELECT 1 FROM datasets WHERE name = '$NAME'")" ]; then
  echo "Seeding $NAME: $N items, $((N * 3 / 2)) boxes"
  curl -sf -H "$AUTH" -H 'content-type: application/json' -X POST "http://127.0.0.1:$PORT/v0/datasets" \
    -d "{\"name\":\"$NAME\",\"kind\":\"annotated\",\"git_url\":\"g@h:bench.git\"}" >/dev/null
  s=$(date +%s%N)
  psql <<SQL
-- UUIDv7 revision ids: one millisecond a minute ago, then a counter, so
-- they order exactly as written.
CREATE FUNCTION pg_temp.rev(ms bigint, n bigint) RETURNS uuid LANGUAGE sql AS \$\$
  SELECT (substr(lpad(to_hex(ms), 12, '0'), 1, 8) || '-' || substr(lpad(to_hex(ms), 12, '0'), 9, 4)
          || '-7000-8000-' || lpad(to_hex(n), 12, '0'))::uuid \$\$;
CREATE TEMP TABLE at AS SELECT (extract(epoch FROM now()) * 1000)::bigint - 60000 AS ms,
  (SELECT dataset_id FROM datasets WHERE name = '$NAME') AS ds;
CREATE TEMP TABLE seed AS
  SELECT i, sha256(convert_to('$NAME/' || i, 'UTF8')) AS hash, gen_random_uuid() AS item_id,
         'cam' || (i % 50) || '/' || lpad(i::text, 8, '0') || '.jpg' AS path,
         CASE i % 10 WHEN 0 THEN 'val' WHEN 1 THEN 'test' ELSE 'train' END AS split
  FROM generate_series(1, $N) i;
INSERT INTO items (item_hash, size_bytes, media_type, meta)
  SELECT hash, 20000 + i % 50000, 'image/jpeg', '{"width":640,"height":480}' FROM seed;
-- Built thumbnails, as the worker would leave them (the bytes are not
-- there; presigning is what the page pays for).
INSERT INTO previews (item_hash, status) SELECT hash, 'done' FROM seed;
INSERT INTO dataset_items (item_id, dataset_id) SELECT item_id, at.ds FROM seed, at;
INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, split, author)
  SELECT pg_temp.rev(at.ms, i), to_timestamp(at.ms / 1000.0), at.ds, 'main', path, 'add', item_id, hash, split, 'agent:bench'
  FROM seed, at;
INSERT INTO annotation_revisions (rev_id, ts, dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver)
  SELECT pg_temp.rev(at.ms, $N + 2 * i + k), to_timestamp(at.ms / 1000.0), at.ds, 'main', gen_random_uuid(), item_id,
         'create', 'box', (ARRAY['person', 'car', 'truck'])[1 + (i + k) % 3],
         jsonb_build_object('x', 10 + k * 50, 'y', 20, 'w', 40, 'h', 30), 'agent:bench', 'p1'
  FROM seed, at, generate_series(0, 1) k WHERE k = 0 OR i % 2 = 0;
-- What autovacuum would have done by the time anyone browses.
ANALYZE items; ANALYZE item_revisions; ANALYZE annotation_revisions;
SQL
  echo "  seeded in $(( ($(date +%s%N) - s) / 1000000 )) ms"
  timed "commit (server, $N items)" -X POST -H 'content-type: application/json' "$API/commit" \
    -d '{"branch":"main","message":"bench","author":"agent:bench"}'
  timed "release v1 (manifest + browse index)" -X POST -H 'content-type: application/json' "$API/tag" -d '{"name":"v1"}'
  echo "  server peak memory so far: $(peak)"
fi

add_file() { # one more file and a commit that is no release; prints the commit
  local tag=$1
  psql >/dev/null <<SQL
INSERT INTO items (item_hash, size_bytes, media_type) VALUES (sha256(convert_to('$NAME/$tag', 'UTF8')), 5, 'text/plain');
WITH d AS (SELECT dataset_id FROM datasets WHERE name = '$NAME'), i AS (SELECT gen_random_uuid() AS id),
di AS (INSERT INTO dataset_items (item_id, dataset_id) SELECT i.id, d.dataset_id FROM i, d RETURNING item_id)
INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, author)
  SELECT (substr(lpad(to_hex(ms), 12, '0'), 1, 8) || '-' || substr(lpad(to_hex(ms), 12, '0'), 9, 4) || '-7fff-8fff-ffffffffffff')::uuid,
         now(), d.dataset_id, 'main', 'zz-$tag.txt', 'add', di.item_id, sha256(convert_to('$NAME/$tag', 'UTF8')), 'agent:bench'
  FROM d, di, (SELECT (extract(epoch FROM now()) * 1000)::bigint AS ms) t;
SQL
  curl -sf -H "$AUTH" -H 'content-type: application/json' -X POST "$API/commit" \
    -d "{\"branch\":\"main\",\"message\":\"$tag\",\"author\":\"agent:bench\"}" | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p'
}

RUN=$(date +%s)
echo "Release, fresh server (manifest streamed and hashed, browse index built and stored)"
stop; start
C=$(add_file "release-$RUN")
timed "release of $N items" -X POST -H 'content-type: application/json' "$API/tag" -d "{\"name\":\"r$RUN\",\"commit\":\"$C\"}"
echo "  server peak memory: $(peak)"

echo "Pages that read the head's statistics, fresh server"
stop; start
C=$(add_file "stats-$RUN")
timed "overview (statistics aggregated, first time)" "$API/overview"
timed "overview again (statistics kept)" "$API/overview"
timed "home listing" "http://127.0.0.1:$PORT/v0/datasets"
echo "  server peak memory: $(peak)"

echo "Browse an unreleased version, fresh server"
stop; start
C=$(add_file "browse-$RUN")
timed "first view: index built from history" "$API/browse?commit=$C&limit=120"
echo "  server peak memory: $(peak)"

echo "cid diff between two 1M-item versions (compared on the server), fresh server"
stop; start
C=$(add_file "diff-$RUN")
timed "version file, first time (written)" "$API/version/$C"
timed "version file again (kept)" "$API/version/$C"
echo "  server peak memory: $(peak)"
WS=$(mktemp -d)
mkdir "$WS/.cid"
printf '.{ .address = "cid@127.0.0.1:%s", .git_url = "g@h:bench.git", .kind = "annotated" }\n' "$NAME" >"$WS/.cid/config.zon"
for pass in first second; do
  (cd "$WS" && CID_SERVER="http://127.0.0.1:$PORT" /usr/bin/time -f "  cid diff v1 $pass time: %e s, client peak %M KB" \
    "$(realpath "$OLDPWD/$CID" 2>/dev/null || echo "$CID")" diff v1 "$C" 2>&1 >/dev/null | tail -1)
done
echo "  server peak memory: $(peak)"
rm -rf "$WS"

stop; start
COMMIT=$(curl -sf -H "$AUTH" "$API/releases" | sed -n 's/.*"name":"v1","commit":"\([^"]*\)".*/\1/p')
echo "Browse release v1 ($COMMIT), fresh server"
timed "first view, empty cache (index from storage)" "$API/browse?commit=$COMMIT&limit=120"
B="$API/browse?commit=$COMMIT&limit=120"
timed "unfiltered" "$B"
timed "split=val" "$B&split=val"
timed "class=truck" "$B&class=truck"
timed "path contains cam7/ + train + car" "$B&q=cam7%2F&split=train&class=car"
timed "type=.png (no match)" "$B&type=.png"
timed "deep page (after cam42/00500000.jpg)" "$B&after=cam42%2F00500000.jpg"
timed "open item + unfiltered page" "$B&item=cam7%2F00000007.jpg"
HASHES=$(curl -sf -H "$AUTH" "$B" | grep -o '"hash":"[0-9a-f]*"' | head -120 | sed 's/"hash"://' | paste -sd,)
timed "thumbs for the page (120 presigns)" -X POST -H 'content-type: application/json' "$API/thumbs" -d "{\"hashes\":[$HASHES]}"
echo "  server peak memory: $(peak)"
