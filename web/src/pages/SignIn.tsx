import { useState } from 'react';
import { useNavigate } from '@tanstack/react-router';
import { ping, setToken, clearToken } from '../api';

// The one page that is mostly sky (docs/dashboard.md: sky gradients only
// where there is no data). GitLab OAuth replaces the token field in its
// own slice; the layout stays.
export function SignIn() {
  const navigate = useNavigate();
  const [value, setValue] = useState('');
  const [problem, setProblem] = useState<string | null>(null);
  const [checking, setChecking] = useState(false);

  async function signIn() {
    setChecking(true);
    setProblem(null);
    setToken(value.trim());
    try {
      await ping();
      navigate({ to: '/' });
    } catch {
      clearToken();
      setProblem('The server did not answer. Check that it is running and the address is right.');
    } finally {
      setChecking(false);
    }
  }

  return (
    <div className="signin sky-band">
      <div className="signin-card blueprint">
        <h1 className="signin-wordmark">cid</h1>
        <p className="tagline">cid · Controlled Iterative Datasets</p>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void signIn();
          }}
        >
          <label htmlFor="token">Access token</label>
          <input
            id="token"
            type="password"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            placeholder="paste a server token"
            autoComplete="off"
          />
          <button type="submit" className="action" disabled={checking || value.trim() === ''}>
            {checking ? 'Checking…' : 'Open the dashboard'}
          </button>
        </form>
        {problem && (
          <p role="alert" className="problem">
            {problem}
          </p>
        )}
        <p className="signin-note">
          Sign-in with GitLab arrives with the access slice; until then this is the server's
          token, the same one the CLI uses.
        </p>
      </div>
    </div>
  );
}
