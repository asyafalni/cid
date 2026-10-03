import {
  createRootRoute,
  createRoute,
  createRouter,
  redirect,
} from '@tanstack/react-router';
import { Shell } from './Shell';
import { SignIn } from './pages/SignIn';
import { Home } from './pages/Home';
import { DatasetOverview } from './pages/DatasetOverview';
import { Keys } from './pages/Keys';
import { Tokens } from './pages/Tokens';
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
  ): { q?: string; kind?: 'files' | 'annotated'; type?: string; released?: 'yes' | 'no'; restricted?: 'yes' | 'no' } => ({
    q: typeof search.q === 'string' && search.q !== '' ? search.q : undefined,
    kind: search.kind === 'files' || search.kind === 'annotated' ? search.kind : undefined,
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
    view?: 'overview' | 'browse' | 'releases' | 'files' | 'activity';
    release?: string;
    item?: string;
    a?: string;
    b?: string;
    dir?: string;
    mode?: 'table';
    q?: string;
    split?: string;
    class?: string;
    type?: string;
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
              : undefined,
    release: typeof search.release === 'string' ? search.release : undefined,
    item: typeof search.item === 'string' ? search.item : undefined,
    a: typeof search.a === 'string' ? search.a : undefined,
    b: typeof search.b === 'string' ? search.b : undefined,
    dir: typeof search.dir === 'string' ? search.dir : undefined,
    // Browse: the gallery is the default, so only the table is spelled;
    // filters are present only when set, so a clean view has a clean URL.
    mode: search.mode === 'table' ? 'table' : undefined,
    q: typeof search.q === 'string' && search.q !== '' ? search.q : undefined,
    split: typeof search.split === 'string' ? search.split : undefined,
    class: typeof search.class === 'string' ? search.class : undefined,
    type: typeof search.type === 'string' ? search.type : undefined,
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

export const router = createRouter({ routeTree });

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router;
  }
}
