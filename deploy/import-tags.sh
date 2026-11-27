#!/bin/sh
# Brings a dataset kept in git with DVC or Git LFS into cid: every git tag
# becomes a cid release of the same name, oldest first, holding exactly the
# data that tag had (docs/coming-from.md).
#
# Run it at the top of a clone of the old repository, after `cid init`
# there. It never changes that repository's history, only what is checked
# out.
#
#   sh import-tags.sh               every tag, oldest first
#   sh import-tags.sh v1.0 v1.1     only these, in this order
#
# It stops at the first thing that fails and says what. Run it again and it
# carries on after the last tag that is already a release: nothing is
# imported twice, and files already uploaded are not sent again.
#
# Local disk: the data once for DVC's cache, and at most one batch more.
# DVC checks the files out as hard links into its cache, and cid keeps what
# it stages in a cache of the import's own (inside .git/), emptied after
# every push. A tag holding more new or changed data than a batch,
# CID_IMPORT_BATCH_MB (default 10240, so 10 GB), goes up in parts, each
# its own commit; the release is made at the last.
set -u
batch_mb="${CID_IMPORT_BATCH_MB:-10240}"
case "$batch_mb" in ''|*[!0-9]*) printf 'import-tags: CID_IMPORT_BATCH_MB must be a number of MB.\n' >&2; exit 1 ;; esac

say() { printf '%s\n' "$*"; }
die() { say "import-tags: $*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is not installed."
command -v cid >/dev/null 2>&1 || die "cid is not on the PATH. Install it, then run this again."
top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "this is not a git repository. Run this in a clone of the repository to import."
[ "$top" = "$(pwd -P)" ] || die "run this at the top of the repository: cd '$top'"
[ -d .cid ] || die "this folder is not a cid dataset yet. Run 'cid init <address> --git <new-empty-git-url>' here first, then run this again."

# git must not see cid's own files, or they would look like leftovers.
for line in .cid/ .cidignore; do
    grep -qxF "$line" .git/info/exclude 2>/dev/null || printf '%s\n' "$line" >> .git/info/exclude
done

# cid's cache for the import: its own, so emptying it after each push can
# never take a file another folder of yours has not pushed yet.
gitdir="$(git rev-parse --absolute-git-dir)"
export XDG_CACHE_HOME="$gitdir/cid-import-cache"

# What is not data. Written once, for you to finish: code beside the data
# is yours to name.
if [ ! -f .cidignore ]; then
    printf '.git/\n.dvc/\n*.dvc\n.dvcignore\n.gitignore\n.gitattributes\ndvc.yaml\ndvc.lock\n' > .cidignore
    say "Wrote .cidignore: git's and DVC's own files are left out of the import."
    say "Add anything else that is not data (code folders, notebooks), one a line,"
    say "then run this again."
    exit 0
fi

# Files git does not know would be taken for data, and are removed between
# tags (a tag that dropped a file must not keep it).
stray="$(git status --porcelain --untracked-files=all | grep '^??' | head -5)"
if [ -n "$stray" ]; then
    say "import-tags: this clone holds files git does not know:" >&2
    say "$stray" >&2
    die "the import removes such files between tags. Move them away or use a fresh clone, then run this again."
fi
[ -z "$(git status --porcelain --untracked-files=no)" ] ||
    die "this clone has uncommitted changes (git status). Commit or discard them, then run this again."
grep -qxF '.git/' .cidignore ||
    die ".cidignore must leave out .git/ (git's own files, and this import's cache). Add the line '.git/' to it, then run this again."

# A file's size, many at a time: GNU stat, else BSD's.
if stat -c %s /dev/null >/dev/null 2>&1; then sizes() { tr '\n' '\0' | xargs -0 stat -c '%s %n'; }
else sizes() { tr '\n' '\0' | xargs -0 stat -f '%z %N'; }; fi

# The folder's unstaged changes, from cid status: "new", "modified" or
# "deleted", then the path. (Its words are checked by tests/import_tags.sh.)
changes() { cid status | sed -nE 's/^  (new|modified|deleted) +(.*)$/\1 \2/p'; }

secs_since() { echo $(( $(date +%s) - $1 )); }

if [ "$#" -gt 0 ]; then tags="$*"; else tags="$(git tag --sort=creatordate)"; fi
[ -n "$tags" ] || die "this repository has no tags. Tag the versions to keep (git tag v1.0 <commit>), then run this again."

# A release name holds letters, digits, dot, dash and underscore.
release_of() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }

