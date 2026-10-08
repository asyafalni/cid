#!/bin/sh
# The reverse-proxy configs in deploy/proxy/, checked against a real
# server: each one, rewritten only to listen on local ports without TLS,
# carries a push with a file large enough to go up in pieces, a clone of
# it elsewhere (every file hash-checked), a release and the dashboard.
# The server reaches the store directly and signs for its public name,
# as the README sets it up, so every file a client moves crosses the proxy. Needs docker-compose.test.yml up, docker, and
# `zig build`. Run: sh tests/proxy.sh            (both)
#                   PROXY=caddy sh tests/proxy.sh (one)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CID="$ROOT/zig-out/bin/cid"
WORK="$(mktemp -d)"
PORT=$((20000 + $$ % 20000))
API_PORT=$((PORT + 1)) S3_PORT=$((PORT + 2)) STORE_PORT=$((PORT + 3))
SEAWEED_IMAGE=chrislusf/seaweedfs:4.48
CADDY_IMAGE=caddy:2.10.0
NGINX_IMAGE=nginx:1.28.0
export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'
export CID_S3_ACCESS_KEY='cid-test-key' CID_S3_SECRET_KEY='cid-test-secret'
export CID_TOKEN='proxy-token' CID_TOKEN_SECRET='proxy-secret-proxy-secret-0123456789'
export CID_AUTHOR='user:proxy'
# Clients go through the proxy's two names; the server reaches the store
# straight, and signs the URLs it hands out for the store's public name
# (deploy/proxy/README.md).
export CID_SERVER="http://127.0.0.1:$API_PORT" CID_PUBLIC_URL="http://127.0.0.1:$API_PORT"
export CID_S3_ENDPOINT="http://127.0.0.1:$STORE_PORT" CID_S3_PUBLIC_ENDPOINT="http://127.0.0.1:$S3_PORT"

fails=0
say() { printf '%s\n' "$*"; }
check() { desc="$1"; shift; if "$@" >"$WORK/last.log" 2>&1; then say "ok: $desc"; else say "FAIL: $desc"; sed 's/^/     /' "$WORK/last.log" | tail -8; fails=$((fails+1)); return 1; fi; }

SERVE_PID= PROXY_ID= STORE_ID=
cleanup() {
    [ -n "$PROXY_ID" ] && docker rm -f "$PROXY_ID" >/dev/null 2>&1
    [ -n "$STORE_ID" ] && docker rm -f "$STORE_ID" >/dev/null 2>&1
    [ -n "$SERVE_PID" ] && { kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null; }
    rm -rf "$WORK"
}
trap cleanup EXIT

# A store of its own that checks every signature, as a real deployment's
# does (the compose file's test store accepts anything): only then does a
# proxy that changed the Host header fail here as it would in production.
cat >"$WORK/s3.json" <<JSON
{"identities": [{"name": "cid", "credentials": [{"accessKey": "$CID_S3_ACCESS_KEY", "secretKey": "$CID_S3_SECRET_KEY"}],
  "actions": ["Admin", "Read", "Write", "List", "Tagging"]}]}
JSON
STORE_ID=$(docker run -d -p "127.0.0.1:$STORE_PORT:8333" -v "$WORK/s3.json:/etc/s3.json:ro" "$SEAWEED_IMAGE" \
    server -dir=/data -s3 -s3.port=8333 -s3.config=/etc/s3.json -master.volumeSizeLimitMB=64) || { say "FAIL: the store did not start"; exit 1; }
for _ in $(seq 100); do docker exec "$STORE_ID" sh -c "echo 's3.bucket.create -name cid' | weed shell" >/dev/null 2>&1 &&
    docker exec "$STORE_ID" sh -c "echo 's3.bucket.list' | weed shell" 2>/dev/null | grep -q cid && break; sleep 0.3; done
# Unsigned requests are refused: the store really checks.
for _ in $(seq 100); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$STORE_PORT/cid/")
    [ "$code" != 000 ] && break; sleep 0.3
done
[ "$code" = 403 ] || { say "FAIL: the test store answers unsigned requests ($code); it would prove nothing"; exit 1; }

