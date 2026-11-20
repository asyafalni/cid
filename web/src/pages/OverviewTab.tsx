import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Link } from '@tanstack/react-router';
import { getBrowse, getSubsetSize, type Overview } from '../api';
import { extOf } from '../browseFilter';
import { hfRepoId, humanBytes } from '../format';
import { AnnotationOverlay } from '../overlays';
import { Thumb } from '../Thumb';
import { thumbsFor } from '../thumbs';

export function OverviewTab({
  overview: o,
  pinned,
  commit,
  release,
}: {
  overview: Overview;
  pinned: string | null;
  commit: string | null;
  /** The release in the URL, kept on links into Browse. */
  release: string | undefined;
}) {
  return (
    <>
      {commit && o.items > 0 && <LookInside overview={o} commit={commit} release={release} />}
      <div className="dataset-columns">
      <section className="panel card" aria-label={o.kind === 'model' ? 'Model card' : 'Dataset card'}>
        <h2>{o.kind === 'model' ? 'Model card' : 'Dataset card'}</h2>
        <p className="engraved data">
          {o.items.toLocaleString()} {o.items === 1 ? 'item' : 'items'} · {humanBytes(o.bytes)}
          {o.classes.length > 0 && <> · {o.classes.length} classes</>}
        </p>
        {o.policy && (
          <p className="quiet card-policy">
            Annotations made under labelling policy <span className="data">{o.policy}</span>.
          </p>
        )}
        {o.types.length > 0 && (
          <table className="count-table">
            <caption>Items by type</caption>
            <tbody>
              {o.types.slice(0, shownTypes).map((t) => (
                <tr key={t.name}>
                  <td className="data">
                    <Link
                      to="/d/$"
                      params={{ _splat: o.name }}
                      search={{ view: 'browse', release, type: t.name }}
                      aria-label={`Browse the ${t.name} items`}
                    >
                      {t.name}
                    </Link>
                  </td>
                  <td className="data count">{t.count.toLocaleString()}</td>
                  <td className="data count">{humanBytes(t.bytes)}</td>
                </tr>
              ))}
              {o.types.length > shownTypes && (
                <tr>
                  <td className="quiet">{o.types.length - shownTypes} more types</td>
                  <td className="data count">
                    {o.types
                      .slice(shownTypes)
                      .reduce((sum, t) => sum + t.count, 0)
                      .toLocaleString()}
                  </td>
                  <td className="data count">
                    {humanBytes(o.types.slice(shownTypes).reduce((sum, t) => sum + t.bytes, 0))}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        )}
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
        <Lineage overview={o} />
        <p className="quiet">
          Purpose, collection method and known gaps are written by the owners in the dataset's
          card; each release keeps a copy, shown in its git repository's README.
        </p>
      </section>

      <UseThisDataset overview={o} pinned={pinned} commit={commit} />
      </div>
    </>
  );
}

// Lineage at the pinned release (docs/roadmap.md, C3): a model's card says
// what it was trained on, a dataset's which models were trained on it,
// each a link to the other at that release. What the viewer cannot read
// is counted, never named.
function Lineage({ overview: o }: { overview: Overview }) {
  const isModel = o.kind === 'model';
  const links = isModel ? o.trained_on : o.trained_models;
  if (links.length === 0 && o.lineage_unseen === 0) return null;
  const title = isModel ? 'Trained on' : 'Models trained on this release';
  return (
    <section className="lineage" aria-label={title}>
      <h3 className="lineage-title">{title}</h3>
      <ul>
        {links.map((l) => (
          <li key={`${l.dataset}@${l.release}`}>
            <Link to="/d/$" params={{ _splat: l.dataset }} search={{ release: l.release }} className="data">
              {l.dataset}
            </Link>{' '}
            <span className="release-tag">{l.release}</span>
          </li>
        ))}
      </ul>
      {o.lineage_unseen > 0 && (
        <p className="quiet">
          and {o.lineage_unseen} {o.lineage_unseen === 1 ? (isModel ? 'dataset' : 'model') : isModel ? 'datasets' : 'models'} you
          cannot open.
        </p>
      )}
    </section>
  );
}

/** The card names a dataset's commonest file types; Browse filters by any. */
const shownTypes = 8;

const noneHidden: ReadonlySet<string> = new Set();

// A look inside: eight items spread over the version, the same eight each
// time (chosen by a hash of their paths), as Browse shows them (real
// previews with their annotations drawn, or type tiles), each opening in
// Browse. One request for the sample and one for its thumbnails.
function LookInside({ overview: o, commit, release }: { overview: Overview; commit: string; release: string | undefined }) {
  const sample = useQuery({
    queryKey: ['look-inside', o.name, commit],
    queryFn: async () => {
      const page = await getBrowse(o.name, commit, { limit: 8, facets: false, sample: true });
      const thumbs = await thumbsFor(o.name, page.items);
      return { items: page.items, thumbs: new Map(thumbs.map((t) => [t.hash, t.url])) };
    },
  });
  if (!sample.data || sample.data.items.length === 0) return null;
  const { items, thumbs } = sample.data;
  return (
    <section className="look-inside" aria-label="A look inside">
      <div className="look-inside-head">
        <h2>A look inside</h2>
        <Link to="/d/$" params={{ _splat: o.name }} search={{ view: 'browse', release }}>
          Browse all {o.items.toLocaleString()} {o.items === 1 ? 'item' : 'items'}
        </Link>
      </div>
      <ul className="look-inside-strip">
        {items.map((item) => (
          <li key={item.path}>
            <Link
              to="/d/$"
              params={{ _splat: o.name }}
              search={{ view: 'browse', release, item: item.path }}
              className="tile look-tile"
            >
              {thumbs.has(item.hash) ? (
                item.item_id && item.width && item.height ? (
                  <span className="tile-media">
                    <span className="overlay-fit" style={{ aspectRatio: `${item.width} / ${item.height}` }}>
                      <Thumb src={thumbs.get(item.hash)} alt={item.path} label={extOf(item.path)} lazy>
                        <AnnotationOverlay
                          width={item.width}
                          height={item.height}
                          annotations={item.annotations}
                          hidden={noneHidden}
                          opacity={1}
                        />
                      </Thumb>
                    </span>
                  </span>
                ) : (
                  <Thumb src={thumbs.get(item.hash)} alt={item.path} label={extOf(item.path)} lazy />
                )
              ) : (
                <span className="tile-type data">{extOf(item.path)}</span>
              )}
              <span className="tile-path data">{item.path}</span>
            </Link>
          </li>
        ))}
      </ul>
    </section>
  );
}

function UseThisDataset({
  overview: o,
  pinned,
  commit,
}: {
  overview: Overview;
  pinned: string | null;
  commit: string | null;
}) {
  const formats =
    o.kind === 'annotated' ? (['files', 'jsonl', 'yolo'] as const) : (['files'] as const);
  const defaultFormat = o.kind === 'annotated' ? o.default_format : 'files';
  const [format, setFormat] = useState<string>(defaultFormat);
  const [splits, setSplits] = useState<ReadonlySet<string>>(new Set());
  const [classes, setClasses] = useState<ReadonlySet<string>>(new Set());
  const [copied, setCopied] = useState<'command' | 'snippet' | 'hf' | null>(null);

  // The pinned version's real items, so the size line is a sum, not a
  // guess: counted on the server with the CLI's subset rule (src/client/
  // sync.zig, `narrow`), so it is exactly what the copied command takes.
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
  const hf = hfSnippet(o, pinned);

  function copy(what: 'command' | 'snippet' | 'hf', text: string) {
    void navigator.clipboard.writeText(text).then(() => {
      setCopied(what);
      setTimeout(() => setCopied(null), 1600);
    });
  }

  return (
    <section className="panel panel--release card" aria-label={o.kind === 'model' ? 'Use this model' : 'Use this dataset'}>
      <h2>{o.kind === 'model' ? 'Use this model' : 'Use this dataset'}</h2>
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
              : `${kept.items.toLocaleString()} ${kept.items === 1 ? 'item' : 'items'} · ${humanBytes(kept.bytes)}`}
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

      <section className="snippet" aria-label="With Hugging Face libraries">
        <div className="snippet-head">
          <span className="quiet">Or read it with Hugging Face libraries, no clone</span>
          <button className="action action--quiet" onClick={() => copy('hf', hf)}>
            {copied === 'hf' ? 'Copied' : 'Copy'}
          </button>
        </div>
        <pre className="data">
          <code>{hf}</code>
        </pre>
        <p className="quiet">
          HF_TOKEN is a personal token from your <a href="/tokens">Tokens</a> page. Read only: changes go
          through <code className="data">cid push</code>.
        </p>
      </section>
    </section>
  );
}

// The same version through the Hugging Face door (src/server/hf.zig):
// two environment variables, then the libraries people already use.
function hfSnippet(o: Overview, pinned: string | null): string {
  const id = hfRepoId(o.name);
  const revision = pinned ?? 'main';
  const env = `# export HF_ENDPOINT=${location.origin} HF_TOKEN=<your cid personal token>\n`;
  if (o.kind === 'model') {
    return `${env}from transformers import AutoModel\n\nmodel = AutoModel.from_pretrained("${id}", revision="${revision}")`;
  }
  return `${env}from datasets import load_dataset\n\nds = load_dataset("${id}", revision="${revision}")`;
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
