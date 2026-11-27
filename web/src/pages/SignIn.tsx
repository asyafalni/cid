import { useState } from 'react';
import { Airship } from '../Airship';
import { useQuery } from '@tanstack/react-query';
import { useSearch } from '@tanstack/react-router';
import { clearToken, getAuthConfig, getMe, setToken } from '../api';
import { Goggles } from '../Goggles';

// The one page that is mostly sky (docs/dashboard.md: sky gradients only
// where there is no data). The server's git host first when it offers
// sign-in (GitLab or GitHub, one per server) — the same identity and roles
// the SSH front door uses — and the server token beneath it, for
// deployments without one and for CI.
function problems(host: string): Record<string, string> {
  return {
    denied: `${host} did not grant access. Run the sign-in again and choose Authorize.`,
    state: 'The sign-in came back without the check it was sent with. Run the sign-in again from this page.',
    expired: 'The sign-in took too long. Run the sign-in again.',
    host: `${host} could not be reached or refused the sign-in. Run the sign-in again; if it keeps failing, tell the administrator.`,
    server: 'The server could not record the sign-in. Run the sign-in again; if it keeps failing, tell the administrator.',
  };
}

export function SignIn() {
  const search = useSearch({ strict: false }) as { error?: string };
  const config = useQuery({ queryKey: ['auth-config'], queryFn: getAuthConfig });
  const [value, setValue] = useState('');
  const host = config.data?.github ? 'GitHub' : config.data?.gitlab ? 'GitLab' : null;
  const [tokenProblem, setProblem] = useState<string | null>(null);
  // A failed round trip's reason, in the words of the host it went to.
  const said = problems(host ?? 'The git host');
  const problem = tokenProblem ?? (search.error ? (said[search.error] ?? said.host) : null);
  const [checking, setChecking] = useState(false);
  const gitlab = host !== null;

  async function signInWithToken() {
    setChecking(true);
    setProblem(null);
    setToken(value.trim());
    try {
      await getMe(); // the token itself is checked, not just the server
      location.assign('/');
    } catch {
      clearToken();
      setProblem('The server did not accept that token. Check it, then run the sign-in again.');
    } finally {
      setChecking(false);
    }
  }

  return (
    <div className="signin sky-band">
      <div className="sky-clouds" aria-hidden="true" />
      <Airship className="signin-airship" />
      <div className="signin-card blueprint">
        <h1 className="signin-wordmark" aria-label="cid">
          <Goggles className="signin-logo" />
        </h1>
        <p className="tagline">cid · Controlled Iterative Datasets</p>
        {host && (
          <a className="action signin-gitlab" href={`/auth/${host.toLowerCase()}`}>
            Sign in with {host}
          </a>
        )}
        <form
          className={gitlab ? 'signin-token signin-token--secondary' : 'signin-token'}
          onSubmit={(e) => {
            e.preventDefault();
            void signInWithToken();
          }}
        >
          <label htmlFor="token">{gitlab ? 'Or a server token' : 'Access token'}</label>
          <input
            id="token"
            type="password"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            placeholder="paste a server token"
            autoComplete="off"
          />
          <button type="submit" className={gitlab ? 'action action--outline' : 'action'} disabled={checking || value.trim() === ''}>
            {checking ? 'Checking…' : 'Open the dashboard'}
          </button>
        </form>
        {problem && (
          <p role="alert" className="problem">
            {problem}
          </p>
        )}
        <p className="signin-note">
          {host
            ? `${host} is your identity here, as it is over SSH: you see the datasets your ${host} role lets you read.`
            : "This server has no git-host sign-in configured; paste the server's token (CID_TOKEN)."}
        </p>
      </div>
    </div>
  );
}
