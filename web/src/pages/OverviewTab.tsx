import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { getSubsetSize, type Overview } from '../api';
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
  const defaultFormat = o.kind === 'annotated' ? o.default_format : 'files';
  const [format, setFormat] = useState<string>(defaultFormat);
  const [splits, setSplits] = useState<ReadonlySet<string>>(new Set());
  const [classes, setClasses] = useState<ReadonlySet<string>>(new Set());
  const [copied, setCopied] = useState<'command' | 'snippet' | null>(null);

  // The pinned version's real items, so the size line is a sum, not a
  // guess: counted on the server with the CLI's subset rule (src/client/
  // sync.zig, `narrow`), so it is exactly what the copied command takes.
  const commit = o.commits.find((c) => c.release === pinned)?.id ?? o.commits[0]?.id ?? null;
  const size = useQuery({
    queryKey: ['size', o.name, commit, [...splits].sort().join(','), [...classes].sort().join(',')],
    queryFn: () => getSubsetSize(o.name, commit!, [...splits], [...classes]),
    enabled: commit !== null,
  });
  const kept = size.data ?? null;

  const folder = o.name.slice(o.name.lastIndexOf('/') + 1);
  const command = [
    'cid clone',
    `cid@${location.hostname}:${o.name}`,
    pinned ? `--release ${pinned}` : null,
    format !== defaultFormat ? `--format ${format}` : null,
    ...[...splits].sort().map((v) => `--split ${v}`),
    ...[...classes].sort().map((v) => `--class ${v}`),
  ]
    .filter(Boolean)
    .join(' ');
  const snippet = pythonFor(format, folder);

  function copy(what: 'command' | 'snippet', text: string) {
    void navigator.clipboard.writeText(text).then(() => {
      setCopied(what);
      setTimeout(() => setCopied(null), 1600);
    });
  }

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

      {o.splits.length > 0 && (
        <SubsetPicker
          label="Splits"
          values={o.splits.map((x) => x.name)}
          chosen={splits}
          onChange={setSplits}
        />
      )}
      {o.classes.length > 0 && (
        <SubsetPicker
          label="Classes"
          values={o.classes.map((x) => x.name)}
          chosen={classes}
          onChange={setClasses}
        />
      )}

      <div className="command-row">
        <code className="command data">{command}</code>
        <button className="action" onClick={() => copy('command', command)}>
          {copied === 'command' ? 'Copied' : 'Copy'}
        </button>
      </div>
      <p className="quiet data subset-size" aria-live="polite">
        {kept === null
          ? 'Counting…'
          : kept.items === 0
            ? 'No item matches this subset. Pick fewer splits or classes.'
            : splits.size + classes.size > 0
              ? `${kept.items.toLocaleString()} of ${kept.total.toLocaleString()} items · ${humanBytes(kept.bytes)}`
              : `${kept.items.toLocaleString()} items · ${humanBytes(kept.bytes)}`}
      </p>
      <p className="quiet">
        Works as pasted: your SSH key is the login.{' '}
        {pinned ? `Pinned to ${pinned}.` : 'No releases yet, so this clones the newest commit.'}
      </p>

      <div className="snippet">
        <div className="snippet-head">
          <span className="quiet">Then, in Python</span>
          <button className="action action--quiet" onClick={() => copy('snippet', snippet)}>
            {copied === 'snippet' ? 'Copied' : 'Copy'}
          </button>
        </div>
        <pre className="data">
          <code>{snippet}</code>
        </pre>
      </div>
    </section>
  );
}

function SubsetPicker({
  label,
  values,
  chosen,
  onChange,
}: {
  label: string;
  values: string[];
  chosen: ReadonlySet<string>;
  onChange: (next: ReadonlySet<string>) => void;
}) {
  return (
    <div className="subset-picker" role="group" aria-label={label}>
      <span className="quiet subset-label">{label}</span>
      {values.map((v) => (
        <button
          key={v}
          className={chosen.has(v) ? 'class-chip' : 'class-chip class-chip--off'}
          aria-pressed={chosen.has(v)}
          onClick={() => {
            const next = new Set(chosen);
            if (next.has(v)) next.delete(v);
            else next.add(v);
            onChange(next);
          }}
        >
          {v}
        </button>
      ))}
      {chosen.size === 0 && <span className="quiet">all</span>}
    </div>
  );
}

// Two lines that read the folder the command just wrote. Documentation
// shaped as code: cid ships no Python package, and needs none.
function pythonFor(format: string, folder: string): string {
  if (format === 'yolo') {
    return `from ultralytics import YOLO\n\nYOLO("yolov8n.pt").train(data="${folder}/dataset.yaml")`;
  }
  if (format === 'jsonl') {
    return `import json\n\nitems = [json.loads(line) for line in open("${folder}/annotations.jsonl")]`;
  }
  return `from pathlib import Path\n\nfiles = sorted(p for p in Path("${folder}").rglob("*")\n               if p.is_file() and ".cid" not in p.parts)`;
}