# The releases cid already has, one a line.
released="$(cid log --json 2>/dev/null | tr '{' '\n' | sed -n 's/.*"releases":"\([^"]*\)".*/\1/p' | sed 's/, /,/g' | tr ',' '\n')"
is_released() { printf '%s\n' "$released" | grep -qxF "$1"; }

WORK_DIR="$gitdir/cid-import-batches"

# Carry on after the last tag that is already a release.
total=0; done_upto=0
for tag in $tags; do
    total=$((total+1))
    is_released "$(release_of "$tag")" && done_upto=$total
done
[ "$done_upto" -lt "$total" ] || { say "Every tag is already a release in cid: nothing to do."; exit 0; }
[ "$done_upto" -eq 0 ] || say "$done_upto of $total tags are already releases; carrying on after them."

stop() { # the tag, then what failed
    say "" >&2
    say "import-tags: stopped at $1: $2" >&2
    say "Nothing after it was imported. Fix that, then run this again; it carries on from $1." >&2
    exit 1
}

n=0
for tag in $tags; do
    n=$((n+1))
    [ "$n" -gt "$done_upto" ] || continue
    rel="$(release_of "$tag")"
    say "[$n/$total] $tag"
    [ "$rel" = "$tag" ] || say "  (released as '$rel': a release name cannot hold every character a git tag can)"

    started=$(date +%s)
    git checkout -q "$tag" || stop "$tag" "git could not check it out."
    # What an earlier tag left behind and this one does not have.
    git clean -fdq || stop "$tag" "git clean failed."
    if [ -d .dvc ]; then
        command -v dvc >/dev/null 2>&1 || stop "$tag" "this tag uses DVC and 'dvc' is not installed."
        # A repository set to check files out as symbolic links into DVC's
        # cache (cache.type symlink, usual for large data) would give cid
        # links, and cid stores files. Hard links are files, and cost no
        # more space; the setting is this clone's own (.dvc/config.local).
        # The usual copies (DVC's default where the disk cannot clone) would
        # hold the data a second time. So this clone checks files out as
        # clones where the disk makes them, else hard links into DVC's
        # cache: files to cid, and no more space. They are read-only, which
        # an import never minds. The setting is this clone's own
        # (.dvc/config.local).
        case "$(dvc config --local cache.type 2>/dev/null)" in
            reflink,hardlink,copy) ;;
            *) dvc config --local cache.type reflink,hardlink,copy || stop "$tag" "could not set this clone's DVC cache.type."
               say "  (this clone checks DVC's files out as hard links or clones, which take no more space)" ;;
        esac
        # Fetches what is missing, then checks it out; it fails if any file is absent from the remote.
        dvc pull -q || stop "$tag" "'dvc pull' failed: is the DVC remote reachable, with its credentials set?"
        # What an earlier checkout left as links or copies is linked too.
        dvc checkout --relink -q || stop "$tag" "'dvc checkout --relink' failed."
    fi
    if git ls-files -z '*.gitattributes' '.gitattributes' | xargs -0 grep -qs 'filter=lfs' 2>/dev/null; then
        git lfs version >/dev/null 2>&1 || stop "$tag" "this tag uses Git LFS and 'git lfs' is not installed."
        git lfs pull || stop "$tag" "'git lfs pull' failed: is the LFS server reachable?"
    fi

    fetched=$(secs_since "$started")

    # This tag's new and changed files in batches of batch_mb at most (one
    # file larger than that is a batch of its own), its deletions with the
    # first. Each batch is added, committed and pushed, then cid's cache is
    # emptied: pushed, its files are on the server.
    rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR" || stop "$tag" "could not make a scratch folder in .git/."
    changes > "$WORK_DIR/changes" || stop "$tag" "'cid status' failed."
    sed -n 's/^deleted //p' "$WORK_DIR/changes" > "$WORK_DIR/deleted"
    sed -nE 's/^(new|modified) //p' "$WORK_DIR/changes" | sizes |
        awk -v max=$((batch_mb * 1024 * 1024)) -v dir="$WORK_DIR" '
            { size = $1; sub(/^[0-9]+ /, ""); if (n == 0 || (sum > 0 && sum + size > max)) { n++; sum = 0 }
              sum += size; print > (dir "/batch-" n) }
            END { print n + 0 > (dir "/batches") }' || stop "$tag" "could not size this tag's files."
    batches=$(cat "$WORK_DIR/batches" 2>/dev/null || echo 0)
    [ "$batches" -gt 0 ] || batches=1
    staged_s=0; pushed_s=0
    part=1
    while [ "$part" -le "$batches" ]; do
        t=$(date +%s)
        list="$WORK_DIR/batch-$part"
        [ "$part" -eq 1 ] && cat "$WORK_DIR/deleted" >> "$list"
        if [ -s "$list" ]; then
            out="$(sed 's|^|./|' "$list" | tr '\n' '\0' | xargs -0 cid add 2>&1)" ||
                { say "$out" >&2; stop "$tag" "'cid add' failed."; }
        fi
        if [ "$part" -eq "$batches" ]; then
            # The last part also takes anything the batches did not name.
            out="$(cid add . 2>&1)" || { say "$out" >&2; stop "$tag" "'cid add .' failed."; }
            message="Import $tag"
        else
            message="Import $tag (part $part of $batches)"
        fi
        staged_s=$((staged_s + $(secs_since "$t")))
        # A tag that changed no data has nothing to commit: it is released all
        # the same, at the commit before it, so every old name has a release.
        out="$(cid commit -m "$message" 2>&1)" || case "$out" in
            *"nothing staged"*) ;;
            *) say "$out" >&2; stop "$tag" "'cid commit' failed." ;;
        esac
        t=$(date +%s)
        cid push >/dev/null || stop "$tag" "'cid push' failed. It resumes: nothing already uploaded is sent again."
        pushed_s=$((pushed_s + $(secs_since "$t")))
        rm -rf "$XDG_CACHE_HOME/cid"
        part=$((part + 1))
    done
    rm -rf "$WORK_DIR"
    parts=""; [ "$batches" -gt 1 ] && parts=", in $batches parts"
    say "  fetched in ${fetched} s, staged in ${staged_s} s, pushed in ${pushed_s} s$parts"
    notes="Imported from git tag $tag ($(git log -1 --format=%as "$tag")): $(git log -1 --format=%s "$tag")"
    out="$(cid tag "$rel" -m "$notes" 2>&1)" || case "$out" in
        *"nothing to tag"*) say "  no data yet at this tag: no release" ;;
        *) say "$out" >&2; stop "$tag" "'cid tag $rel' failed." ;;
    esac
done

say ""
say "Imported. 'cid log' lists the releases; the folder is left at the last tag."
