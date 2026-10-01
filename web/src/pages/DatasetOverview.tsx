import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useParams } from '@tanstack/react-router';
import { ApiError, getOverview, type Overview } from '../api';
import { ReleaseTape } from '../ReleaseTape';

export function DatasetOverview() {
  const { _splat: name = '' } = useParams({ strict: false });
  const query = useQuery({
    queryKey: ['overview', name],
    queryFn: () => getOverview(name),
  });
  // The tape's selection pins the page: null = the newest release, or
  // the head when none exists yet.
  const [selected, setSelected] = useState<string | null>(null);

  if (query.isPending) return <p className="quiet">Reading {name}…</p>;
  if (query.isError) {
    const err = query.error;
    return (
      <div className="panel notice" role="alert">
        <p>{err instanceof ApiError ? err.message : 'The server did not answer.'}</p>
        {err instanceof ApiError && err.next && <p className="quiet">{err.next}</p>}
      </div>
    );
  }

  const o = query.data;
  const releases = o.commits.filter((c) => c.release !== null);
  const pinned = selected ?? releases[0]?.release ?? null;

  return (
    <article className="dataset">
      <header className="dataset-head sky-band">
        <div className="dataset-head-inner">
          <h1 className="data dataset-name">{o.name}</h1>
          <p className="dataset-meta">
            {o.kind === 'annotated' ? 'annotated dataset' : 'file dataset'}
            {' — '}
            <a href={gitWebUrl(o.git_url)} target="_blank" rel="noreferrer">
              view in git
            </a>
          </p>
        </div>
      </header>

      <ReleaseTape commits={o.commits} pinned={pinned} onPick={setSelected} />

      <div className="dataset-columns">
        <section className="panel card" aria-label="Dataset card">
          <h2>Dataset card</h2>
          <p className="engraved data">
            {o.items.toLocaleString()} items · {humanBytes(o.bytes)}
            {o.classes.length > 0 && <> · {o.classes.length} classes</>}
          </p>
          {o.classes.length > 0 && (
            <table className="count-table">
              <caption>Annotations by class</caption>
              <tbody>
                {o.classes.map((c, i) => (
                  <tr key={c.name}>
                    <td className="data">{i}</td>
                    <td>{c.name}</td>
                    <td className="data count">{c.count.toLocaleString()}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {o.splits.length > 0 && (
            <table className="count-table">
              <caption>Items by split</caption>
              <tbody>
                {o.splits.map((s) => (
                  <tr key={s.name}>
                    <td>{s.name}</td>
                    <td className="data count">{s.count.toLocaleString()}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          <p className="quiet">
            Purpose, collection method and known gaps are written by the owners; card editing
            arrives with the access slice.
          </p>
        </section>

        <UseThisDataset overview={o} pinned={pinned} />
      </div>
    </article>
  );
}

function UseThisDataset({ overview: o, pinned }: { overview: Overview; pinned: string | null }) {
  const formats =
    o.kind === 'annotated' ? (['files', 'jsonl', 'yolo'] as const) : (['files'] as const);
  const [format, setFormat] = useState<string>(
    o.kind === 'annotated' ? o.default_format : 'files',
  );
  const [copied, setCopied] = useState(false);

  const command = [
    'cid clone',
    `cid@${location.hostname}:${o.name}`,
    pinned ? `--release ${pinned}` : null,
    format !== (o.kind === 'annotated' ? o.default_format : 'files') ? `--format ${format}` : null,
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <section className="panel panel--release card" aria-label="Use this dataset">
      <h2>Use this dataset</h2>
      {formats.length > 1 && (
        <div className="format-picker" role="radiogroup" aria-label="Export format">
          {formats.map((f) => (
            <button
              key={f}
              role="radio"
              aria-checked={format === f}
              className={format === f ? 'format on' : 'format'}
              onClick={() => setFormat(f)}
            >
              {f}
            </button>
          ))}
        </div>
      )}
      <div className="command-row">
        <code className="command data">{command}</code>
        <button
          className="action"
          onClick={() => {
            void navigator.clipboard.writeText(command).then(() => {
              setCopied(true);
              setTimeout(() => setCopied(false), 1600);
            });
          }}
        >
          {copied ? 'Copied' : 'Copy'}
        </button>
      </div>
      <p className="quiet">
        Works as pasted: your SSH key is the login.{' '}
        {pinned ? `Pinned to ${pinned}.` : 'No releases yet, so this clones the newest commit.'}
      </p>
    </section>
  );
}

function gitWebUrl(gitUrl: string): string {
  // git@host:path.git → https://host/path — a convenience, not a promise.
  const ssh = gitUrl.match(/^git@([^:]+):(.+?)(\.git)?$/);
  if (ssh) return `https://${ssh[1]}/${ssh[2]}`;
  return gitUrl;
}

function humanBytes(n: number): string {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = n;
  let u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u += 1;
  }
  return u === 0 ? `${n} B` : `${v.toFixed(1)} ${units[u]}`;
}
