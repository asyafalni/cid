import { useQuery } from '@tanstack/react-query';
import { Link, Outlet, useRouterState } from '@tanstack/react-router';
import { clearToken, getMe } from './api';

// The shell: the manifest rail on the left, the deck on the right.
// The sign-in page gets the whole viewport to itself.
export function Shell() {
  const path = useRouterState({ select: (s) => s.location.pathname });
  const me = useQuery({ queryKey: ['me'], queryFn: getMe, enabled: path !== '/signin' });
  if (path === '/signin') return <Outlet />;

  return (
    <div className="shell">
      <nav className="rail" aria-label="cid">
        <Link to="/" className="wordmark">
          cid
        </Link>
        <div className="rail-foot">
          {me.data && (
            <>
              <p className="rail-who" title={me.data.account ?? undefined}>
                {me.data.display_name}
              </p>
              <Link to="/keys" className="rail-link">
                SSH keys
              </Link>
              {me.data.via === 'gitlab' ? (
                // A POST, so no link elsewhere can sign anybody out.
                <form method="post" action="/auth/signout">
                  <button type="submit" className="rail-signout">
                    Sign out
                  </button>
                </form>
              ) : (
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
            </>
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
