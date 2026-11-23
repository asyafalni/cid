#!/bin/sh
# The Hugging Face door read by the real clients (huggingface_hub and
# datasets, tests/hf_requirements.txt): a file dataset, an annotated one and
# a model are seeded the way people and the platform make them, then
# tests/hf_client.py reads them through HF_ENDPOINT, unchanged code.
#
# Needs: docker compose -f docker-compose.test.yml up -d --wait, `zig build`,
# and Python with tests/hf_requirements.txt installed (PYTHON, default
# python3). From the repository root:  sh tests/hf_client.sh
# Seeding is skipped for what already exists, so it can run again.
set -eu
CID=${CID:-$(pwd)/zig-out/bin/cid}
PYTHON=${PYTHON:-python3}
PORT=${PORT:-7192}
TOKEN=hf-client-token
FIXTURES=$(pwd)/tests/fixtures
export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'
export CID_S3_ENDPOINT=http://127.0.0.1:8333 CID_S3_ACCESS_KEY=cid-test-key CID_S3_SECRET_KEY=cid-test-secret
export CID_TOKEN=$TOKEN CID_SERVER=http://127.0.0.1:$PORT
WORK=$(mktemp -d)
export CID_BROWSE_DIR=$WORK/browse
psql() { docker compose -f docker-compose.test.yml exec -T timescaledb psql -qtA -U cid -d cid_test -v ON_ERROR_STOP=1 "$@"; }
api() { curl -sf -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' "$@"; }

"$CID" admin migrate >/dev/null
"$CID" admin serve --port "$PORT" >"$WORK/serve.log" 2>&1 &
SERVE=$!
trap 'kill $SERVE 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 100); do curl -sf "$CID_SERVER/v0/ping" >/dev/null && break; sleep 0.1; done
has() { api "$CID_SERVER/v0/datasets/$1/-/releases" 2>/dev/null | grep -q '"v1.0.0"'; }

# A file dataset, pushed with the CLI: two tables, a split each.
if ! has hf/datasets/clients-files; then
  mkdir -p "$WORK/files/data" && cp "$FIXTURES/people.csv" "$WORK/files/data/train.csv" && cp "$FIXTURES/people.csv" "$WORK/files/data/test.csv"
  (cd "$WORK/files" && "$CID" init "cid@127.0.0.1:hf/datasets/clients-files" --git g@h:hf-files.git >/dev/null &&
    "$CID" add . >/dev/null && "$CID" commit -m "two tables" >/dev/null && "$CID" push >/dev/null && "$CID" tag v1.0.0 >/dev/null)
fi

# A model, the same way.
if ! has hf/models/clients-model; then
  mkdir -p "$WORK/model" && printf '{"hidden_size": 8}\n' > "$WORK/model/config.json"
  (cd "$WORK/model" && "$CID" init "cid@127.0.0.1:hf/models/clients-model" --git g@h:hf-model.git --model >/dev/null &&
    "$CID" add . >/dev/null && "$CID" commit -m "weights" >/dev/null && "$CID" push >/dev/null && "$CID" tag v1.0.0 >/dev/null)
fi

# An annotated dataset, the platform's way: bytes through the server, then
# revisions in the database, then a commit and a release through the API.
if ! has hf/datasets/clients-boxes; then
  api -X POST "$CID_SERVER/v0/datasets" -d '{"name":"hf/datasets/clients-boxes","kind":"annotated","git_url":"g@h:hf-boxes.git"}' >/dev/null
  HASH=$("$CID" hash-object "$FIXTURES/pixels.png")
  SIZE=$(wc -c < "$FIXTURES/pixels.png" | tr -d ' ')
  URL=$(api -X POST "$CID_SERVER/v0/datasets/hf/datasets/clients-boxes/-/check-hashes" -d "{\"hashes\":[\"$HASH\"]}" |
    "$PYTHON" -c 'import json,sys; m=json.load(sys.stdin)["missing"]; print(m[0]["url"] if m else "")')
  [ -n "$URL" ] && curl -sf -X PUT --data-binary "@$FIXTURES/pixels.png" "$URL" >/dev/null
  api -X POST "$CID_SERVER/v0/datasets/hf/datasets/clients-boxes/-/register-items" \
    -d "{\"items\":[{\"hash\":\"$HASH\",\"size\":$SIZE,\"media_type\":\"image/png\",\"width\":4,\"height\":3}]}" >/dev/null
  psql <<SQL
WITH d AS (SELECT dataset_id FROM datasets WHERE name = 'hf/datasets/clients-boxes'),
     it AS (SELECT gen_random_uuid() AS item_id, p, s FROM (VALUES ('frames/a.png', 'train'), ('frames/b.png', 'val')) v(p, s)),
     items AS (INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, split, author)
       SELECT d.dataset_id, 'main', it.p, 'add', it.item_id, decode('$HASH', 'hex'), it.s, 'agent:annotator' FROM d, it RETURNING item_id),
     owned AS (INSERT INTO dataset_items (item_id, dataset_id) SELECT items.item_id, d.dataset_id FROM items, d)
INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver)
  SELECT d.dataset_id, 'main', gen_random_uuid(), items.item_id, 'create', 'box', 'person', '{"x":1,"y":1,"w":2,"h":1}'::jsonb, 'agent:annotator', 'p1'
  FROM d, items;
SQL
  api -X POST "$CID_SERVER/v0/datasets/hf/datasets/clients-boxes/-/commit" -d '{"message":"two frames","author":"agent:annotator"}' >/dev/null
  api -X POST "$CID_SERVER/v0/datasets/hf/datasets/clients-boxes/-/tag" -d '{"name":"v1.0.0"}' >/dev/null
fi

HF_ENDPOINT=$CID_SERVER HF_TOKEN=$TOKEN HF_HOME=$WORK/hf HF_HUB_DISABLE_TELEMETRY=1 HF_HUB_OFFLINE=0 \
  "$PYTHON" -I "$(pwd)/tests/hf_client.py" "$FIXTURES"
