import {
  createRootRoute,
  createRoute,
  createRouter,
  stringifySearchWith,
  redirect,
} from '@tanstack/react-router';
import { Shell } from './Shell';
import { SignIn } from './pages/SignIn';
import { Home } from './pages/Home';
import { DatasetOverview } from './pages/DatasetOverview';
import { Keys } from './pages/Keys';
import { Tokens } from './pages/Tokens';
import { NotFound } from './pages/NotFound';
import { getMe } from './api';

// Signed in means the server says so: a GitLab session cookie or a pasted
// token, either way answered by /v0/me. Asked once per page load; signing
// in or out reloads the page.
let signedIn: Promise<boolean> | null = null;
function requireSignIn() {
  signedIn ??= getMe().then(
    () => true,
    () => false,
  );
  return signedIn.then((ok) => {
    if (!ok) throw redirect({ to: '/signin' });
  });
}

const rootRoute = createRootRoute({ component: Shell });

const signInRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/signin',
  component: SignIn,
});

const homeRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/',
  // The home's search and filters are a link too.
  validateSearch: (
    search: Record<string, unknown>,
  ): {
    q?: string;
    kind?: 'files' | 'annotated' | 'model';
    type?: string;
    released?: 'yes' | 'no';
    restricted?: 'yes' | 'no';
    layout?: 'list';
  } => ({
    // Cards are the default, so only the list is spelled.
    layout: search.layout === 'list' ? 'list' : undefined,
    q: typeof search.q === 'string' && search.q !== '' ? search.q : undefined,
    kind: search.kind === 'files' || search.kind === 'annotated' || search.kind === 'model' ? search.kind : undefined,
    type: typeof search.type === 'string' ? search.type : undefined,
    released: search.released === 'yes' || search.released === 'no' ? search.released : undefined,
    restricted: search.restricted === 'yes' || search.restricted === 'no' ? search.restricted : undefined,
  }),
  beforeLoad: requireSignIn,
  component: Home,
});

const datasetRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/d/$',
  // Every view is a link: the tab, the pinned release and the open item
  // all live in the URL.
  validateSearch: (
    search: Record<string, unknown>,
  ): {
    view?: 'overview' | 'browse' | 'releases' | 'health' | 'files' | 'activity';
    release?: string;
    commit?: string;
    branch?: string;
    item?: string;
    a?: string;
    b?: string;
    dir?: string;
    mode?: 'table' | 'gallery' | 'list' | 'sql';
    /** The SQL console's query. */
    sql?: string;
    q?: string;
    split?: string;
    class?: string;
    type?: string;
    anns?: string;
    attr?: string;
    identity?: string;
    /** Browse: only items changed since this release. */
    since?: string;
    /** A table item's row filters, as JSON (TableView). */
    rows?: string;
    /** A table item's row, by its place in the file from 1 (TableView). */
    row?: number;
    what?: string;
    who?: string;
  } => ({
    view:
      search.view === 'browse'
        ? 'browse'
        : search.view === 'releases'
          ? 'releases'
          : search.view === 'files'
            ? 'files'
            : search.view === 'activity'
              ? 'activity'
              : search.view === 'health'
                ? 'health'
                : undefined,
    release: typeof search.release === 'string' && typeof search.commit !== 'string' ? search.release : undefined,
    commit: typeof search.commit === 'string' ? search.commit : undefined,
    branch: typeof search.branch === 'string' && search.branch !== 'main' ? search.branch : undefined,
    item: typeof search.item === 'string' ? search.item : undefined,
    a: typeof search.a === 'string' ? search.a : undefined,
    b: typeof search.b === 'string' ? search.b : undefined,
    dir: typeof search.dir === 'string' ? search.dir : undefined,
    // Browse: the gallery is the default, so only the table is spelled;
    // filters are present only when set, so a clean view has a clean URL.
    mode: search.mode === 'table' || search.mode === 'gallery' || search.mode === 'list' || search.mode === 'sql' ? search.mode : undefined,
    sql: typeof search.sql === 'string' ? search.sql : undefined,
    q: typeof search.q === 'string' && search.q !== '' ? search.q : undefined,
    split: typeof search.split === 'string' ? search.split : undefined,
    class: typeof search.class === 'string' ? search.class : undefined,
    type: typeof search.type === 'string' ? search.type : undefined,
    anns: typeof search.anns === 'string' ? search.anns : undefined,
    attr: typeof search.attr === 'string' ? search.attr : undefined,
    identity: typeof search.identity === 'string' ? search.identity : undefined,
    since: typeof search.since === 'string' ? search.since : undefined,
    rows: typeof search.rows === 'string' ? search.rows : Array.isArray(search.rows) ? JSON.stringify(search.rows) : undefined,
    // Text in a URL, a number when the page sets it.
    row: /^[1-9]\d*$/.test(String(search.row ?? '')) ? Number(search.row) : undefined,
    // Activity: the action and the person, when narrowed.
    what: typeof search.what === 'string' ? search.what : undefined,
    who: typeof search.who === 'string' ? search.who : undefined,
  }),
  beforeLoad: requireSignIn,
  component: DatasetOverview,
});

export { datasetRoute };

const keysRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/keys',
  beforeLoad: requireSignIn,
  component: Keys,
});

const tokensRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/tokens',
  beforeLoad: requireSignIn,
  component: Tokens,
});

const routeTree = rootRoute.addChildren([signInRoute, homeRoute, datasetRoute, keysRoute, tokensRoute]);

// Search values are plain text: a release named 2024, a filter of 0 or a
// path like 123.jpg read as written, never JSON-quoted (anns=0, not
// anns=%220%22). A value written quoted, as links made before did, still
// reads as the text inside; a text that itself is quoted is written so.
const quoted = (v: string): string => {
  if (!/^".*"$/s.test(v)) throw new Error('plain');
  return JSON.parse(v) as string;
};
function parseSearch(searchStr: string): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of new URLSearchParams(searchStr)) {
    if (key in out) continue;
    try {
      out[key] = quoted(value);
    } catch {
      out[key] = value;
    }
  }
  return out;
}

// Any other address: lost in the clouds, inside the shell.
export const router = createRouter({
  routeTree,
  defaultNotFoundComponent: () => <NotFound />,
  parseSearch,
  stringifySearch: stringifySearchWith(JSON.stringify, quoted),
});

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router;
  }
}
