# cid dashboard

The web dashboard for browsing, comparing and downloading datasets: React,
TypeScript and Vite. Read [`docs/dashboard.md`](../docs/dashboard.md) before
changing anything here: its phases, principles, design language and budgets
apply to every page.

## Scripts

Install once with `pnpm --dir web install`, then run each from the repository
root with `pnpm --dir web <script>`:

| Script | Does |
|---|---|
| `dev` | Vite dev server; proxies `/v0` to a `cid admin serve` on `127.0.0.1:7070` |
| `build` | Type-check, then build into `web/dist` |
| `preview` | Serve the built `web/dist` locally |
| `lint` | oxlint (`.oxlintrc.json`) |
| `typecheck` | `tsc -b` |
| `test:e2e` | Playwright (`web/e2e/`): UX budgets, accessibility (axe), keyboard |

Dashboard changes must pass `lint`, `typecheck` and `test:e2e`.

## Dev server

`pnpm --dir web dev` proxies only `/v0` (the API) to `127.0.0.1:7070`, so
start `cid admin serve` there first. `/auth` is not proxied, so "Sign in with
GitLab" does not work through the dev server; use the server's own port for
sign-in.

## Build

`pnpm --dir web build` writes `web/dist`. `zig build` embeds every file under
`web/dist` into the `cid` binary, so the dashboard ships inside the server;
without a build, the server has no dashboard to show. Build the web first,
then `zig build`.

## End-to-end tests

`pnpm --dir web test:e2e` runs against `../zig-out/bin/cid` (so `zig build`
first) with the services from `docker-compose.test.yml` up. It starts the
server on port 7177 and a fake GitLab on 7190, and seeds a small dataset
through the real CLI.
