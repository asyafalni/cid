import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ApiError, addKey, getMe, listKeys, removeKey, type SshKey } from '../api';

// Your SSH keys (docs/access.md): the identity `cid clone`, `pull` and
// `push` sign in with, as git does. A key added here works over SSH at
// once; a key from GitLab is listed but managed in GitLab. One key belongs
// to one account, so a key someone already registered is refused.
export function Keys() {
  const me = useQuery({ queryKey: ['me'], queryFn: getMe });
  const person = me.data?.via === 'gitlab';
  const keys = useQuery({ queryKey: ['keys'], queryFn: listKeys, enabled: person });
  const client = useQueryClient();
  const [title, setTitle] = useState('');
  const [text, setText] = useState('');

  const add = useMutation({
    mutationFn: () => addKey(title, text),
    onSuccess: (got) => {
      client.setQueryData(['keys'], { keys: got.keys });
      setTitle('');
      setText('');
    },
  });
  const remove = useMutation({
    mutationFn: (fingerprint: string) => removeKey(fingerprint),
    onSuccess: (got) => client.setQueryData(['keys'], { keys: got.keys }),
  });

  return (
    <section className="keys">
      <header className="deck-head">
        <h1>SSH keys</h1>
        <p className="quiet">
          cid knows you by your SSH key, the way git does: <code className="data">cid clone</code>,{' '}
          <code className="data">pull</code> and <code className="data">push</code> sign in with it.
        </p>
      </header>

      {me.data && !person && (
        <div className="panel notice" role="status">
          <p>You are signed in with the server token, which belongs to no one and has no keys.</p>
          <p className="quiet">Sign out, then choose Sign in with GitLab to manage your own.</p>
        </div>
      )}

      {person && keys.isPending && <p className="quiet">Reading your keys…</p>}
      {person && keys.isError && <Problem error={keys.error} />}
      {person &&
        keys.data &&
        (keys.data.keys.length === 0 ? (
          <div className="empty blueprint">
            <p>No keys yet. Add the public half of the key you use for git.</p>
          </div>
        ) : (
          <ul className="key-list panel" aria-label="Your keys">
            {keys.data.keys.map((k) => (
              <KeyRow
                key={k.fingerprint}
                k={k}
                removing={remove.isPending && remove.variables === k.fingerprint}
                onRemove={() => remove.mutate(k.fingerprint)}
              />
            ))}
          </ul>
        ))}
      {remove.isError && <Problem error={remove.error} />}

      {person && (
        <form
          className="key-add panel"
          onSubmit={(e) => {
            e.preventDefault();
            add.mutate();
          }}
        >
          <h2>Add a key</h2>
          <label htmlFor="key-title">Title</label>
          <input
            id="key-title"
            value={title}
            maxLength={100}
            placeholder="work laptop"
            onChange={(e) => setTitle(e.target.value)}
          />
          <label htmlFor="key-text">Public key</label>
          <textarea
            id="key-text"
            value={text}
            rows={3}
            spellCheck={false}
            placeholder="ssh-ed25519 AAAA… you@laptop"
            onChange={(e) => setText(e.target.value)}
          />
          <p className="quiet key-hint">
            Paste the one line of your <code className="data">.pub</code> file. No key yet? Make one with{' '}
            <code className="data">ssh-keygen -t ed25519</code>, then paste{' '}
            <code className="data">~/.ssh/id_ed25519.pub</code>.
          </p>
          <button type="submit" className="action" disabled={add.isPending || text.trim() === ''}>
            {add.isPending ? 'Adding…' : 'Add key'}
          </button>
          <div aria-live="polite">{add.isError && <Problem error={add.error} />}</div>
        </form>
      )}
    </section>
  );
}

function KeyRow({ k, removing, onRemove }: { k: SshKey; removing: boolean; onRemove: () => void }) {
  return (
    <li className="key-row">
      <div className="key-main">
        <span className="key-title">{k.title || 'untitled key'}</span>
        <span className="data quiet">{k.key_type}</span>
      </div>
      <Fingerprint value={k.fingerprint} />
      <span className="data quiet key-added">added {k.added_at.slice(0, 10)}</span>
      {k.source === 'dashboard' ? (
        <button
          className="action action--quiet"
          onClick={onRemove}
          disabled={removing}
          aria-label={`Remove key ${k.title || k.fingerprint}`}
        >
          {removing ? 'Removing…' : 'Remove'}
        </button>
      ) : (
        <span
          className="chip"
          title={
            k.source === 'gitlab'
              ? 'Remove it in GitLab; cid drops it at the next sync.'
              : 'Ask the administrator to remove it.'
          }
        >
          {k.source === 'gitlab' ? 'from GitLab' : 'by an administrator'}
        </span>
      )}
    </li>
  );
}

// The fingerprint as OpenSSH prints it, copied whole on click.
function Fingerprint({ value }: { value: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      className="chip key-fingerprint"
      title={`${value} — copy`}
      onClick={() =>
        void navigator.clipboard.writeText(value).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 1200);
        })
      }
    >
      {copied ? 'copied' : `${value.slice(0, 19)}…`}
    </button>
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
