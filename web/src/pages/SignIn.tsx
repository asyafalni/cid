import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useSearch } from '@tanstack/react-router';
import { clearToken, getAuthConfig, getMe, setToken } from '../api';

// The one page that is mostly sky (docs/dashboard.md: sky gradients only
// where there is no data). GitLab first when the server offers it — the
// same identity and roles the SSH front door uses — and the server token
// beneath it, for deployments without GitLab and for CI.
const problems: Record<string, string> = {
  denied: 'GitLab did not grant access. Run the sign-in again and choose Authorize.',
  state: 'The sign-in came back without the check it was sent with. Run the sign-in again from this page.',
  expired: 'The sign-in took too long. Run the sign-in again.',
  gitlab: 'GitLab could not be reached or refused the sign-in. Run the sign-in again; if it keeps failing, tell the administrator.',
  server: 'The server could not record the sign-in. Run the sign-in again; if it keeps failing, tell the administrator.',
};

export function SignIn() {
  const search = useSearch({ strict: false }) as { error?: string };
  const config = useQuery({ queryKey: ['auth-config'], queryFn: getAuthConfig });
  const [value, setValue] = useState('');
  const [problem, setProblem] = useState<string | null>(
    search.error ? (problems[search.error] ?? problems.gitlab) : null,
  );
  const [checking, setChecking] = useState(false);
  const gitlab = config.data?.gitlab === true;

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
      <div className="signin-card blueprint">
        <h1 className="signin-wordmark">cid</h1>
        <p className="tagline">cid · Controlled Iterative Datasets</p>
        {gitlab && (
          <a className="action signin-gitlab" href="/auth/gitlab">
            Sign in with GitLab
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
          <button type="submit" className={gitlab ? 'action action--quiet' : 'action'} disabled={checking || value.trim() === ''}>
            {checking ? 'Checking…' : 'Open the dashboard'}
          </button>
        </form>
        {problem && (
          <p role="alert" className="problem">
            {problem}
          </p>
        )}
        <p className="signin-note">
          {gitlab
            ? 'GitLab is your identity here, as it is over SSH: you see the datasets your GitLab role lets you read.'
            : "This server has no GitLab sign-in configured; use its token, the same one the CLI's 'cid login' takes."}
        </p>
      </div>
    </div>
  );
}
