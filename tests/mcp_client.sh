#!/bin/sh
# The MCP door read by the official client (@modelcontextprotocol/sdk,
# pinned in tests/mcp_client/package.json): a dataset with two releases is
# made with the CLI, then tests/mcp_client/client.mjs connects as an
# agent's client does and calls the tools.
#
# Needs docker-compose.test.yml up, `zig build`, and Node with
# `npm ci --prefix tests/mcp_client` done. Run: sh tests/mcp_client.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CID="${CID:-$ROOT/zig-out/bin/cid}"
WORK="$(mktemp -d)"
PORT=$((20000 + $$ % 20000))
export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'
export CID_S3_ENDPOINT='http://127.0.0.1:8333'
export CID_S3_ACCESS_KEY='cid-test-key' CID_S3_SECRET_KEY='cid-test-secret'
export CID_TOKEN='mcp-client-token' CID_SERVER="http://127.0.0.1:$PORT"
export CID_TOKEN_SECRET='mcp-secret-mcp-secret-0123456789abc'
export CID_AUTHOR='user:mcp' CID_BROWSE_DIR="$WORK/browse"
export CID_GIT_WORKDIR="$WORK/git-work" CID_PUBLIC_URL="http://127.0.0.1:$PORT"
export XDG_CACHE_HOME="$WORK/cache"
DS="mcp/datasets/client-$(date +%s)-$$"

[ -d "$ROOT/tests/mcp_client/node_modules" ] || { echo "mcp_client: the client is not installed. Run 'npm ci --prefix tests/mcp_client', then run this again."; exit 1; }
if curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1; then
    echo "mcp_client: something already answers on port $PORT. Stop it, then run this again."; exit 1
fi
git init -q --bare "$WORK/demo.git"
"$CID" admin serve --port "$PORT" >"$WORK/serve.log" 2>&1 &
SERVE_PID=$!
trap 'kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 20); do curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1 && break; sleep 0.5; done

mkdir "$WORK/demo" && cd "$WORK/demo" || exit 1
printf 'id,text\n1,hello\n2,world\n' > calls.csv
echo "notes" > notes.txt
{ "$CID" init "cid@127.0.0.1:$DS" --git "$WORK/demo.git" && "$CID" add . && "$CID" commit -m "First" && "$CID" push && "$CID" tag v1.0.0 &&
  printf '3,again\n' >> calls.csv && "$CID" commit -a -m "Second" && "$CID" push && "$CID" tag v1.1.0; } >"$WORK/seed.log" 2>&1 ||
    { echo "FAIL: could not make the dataset"; cat "$WORK/seed.log"; exit 1; }

if node "$ROOT/tests/mcp_client/client.mjs" "$CID_SERVER/mcp" "$CID_TOKEN" "$DS"; then
    echo "mcp_client: all passed"
else
    echo "mcp_client: failed. The server's log:"; tail -20 "$WORK/serve.log"; exit 1
fi
