# cid · Controlled Iterative Datasets

**DVC lives inside git. Git lives inside cid.**

`cid` gives datasets what git gives code: history, releases, diffs and one-command
downloads — for any kind of data (images, video, audio, text, documents, tables, point
clouds) and the annotations on them. Where DVC bolts data onto git with pointer files
you must commit yourself, cid runs data natively and **writes git for you**: every
release lands in a paired git repository as one small, readable commit — dataset card,
release notes, stats — so the people who live in GitLab see every dataset release next
to their code, without git ever carrying the data.

```bash
cid clone cid@cidhub.com:your-org/datasets/speech-id   # no login: your SSH key
cd speech-id
cid checkout v1.3.0        # switch release; only changed files download
cid diff v1.2.0 v1.3.0     # what changed
```

And for people who produce data:

```bash
cid init cid@cidhub.com:your-org/datasets/calls --git git@gitlab.com:your-org/datasets/calls.git
cid add .
cid commit -m "Add March calls"    # instant, works offline
cid push
cid tag v1.0.0
```

For now, creating a dataset needs the server token (`CID_SERVER` and `CID_TOKEN`) or
`cid login`; creating one over SSH alone is refused until who may create datasets is
decided (see [`docs/access.md`](docs/access.md)).

If you know git, you already know cid: `add`, `commit`, `push`, `pull`, `checkout`,
`status`, `log`, `diff` — same verbs, same meaning.

## Status

**Pre-release.** The schema and protocols still change freely; the repo goes public at
the first usable release. Design docs: [`CLAUDE.md`](CLAUDE.md) (rules and invariants),
[`docs/data-model.md`](docs/data-model.md), [`docs/access.md`](docs/access.md),
[`docs/git-repository.md`](docs/git-repository.md),
[`docs/dashboard.md`](docs/dashboard.md).

Stack: CLI and server in Zig; history in TimescaleDB; files in SeaweedFS (S3 API);
dashboard in React + TypeScript, embedded in the server binary.

## Build

```bash
pnpm --dir web install
pnpm --dir web build                          # the dashboard, embedded by zig build
zig build                                     # the cid binary, libduckdb beside it
zig build test                                # unit tests, no services
docker compose -f docker-compose.test.yml up -d
zig build integration                         # against TimescaleDB + SeaweedFS
```

More in [`CLAUDE.md`](CLAUDE.md), "Build and test", and [`web/README.md`](web/README.md).

## Name

A tribute to the engineer who builds the airship in every classic JRPG — the tinkerer
who keeps the machine running. Always lower case `cid`. It is not an IPFS "CID"
(content identifier), though both deal in content hashes. Depending on the day, it may
also stand for *Clean, Inspected Datasets* (a release passed validation) or
*Corrupted Items Detected* (the validator found broken files) — officially, always
**Controlled Iterative Datasets**.

## License

[GPL-2.0-only](LICENSE) — exactly like git.
