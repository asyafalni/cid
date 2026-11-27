#!/bin/sh
# cid's exports loaded by the real FiftyOne (tests/fiftyone_requirements.txt):
# an annotated dataset is seeded the platform's way, cloned as yolo, coco and
# voc with the CLI, and tests/fiftyone_client.py loads each folder as a person
# would (docs/roadmap.md, E5).
#
# Needs: docker compose -f docker-compose.test.yml up -d --wait, `zig build`,
# and Python with tests/fiftyone_requirements.txt installed (PYTHON, default
# python3). FiftyOne keeps its datasets in MongoDB: FIFTYONE_DATABASE_URI
# names one, else this starts a throwaway one in docker and removes it.
# From the repository root:  sh tests/fiftyone_client.sh
# Seeding is skipped for what already exists, so it can run again.
set -eu
CID=${CID:-$(pwd)/zig-out/bin/cid}
PYTHON=${PYTHON:-python3}
PORT=${PORT:-7193}
TOKEN=fiftyone-client-token
FIXTURES=$(pwd)/tests/fixtures
DATASET=fo/datasets/boxes
export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'
export CID_S3_ENDPOINT=http://127.0.0.1:8333 CID_S3_ACCESS_KEY=cid-test-key CID_S3_SECRET_KEY=cid-test-secret
export CID_TOKEN=$TOKEN CID_SERVER=http://127.0.0.1:$PORT
WORK=$(mktemp -d)
export CID_BROWSE_DIR=$WORK/browse CID_WORK_DIR=$WORK/work XDG_CACHE_HOME=$WORK/cache
mkdir -p "$WORK/work"
psql() { docker compose -f docker-compose.test.yml exec -T timescaledb psql -qtA -U cid -d cid_test -v ON_ERROR_STOP=1 "$@"; }
api() { curl -sf -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' "$@"; }

MONGO=
"$CID" admin migrate >/dev/null
"$CID" admin serve --port "$PORT" >"$WORK/serve.log" 2>&1 &
SERVE=$!
trap 'kill $SERVE 2>/dev/null; [ -n "$MONGO" ] && docker rm -f "$MONGO" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
for _ in $(seq 100); do curl -sf "$CID_SERVER/v0/ping" >/dev/null && break; sleep 0.1; done

# An annotated dataset, the platform's way: bytes through the server, then
# revisions in the database, then a commit and a release through the API.
# Two frames of the same 4 x 3 picture, one in train and one in val, each
# with one person box.
if ! api "$CID_SERVER/v0/datasets/$DATASET/-/releases" 2>/dev/null | grep -q '"v1.0.0"'; then
  # Already there when an earlier run stopped before its release: go on.
  api -X POST "$CID_SERVER/v0/datasets" -d "{\"name\":\"$DATASET\",\"kind\":\"annotated\",\"git_url\":\"g@h:fo-boxes.git\"}" >/dev/null || true
  HASH=$("$CID" hash-object "$FIXTURES/pixels.png")
  SIZE=$(wc -c < "$FIXTURES/pixels.png" | tr -d ' ')
  URL=$(api -X POST "$CID_SERVER/v0/datasets/$DATASET/-/check-hashes" -d "{\"hashes\":[\"$HASH\"]}" |
    "$PYTHON" -c 'import json,sys; m=json.load(sys.stdin)["missing"]; print(m[0]["url"] if m else "")')
  [ -n "$URL" ] && curl -sf -X PUT --data-binary "@$FIXTURES/pixels.png" "$URL" >/dev/null
  api -X POST "$CID_SERVER/v0/datasets/$DATASET/-/register-items" \
    -d "{\"items\":[{\"hash\":\"$HASH\",\"size\":$SIZE,\"media_type\":\"image/png\",\"width\":4,\"height\":3}]}" >/dev/null
  psql <<SQL
WITH d AS (SELECT dataset_id FROM datasets WHERE name = '$DATASET'),
     it AS (SELECT gen_random_uuid() AS item_id, p, s FROM (VALUES ('frames/a.png', 'train'), ('frames/b.png', 'val')) v(p, s)),
     items AS (INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, split, author)
       SELECT d.dataset_id, 'main', it.p, 'add', it.item_id, decode('$HASH', 'hex'), it.s, 'agent:annotator' FROM d, it RETURNING item_id),
     owned AS (INSERT INTO dataset_items (item_id, dataset_id) SELECT items.item_id, d.dataset_id FROM items, d)
INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver)
  SELECT d.dataset_id, 'main', gen_random_uuid(), items.item_id, 'create', 'box', 'person', '{"x":1,"y":1,"w":2,"h":1}'::jsonb, 'agent:annotator', 'p1'
  FROM d, items;
SQL
  api -X POST "$CID_SERVER/v0/datasets/$DATASET/-/commit" -d '{"message":"two frames","author":"agent:annotator"}' >/dev/null
  api -X POST "$CID_SERVER/v0/datasets/$DATASET/-/tag" -d '{"name":"v1.0.0"}' >/dev/null
fi

# The same release, cloned in each format a person would hand to FiftyOne.
for format in yolo coco voc; do
  mkdir -p "$WORK/$format"
  (cd "$WORK/$format" && "$CID" clone "cid@127.0.0.1:$DATASET" --release v1.0.0 --format "$format" >/dev/null)
done

if [ -z "${FIFTYONE_DATABASE_URI:-}" ]; then
  MONGO=cid-fiftyone-test-mongo
  docker rm -f "$MONGO" >/dev/null 2>&1 || true
  docker run -d --name "$MONGO" -p 127.0.0.1:27027:27017 mongo:7.0 >/dev/null
  export FIFTYONE_DATABASE_URI=mongodb://127.0.0.1:27027
  for _ in $(seq 100); do docker exec "$MONGO" mongosh --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1 && break; sleep 0.2; done
fi

FIFTYONE_DO_NOT_TRACK=true FIFTYONE_DEFAULT_DATASET_DIR=$WORK/fiftyone \
  "$PYTHON" -I "$(pwd)/tests/fiftyone_client.py" "$WORK/yolo/boxes" "$WORK/coco/boxes" "$WORK/voc/boxes"
