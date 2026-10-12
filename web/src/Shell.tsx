import { useState, type FormEvent, type ReactNode } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Link, Outlet, useNavigate, useRouterState } from '@tanstack/react-router';
import { clearToken, getMe } from './api';
import { applyTheme, storedTheme, type Theme } from './theme';

// The shell: a top bar (wordmark, search, theme, account), the deck, and
// a footer carrying the tagline. The sign-in page gets the whole viewport
// to itself.
export function Shell() {
  const path = useRouterState({ select: (s) => s.location.pathname });
  const me = useQuery({ queryKey: ['me'], queryFn: getMe, enabled: path !== '/signin' });
  if (path === '/signin') return <Outlet />;

  return (
    <div className="shell">
      <header className="topbar">
        <Link to="/" className="wordmark" aria-label="cid, all datasets">
          cid
        </Link>
        {/* The home has its own, larger search. */}
        {path !== '/' && <TopSearch />}
        <div className="topbar-end">
          <ThemeSwitch />
          {me.data && (
            // Keyed by the page, so the menu closes once a link in it is taken.
            <details className="account" key={path}>
              <summary className="account-name" title={me.data.account ?? undefined}>
                {me.data.display_name}
              </summary>
              <div className="account-menu panel">
                <Link to="/keys">SSH keys</Link>
                <Link to="/tokens">Tokens</Link>
                {me.data.via === 'gitlab' ? (
                  // A POST, so no link elsewhere can sign anybody out.
                  <form method="post" action="/auth/signout">
                    <button type="submit">Sign out</button>
                  </form>
                ) : (
                  <button
                    onClick={() => {
                      clearToken();
                      location.assign('/signin');
                    }}
                  >
                    Sign out
                  </button>
                )}
              </div>
            </details>
          )}
        </div>
      </header>
      <main className="deck">
        <Outlet />
      </main>
      <footer className="footer">cid · Controlled Iterative Datasets</footer>
    </div>
  );
}

function TopSearch() {
  const navigate = useNavigate();
  const [q, setQ] = useState('');
  const submit = (e: FormEvent) => {
    e.preventDefault();
    void navigate({ to: '/', search: q.trim() === '' ? {} : { q: q.trim() } });
  };
  return (
    <form className="topbar-search" role="search" onSubmit={submit}>
      <input
        type="search"
        aria-label="Search datasets"
        placeholder="Search datasets"
        value={q}
        onChange={(e) => setQ(e.target.value)}
      />
    </form>
  );
}

const themes: { id: Theme; label: string; icon: ReactNode }[] = [
  {
    id: 'system',
    label: 'Theme: follow the system',
    icon: (
      <>
        <rect x="2.75" y="3.75" width="14.5" height="10" />
        <path d="M7 17.25h6M10 13.75v3.5" />
      </>
    ),
  },
  {
    id: 'night',
    label: 'Theme: Night flight',
    icon: <path d="M15.5 12.5A6.5 6.5 0 0 1 7.5 4.5a6.5 6.5 0 1 0 8 8z" />,
  },
  {
    id: 'daybreak',
    label: 'Theme: Daybreak',
    icon: (
      <>
        <circle cx="10" cy="10" r="3.25" />
        <path d="M10 2.5v2M10 15.5v2M2.5 10h2M15.5 10h2M4.7 4.7l1.4 1.4M13.9 13.9l1.4 1.4M4.7 15.3l1.4-1.4M13.9 6.1l1.4-1.4" />
      </>
    ),
  },
];

function ThemeSwitch() {
  const [theme, setTheme] = useState<Theme>(storedTheme);
  return (
    <div className="theme-switch" role="radiogroup" aria-label="Theme">
      {themes.map((t) => (
        <button
          key={t.id}
          role="radio"
          aria-checked={theme === t.id}
          aria-label={t.label}
          title={t.label}
          onClick={() => {
            applyTheme(t.id);
            setTheme(t.id);
          }}
        >
          <svg viewBox="0 0 20 20" width="16" height="16" aria-hidden="true" className="icon">
            {t.icon}
          </svg>
        </button>
      ))}
    </div>
  );
}
