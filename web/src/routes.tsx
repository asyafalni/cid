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
