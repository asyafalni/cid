// A fake GitHub for the e2e suite: OAuth (authorization code + PKCE S256)
// at /login/oauth/*, and /api/v3/user (a GitHub Enterprise Server's API
// path, which a CID_GITHUB_URL other than github.com uses). Strict where
// GitHub is: no scope is needed, the token exchange answers a form unless
// asked for JSON and reports a refusal as 200 with an error, and the API
// refuses a request without a User-Agent.
import { createServer } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';

const port = 7191;
const clientId = 'cid-e2e-github';
const clientSecret = 'cid-e2e-github-secret';
const user = { login: 'octo', id: 5353, name: null };

const codes = new Map(); // code -> { challenge, redirectUri }
const tokens = new Set();

const b64url = (buf) => buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => (data += c));
    req.on('end', () => resolve(data));
  });
}

function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${port}`);
  if (url.pathname === '/health') return send(res, 200, { ok: true });

  if (req.method === 'GET' && url.pathname === '/login/oauth/authorize') {
    const q = url.searchParams;
    if (q.get('client_id') !== clientId) return send(res, 404, { error: 'unknown application' });
    if (q.get('code_challenge_method') !== 'S256' || !q.get('code_challenge'))
      return send(res, 400, { error: 'pkce_required' });
    const code = b64url(randomBytes(12));
    codes.set(code, { challenge: q.get('code_challenge'), redirectUri: q.get('redirect_uri') });
    const back = new URL(q.get('redirect_uri'));
    back.searchParams.set('code', code);
    back.searchParams.set('state', q.get('state'));
    res.writeHead(302, { location: back.toString() });
    return res.end();
  }

  if (req.method === 'POST' && url.pathname === '/login/oauth/access_token') {
    const form = new URLSearchParams(await readBody(req));
    const json = (req.headers.accept ?? '').includes('application/json');
    const answer = (body) => {
      if (json) return send(res, 200, body);
      res.writeHead(200, { 'content-type': 'application/x-www-form-urlencoded' });
      res.end(new URLSearchParams(body).toString());
    };
    const pending = codes.get(form.get('code'));
    if (form.get('client_id') !== clientId || form.get('client_secret') !== clientSecret)
      return answer({ error: 'incorrect_client_credentials' });
    if (!pending) return answer({ error: 'bad_verification_code' });
    if (form.get('redirect_uri') !== pending.redirectUri) return answer({ error: 'redirect_uri_mismatch' });
    const verifier = form.get('code_verifier') ?? '';
    if (b64url(createHash('sha256').update(verifier).digest()) !== pending.challenge)
      return answer({ error: 'bad_verification_code', error_description: 'PKCE verifier does not match' });
    codes.delete(form.get('code'));
    const token = b64url(randomBytes(16));
    tokens.add(token);
    return answer({ access_token: token, token_type: 'bearer', scope: '' });
  }

  if (req.method === 'GET' && url.pathname === '/api/v3/user') {
    if (!req.headers['user-agent']) return send(res, 403, { message: 'Request forbidden by administrative rules. Please make sure your request has a User-Agent header' });
    const auth = req.headers.authorization ?? '';
    if (!tokens.has(auth.replace(/^Bearer /, ''))) return send(res, 401, { message: 'Bad credentials' });
    return send(res, 200, user);
  }

  send(res, 404, { message: 'Not Found' });
}).listen(port, '127.0.0.1');
