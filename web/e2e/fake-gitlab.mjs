// A fake GitLab for the e2e suite: OAuth (authorization code + PKCE S256)
// and /api/v4/user, strict where GitLab is strict, so a mistake in cid's
// OAuth — a wrong redirect_uri, a verifier that does not match its
// challenge, a missing client secret — fails a test instead of passing.
import { createServer } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';

const port = 7190;
const clientId = 'cid-e2e';
const clientSecret = 'cid-e2e-secret';
const user = { id: 4242, username: 'rhea', name: 'Rhea Reviewer' };

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

  if (req.method === 'GET' && url.pathname === '/oauth/authorize') {
    const q = url.searchParams;
    if (q.get('client_id') !== clientId) return send(res, 400, { error: 'invalid_client' });
    if (q.get('response_type') !== 'code' || q.get('scope') !== 'read_user')
      return send(res, 400, { error: 'invalid_request' });
    if (q.get('code_challenge_method') !== 'S256' || !q.get('code_challenge'))
      return send(res, 400, { error: 'pkce_required' });
    // The user "authorizes" at once: the e2e test is about cid's side.
    const code = b64url(randomBytes(12));
    codes.set(code, { challenge: q.get('code_challenge'), redirectUri: q.get('redirect_uri') });
    const back = new URL(q.get('redirect_uri'));
    back.searchParams.set('code', code);
    back.searchParams.set('state', q.get('state'));
    res.writeHead(302, { location: back.toString() });
    return res.end();
  }

  if (req.method === 'POST' && url.pathname === '/oauth/token') {
    const form = new URLSearchParams(await readBody(req));
    const pending = codes.get(form.get('code'));
    if (form.get('client_id') !== clientId || form.get('client_secret') !== clientSecret)
      return send(res, 401, { error: 'invalid_client' });
    if (!pending || form.get('grant_type') !== 'authorization_code')
      return send(res, 400, { error: 'invalid_grant' });
    if (form.get('redirect_uri') !== pending.redirectUri)
      return send(res, 400, { error: 'invalid_grant', why: 'redirect_uri differs' });
    const verifier = form.get('code_verifier') ?? '';
    if (b64url(createHash('sha256').update(verifier).digest()) !== pending.challenge)
      return send(res, 400, { error: 'invalid_grant', why: 'PKCE verifier does not match' });
    codes.delete(form.get('code')); // a code is good once
    const token = b64url(randomBytes(16));
    tokens.add(token);
    return send(res, 200, { access_token: token, token_type: 'Bearer' });
  }

  if (req.method === 'GET' && url.pathname === '/api/v4/user') {
    const auth = req.headers.authorization ?? '';
    if (!tokens.has(auth.replace(/^Bearer /, ''))) return send(res, 401, { message: '401 Unauthorized' });
    return send(res, 200, user);
  }

  send(res, 404, { message: 'not found' });
}).listen(port, '127.0.0.1');
