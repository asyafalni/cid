import { Link, Outlet, useRouterState } from '@tanstack/react-router';
import { clearToken, getToken } from './api';

// The shell: the manifest rail on the left, the deck on the right.
// The sign-in page gets the whole viewport to itself.
export function Shell() {
  const path = useRouterState({ select: (s) => s.location.pathname });
  if (path === '/signin') return <Outlet />;

  return (
    <div className="shell">
      <nav className="rail" aria-label="cid">
        <Link to="/" className="wordmark">
          cid
        </Link>
        <div className="rail-foot">
          {getToken() && (
            <button
              className="rail-signout"
              onClick={() => {
                clearToken();
                location.assign('/signin');
              }}
            >
              Sign out
            </button>
          )}
          <p className="tagline">cid · Controlled Iterative Datasets</p>
        </div>
      </nav>
      <main className="deck">
        <Outlet />
      </main>
    </div>
  );
}
