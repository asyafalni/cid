#!/bin/sh
# One live check of cid's GitHub access (docs/access.md, "Other git
# hosts"): the tests run against a fake GitHub; this runs the real sync
# against a real repository once, to prove GitHub's answers have the shape
# cid reads. It only reads from GitHub.
#
# Needs: docker compose -f docker-compose.test.yml up -d --wait, `zig build`,
# and a fine-grained token with "Metadata: read" on the repository.
#   CID_GITHUB_TOKEN=github_pat_... GITHUB_REPO=owner/name [GITHUB_LOGIN=someone] sh tests/github_live.sh
# It registers a throwaway dataset pointing at the repository in the test
# database, syncs, prints what cid recorded, and removes it again.
set -eu
: "${CID_GITHUB_TOKEN:?set CID_GITHUB_TOKEN to a fine-grained token with Metadata: read}"
: "${GITHUB_REPO:?set GITHUB_REPO to owner/name}"
CID=${CID:-./zig-out/bin/cid}
NAME=live/github-check
export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'
psql() { docker compose -f docker-compose.test.yml exec -T timescaledb psql -qtA -U cid -d cid_test -v ON_ERROR_STOP=1 "$@"; }
cleanup() {
  psql -c "DELETE FROM access WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = '$NAME');
           DELETE FROM datasets WHERE name = '$NAME';" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$CID" admin migrate >/dev/null
cleanup
psql -c "INSERT INTO datasets (dataset_id, name, kind, git_url) VALUES (gen_random_uuid(), '$NAME', 'files', 'git@github.com:$GITHUB_REPO.git')"

echo "== cid admin sync (GitHub: $GITHUB_REPO)"
CID_GITHUB_TOKEN="$CID_GITHUB_TOKEN" "$CID" admin sync

echo "== access cid recorded for the repository's collaborators"
psql -c "SELECT a.account_id, ac.display_name, a.level FROM access a JOIN datasets d USING (dataset_id)
         JOIN accounts ac USING (account_id) WHERE d.name = '$NAME' ORDER BY a.level, ac.display_name"
echo "== their public SSH keys, as cid fingerprints them"
psql -c "SELECT k.account_id, k.fingerprint FROM ssh_keys k WHERE k.source = 'github' AND k.account_id IN
         (SELECT a.account_id FROM access a JOIN datasets d USING (dataset_id) WHERE d.name = '$NAME') ORDER BY 1, 2"

if [ -n "${GITHUB_LOGIN:-}" ]; then
  # What the create check reads: one person's role on the repository.
  echo "== $GITHUB_LOGIN's permission on $GITHUB_REPO (creating a dataset needs admin or maintain)"
  curl -sf -H "Authorization: Bearer $CID_GITHUB_TOKEN" -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' -A cid \
    "https://api.github.com/repos/$GITHUB_REPO/collaborators/$GITHUB_LOGIN/permission" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print("permission:", d.get("permission"), " role_name:", d.get("role_name"))'
fi
echo "== done: paste everything above back"
