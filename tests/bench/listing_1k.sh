#!/bin/sh
# The home page's listing and search at 1,000 datasets (docs/roadmap.md,
# U17): a database of its own (cid_bench, beside the test database, so
# the test data is left alone) is filled with DATASETS annotated datasets
# across twenty groups, each with four pictures that have thumbnails, two
# classes and a release; then the listing is timed and sized.
#
# Needs: docker compose -f docker-compose.test.yml up -d --wait, a
# ReleaseFast `zig build`, ffmpeg. From the repository root:
#   sh tests/bench/listing_1k.sh            # seed if needed, then measure
#   KEEP=1 sh tests/bench/listing_1k.sh     # leave the server up on PORT
# The browser's side (a keystroke to its results) is web/e2e/bench.spec.ts
# with BENCH_LISTING set to the server's address.
set -eu
CID=${CID:-$(pwd)/zig-out/bin/cid}
PORT=${PORT:-7195}
DATASETS=${DATASETS:-1000}
TOKEN=bench-listing-token
export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_bench'
export CID_S3_ENDPOINT=http://127.0.0.1:8333 CID_S3_ACCESS_KEY=cid-test-key CID_S3_SECRET_KEY=cid-test-secret
export CID_TOKEN=$TOKEN CID_SERVER=http://127.0.0.1:$PORT
WORK=$(mktemp -d)
export CID_BROWSE_DIR=$WORK/browse CID_WORK_DIR=$WORK/work
mkdir -p "$WORK/work"
compose() { docker compose -f docker-compose.test.yml "$@"; }
psql() { compose exec -T timescaledb psql -qtA -U cid -d cid_bench -v ON_ERROR_STOP=1 "$@"; }
api() { curl -sf -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' "$@"; }

compose exec -T timescaledb psql -qtA -U cid -d cid_test -c "SELECT 1 FROM pg_database WHERE datname = 'cid_bench'" | grep -q 1 ||
  compose exec -T timescaledb psql -q -U cid -d cid_test -c "CREATE DATABASE cid_bench"
"$CID" admin setup >/dev/null 2>&1 || true
"$CID" admin migrate >/dev/null

"$CID" admin serve --port "$PORT" >"$WORK/serve.log" 2>&1 &
SERVE=$!
trap '[ -n "${KEEP:-}" ] || kill $SERVE 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT
for _ in $(seq 100); do curl -sf "$CID_SERVER/v0/ping" >/dev/null && break; sleep 0.1; done

have=$(psql -c "SELECT count(*) FROM datasets")
if [ "$have" -lt "$DATASETS" ]; then
  echo "seeding $DATASETS datasets (have $have)"
  # Four pictures, uploaded once through the first dataset: content is
  # stored once, so every dataset holds the same four.
  hashes=""
  items=""
  first=bench/g00/datasets/d0000
  api -X POST "$CID_SERVER/v0/datasets" -d "{\"name\":\"$first\",\"kind\":\"annotated\",\"git_url\":\"g@h:bench.git\"}" >/dev/null 2>&1 || true
  for n in 1 2 3 4; do
    f="$WORK/p$n.png"
    ffmpeg -nostdin -loglevel error -f lavfi -i "testsrc2=size=320x240:rate=1" -vf "hue=h=$((n * 80))" -frames:v 1 -y "$f"
    h=$("$CID" hash-object "$f")
    size=$(wc -c < "$f" | tr -d ' ')
    url=$(api -X POST "$CID_SERVER/v0/datasets/$first/-/check-hashes" -d "{\"hashes\":[\"$h\"]}" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    [ -n "$url" ] && curl -sf -X PUT --data-binary "@$f" "$url" >/dev/null
    api -X POST "$CID_SERVER/v0/datasets/$first/-/register-items" \
      -d "{\"items\":[{\"hash\":\"$h\",\"size\":$size,\"media_type\":\"image/png\",\"width\":320,\"height\":240}]}" >/dev/null
    hashes="$hashes $h"
  done
  set -- $hashes
  i=0
  while [ "$i" -lt "$DATASETS" ]; do
    name=$(printf 'bench/g%02d/%s/d%04d' $((i % 20)) "$([ $((i % 7)) -eq 0 ] && echo sets || echo datasets)" "$i")
    api -X POST "$CID_SERVER/v0/datasets" -d "{\"name\":\"$name\",\"kind\":\"annotated\",\"git_url\":\"g@h:bench.git\"}" >/dev/null 2>&1 || true
    i=$((i + 1))
  done
  # Every dataset's items and boxes in one statement: four frames, each
  # with a box of one of two classes taken from thirty.
  psql <<SQL
WITH d AS (SELECT dataset_id, name, row_number() OVER (ORDER BY name) AS n FROM datasets
           WHERE NOT EXISTS (SELECT 1 FROM item_revisions r WHERE r.dataset_id = datasets.dataset_id)),
     h(k, hash) AS (VALUES (1, '$1'), (2, '$2'), (3, '$3'), (4, '$4')),
     it AS (SELECT d.dataset_id, d.n, h.k, gen_random_uuid() AS item_id, h.hash FROM d, h),
     items AS (INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, split, author)
       SELECT dataset_id, 'main', 'frames/' || k || '.png', 'add', item_id, decode(hash, 'hex'),
              CASE WHEN k = 4 THEN 'val' ELSE 'train' END, 'agent:bench' FROM it RETURNING 1),
     owned AS (INSERT INTO dataset_items (item_id, dataset_id) SELECT item_id, dataset_id FROM it RETURNING 1),
     held AS (INSERT INTO dataset_hashes (dataset_id, item_hash) SELECT dataset_id, decode(hash, 'hex') FROM it
              ON CONFLICT DO NOTHING RETURNING 1)
INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver)
  SELECT dataset_id, 'main', gen_random_uuid(), item_id, 'create', 'box',
         'class-' || lpad((((n + k) * 7) % 30)::text, 2, '0'), '{"x":40,"y":40,"w":120,"h":90}'::jsonb, 'agent:bench', 'p1'
  FROM it;
SQL
  i=0
  for name in $(psql -c "SELECT name FROM datasets d WHERE NOT EXISTS (SELECT 1 FROM commits c WHERE c.dataset_id = d.dataset_id) ORDER BY name"); do
    api -X POST "$CID_SERVER/v0/datasets/$name/-/commit" -d '{"message":"four frames","author":"agent:bench"}' >/dev/null
    [ $((i % 3)) -eq 0 ] || api -X POST "$CID_SERVER/v0/datasets/$name/-/tag" -d '{"name":"v1.0.0"}' >/dev/null
    i=$((i + 1))
    [ $((i % 200)) -eq 0 ] && echo "  $i committed"
  done
  "$CID" admin previews >/dev/null 2>&1 || true
fi

echo "datasets: $(psql -c "SELECT count(*) FROM datasets")"
# The listing, as the home page and every search box ask for it.
for run in 1 2 3 4 5; do
  curl -s -o "$WORK/listing.json" -w "listing $run: %{time_total} s, %{size_download} bytes\n" \
    -H "Authorization: Bearer $TOKEN" "$CID_SERVER/v0/datasets"
done
gzip -c "$WORK/listing.json" | wc -c | sed 's/^/listing gzipped: /; s/$/ bytes/'
[ -z "${KEEP:-}" ] || echo "server left up at $CID_SERVER (token $TOKEN, pid $SERVE)"
