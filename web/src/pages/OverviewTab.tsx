import { useState } from 'react';
import type { Overview } from '../api';
import { humanBytes } from '../format';

export function OverviewTab({ overview: o, pinned }: { overview: Overview; pinned: string | null }) {
  return (
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