# The shipped configs, changed only where a test must: local ports for the
# two names, no certificates, the server on this run's port.
caddy_config() {
    sed -e "s|^s3\.cid\.example\.com {|http://127.0.0.1:$S3_PORT {|" \
        -e "s|^cid\.example\.com {|http://127.0.0.1:$API_PORT {|" \
        -e "s|127\.0\.0\.1:7070|127.0.0.1:$PORT|" \
        -e "s|127\.0\.0\.1:8333|127.0.0.1:$STORE_PORT|" \
        "$ROOT/deploy/proxy/Caddyfile" >"$WORK/Caddyfile"
    PROXY_ID=$(docker run -d --network host -v "$WORK/Caddyfile:/etc/caddy/Caddyfile:ro" "$CADDY_IMAGE") || return 1
}
nginx_config() {
    # The first server block is the API's, the second the store's; the
    # last one only redirects port 80 to HTTPS, which a test has no use for.
    awk -v api="$API_PORT" -v s3="$S3_PORT" -v port="$PORT" -v store="$STORE_PORT" '
        /^server \{/ { n++ }
        n == 3 { next }
        /listen 443 ssl;/ { sub(/443 ssl/, (n == 1 ? api : s3)) }
        /ssl_certificate|http2 on;/ { next }
        { gsub(/127\.0\.0\.1:7070/, "127.0.0.1:" port); gsub(/127\.0\.0\.1:8333/, "127.0.0.1:" store); print }
    ' "$ROOT/deploy/proxy/nginx.conf" >"$WORK/cid.conf"
    printf 'events {}\nhttp {\n    include /etc/nginx/conf.d/cid.conf;\n}\n' >"$WORK/nginx.conf"
    PROXY_ID=$(docker run -d --network host -v "$WORK/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$WORK/cid.conf:/etc/nginx/conf.d/cid.conf:ro" "$NGINX_IMAGE") || return 1
}

run_one() {
    proxy="$1"
    say "--- $proxy"
    "${proxy}_config" || { say "FAIL: $proxy did not start"; fails=$((fails+1)); return; }
    for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$S3_PORT/" && break; sleep 0.2; done

    "$CID" admin serve --port "$PORT" >"$WORK/serve-$proxy.log" 2>&1 &
    SERVE_PID=$!
    for _ in $(seq 50); do curl -sf "$CID_SERVER/v0/ping" >/dev/null 2>&1 && break; sleep 0.2; done
    check "$proxy: the API answers through the proxy" curl -sf "$CID_SERVER/v0/ping" ||
        { tail -5 "$WORK/serve-$proxy.log" | sed 's/^/     server: /'; docker logs "$PROXY_ID" 2>&1 | tail -5 | sed 's/^/     proxy: /'; }
    check "$proxy: the dashboard loads through the proxy" sh -c "curl -sf '$CID_SERVER/' | grep -q '<div id=\"root\"'"

    ds="proxy/datasets/$proxy-$(date +%s)-$$"
    src="$WORK/$proxy-src" dst="$WORK/$proxy-dst"
    mkdir -p "$src"
    printf 'through the proxy\n' >"$src/notes.txt"
    # Over 64 MB: it goes up in pieces, each a presigned PUT at the store's name.
    head -c 70000000 /dev/urandom >"$src/big.bin"
    check "$proxy: init" sh -c "cd '$src' && '$CID' init 'cid@proxy:$ds' --git 'git@example.invalid:$proxy.git'"
    check "$proxy: add and commit" sh -c "cd '$src' && '$CID' add . && '$CID' commit -m 'through the proxy'"
    check "$proxy: push, a 70 MB file in pieces" sh -c "cd '$src' && '$CID' push"
    check "$proxy: release" sh -c "cd '$src' && '$CID' tag v1.0.0"
    check "$proxy: clone elsewhere, every file hash-checked" sh -c "cd '$WORK' && '$CID' clone 'cid@proxy:$ds' '$dst'"
    check "$proxy: the clone holds exactly what was pushed" sh -c "cmp '$src/big.bin' '$dst/big.bin' && cmp '$src/notes.txt' '$dst/notes.txt'"

    kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null; SERVE_PID=
    docker rm -f "$PROXY_ID" >/dev/null 2>&1; PROXY_ID=
}

for proxy in ${PROXY:-caddy nginx}; do run_one "$proxy"; done

if [ "$fails" -eq 0 ]; then say "proxy: every config carried a push, a clone, a release and the dashboard."
else say "proxy: $fails check(s) failed."; exit 1; fi
