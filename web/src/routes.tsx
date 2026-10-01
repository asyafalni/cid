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
  beforeLoad: () => {
    if (!getToken()) throw redirect({ to: '/signin' });
  },
  component: DatasetOverview,
});

const routeTree = rootRoute.addChildren([signInRoute, homeRoute, datasetRoute]);

export const router = createRouter({ routeTree });

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router;
  }
}
