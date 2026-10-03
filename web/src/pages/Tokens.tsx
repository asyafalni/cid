import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ApiError, getMe, listTokens, makeToken, revokeToken, type PersonalToken } from '../api';

// Personal tokens (docs/access.md): for scripts, CI and machines without
// SSH. A token acts as you, with your access, until it expires or is
// revoked. It goes in an https address the way git takes credentials, or
// in CID_TOKEN. Shown once; only its hash is kept.
const lifetimes = [30, 90, 180, 365];

export function Tokens() {
  const me = useQuery({ queryKey: ['me'], queryFn: getMe });
  const person = me.data?.via === 'gitlab';
  const tokens = useQuery({ queryKey: ['tokens'], queryFn: listTokens, enabled: person });
  const client = useQueryClient();
  const [name, setName] = useState('');
  const [days, setDays] = useState(90);
  const [fresh, setFresh] = useState<{ name: string; token: string } | null>(null);

  const make = useMutation({
    mutationFn: () => makeToken(name, days),
    onSuccess: (got) => {
      client.setQueryData(['tokens'], { tokens: got.tokens });
      setFresh({ name: name.trim(), token: got.token });
      setName('');
    },
  });
  const revoke = useMutation({
    mutationFn: (id: string) => revokeToken(id),
    onSuccess: (got) => client.setQueryData(['tokens'], { tokens: got.tokens }),
  });

  return (
    <section className="keys">
      <header className="deck-head">
        <h1>Tokens</h1>
        <p className="quiet">
          For scripts and CI, where there is no SSH key. A token acts as you, with your access, until it
          expires or you revoke it.
        </p>
      </header>

      {me.data && !person && (
        <div className="panel notice" role="status">
          <p>You are signed in with the server token, which belongs to no one and makes no tokens.</p>
          <p className="quiet">Sign out, then choose Sign in with GitLab to manage your own.</p>
        </div>
      )}

      {fresh && <FreshToken name={fresh.name} token={fresh.token} onDone={() => setFresh(null)} />}

      {person && tokens.isPending && <p className="quiet">Reading your tokens…</p>}
      {person && tokens.isError && <Problem error={tokens.error} />}
      {person &&
        tokens.data &&
        (tokens.data.tokens.length === 0 ? (
          <div className="empty blueprint">
            <p>No tokens yet. Make one for each script or job, so you can revoke one without the others.</p>
          </div>
        ) : (
          <ul className="key-list panel" aria-label="Your tokens">
            {tokens.data.tokens.map((t) => (
              <TokenRow
                key={t.id}
                t={t}
                revoking={revoke.isPending && revoke.variables === t.id}
                onRevoke={() => revoke.mutate(t.id)}
              />
            ))}
          </ul>
        ))}
      {revoke.isError && <Problem error={revoke.error} />}

      {person && (
        <form
          className="key-add panel"
          onSubmit={(e) => {
            e.preventDefault();
            make.mutate();
          }}
        >
          <h2>Make a token</h2>
          <label htmlFor="token-name">Name</label>
          <input
            id="token-name"
            value={name}
            maxLength={100}
            placeholder="nightly CI"
            onChange={(e) => setName(e.target.value)}
          />
          <label htmlFor="token-days">Expires after</label>
          <select id="token-days" value={days} onChange={(e) => setDays(Number(e.target.value))}>
            {lifetimes.map((d) => (
              <option key={d} value={d}>
                {d} days
              </option>
            ))}
          </select>
          <button type="submit" className="action" disabled={make.isPending || name.trim() === ''}>
            {make.isPending ? 'Making…' : 'Make token'}
          </button>
          <div aria-live="polite">{make.isError && <Problem error={make.error} />}</div>
        </form>
      )}
    </section>
  );
}

// The one moment the token can be seen: copy it now, with the two ways to
// use it filled in for this server.
function FreshToken({ name, token, onDone }: { name: string; token: string; onDone: () => void }) {
  const origin = `${location.protocol}//`;
  const clone = `cid clone ${origin}you:${token}@${location.host}/<dataset path>`;
  return (
    <div className="panel token-fresh" role="status">
      <h2>{name} is ready</h2>
      <p className="quiet">Copy it now. It is not shown again; only its fingerprint is kept.</p>
      <CopyLine label="Token" text={token} />
      <CopyLine label="In an address" text={clone} />
      <CopyLine label="Or in the environment" text={`export CID_TOKEN=${token}`} />
      <button className="key-remove" onClick={onDone}>
        Done, I have copied it
      </button>
    </div>
  );
}

function CopyLine({ label, text }: { label: string; text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="token-line">
      <span className="quiet token-line-label">{label}</span>
      <div className="command-row">
        <code className="command data">{text}</code>
        <button
          className="chip"
          aria-label={`Copy: ${label}`}
          onClick={() =>
            void navigator.clipboard.writeText(text).then(() => {
              setCopied(true);
              setTimeout(() => setCopied(false), 1200);
            })
          }
        >
          {copied ? 'copied' : 'copy'}
        </button>
      </div>
    </div>
  );
}

function TokenRow({ t, revoking, onRevoke }: { t: PersonalToken; revoking: boolean; onRevoke: () => void }) {
  const expired = t.expired;
  return (
    <li className="key-row">
      <div className="key-main">
        <span className="key-title">{t.name}</span>
        <span className="data quiet">{t.prefix}…</span>
      </div>
      <span className="data quiet">
        {t.last_used_at ? `used ${t.last_used_at.slice(0, 10)}` : 'never used'}
      </span>
      <span className={expired ? 'data token-expired' : 'data quiet'}>
        {expired ? `expired ${t.expires_at.slice(0, 10)}` : `expires ${t.expires_at.slice(0, 10)}`}
      </span>
      <button className="key-remove" onClick={onRevoke} disabled={revoking} aria-label={`Revoke token ${t.name}`}>
        {revoking ? 'Revoking…' : 'Revoke'}
      </button>
    </li>
  );
}

function Problem({ error }: { error: unknown }) {
  return (
    <div className="problem" role="alert">
      <p>{error instanceof ApiError ? error.message : 'The server did not answer.'}</p>
      {error instanceof ApiError && error.next && <p className="quiet">{error.next}</p>}
    </div>
  );
}
