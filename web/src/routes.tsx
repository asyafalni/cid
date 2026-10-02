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
import { getToken } from './api';

const rootRoute = createRootRoute({ component: Shell });

const signInRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/signin',
  component: SignIn,
});

const homeRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/',
  beforeLoad: () => {
    if (!getToken()) throw redirect({ to: '/signin' });
  },
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
    view?: 'overview' | 'browse' | 'releases' | 'files';
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
  beforeLoad: () => {
    if (!getToken()) throw redirect({ to: '/signin' });
  },
  component: DatasetOverview,
});

export { datasetRoute };

const routeTree = rootRoute.addChildren([signInRoute, homeRoute, datasetRoute]);

export const router = createRouter({ routeTree });

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router;
  }
}
