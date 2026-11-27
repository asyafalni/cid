import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Link } from '@tanstack/react-router';
import { ApiError, commitAlias, getBrowse, getDeployKeys, getSubsetSize, type Overview, type Pin } from '../api';
import { extOf, textLike } from '../browseFilter';
import { hfRepoId, humanBytes } from '../format';
import { AnnotationOverlay } from '../overlays';
import { Thumb } from '../Thumb';
import { thumbsFor } from '../thumbs';
import { Bar } from '../Skeleton';
import { BarTable } from '../Bars';
import { classColor } from '../shapes';
import { TextTile } from '../TextTile';
import { TypeTile } from '../TypeTile';
import { Icon } from '../icons';

export function OverviewTab({
  overview: o,
  pinned,
  commit,
  pin,
}: {
  overview: Overview;
  pinned: string | null;
  commit: string | null;
  /** What the page is pinned to, kept on links into Browse. */
  pin: Pin;
}) {
  return (
    <>
      {commit && o.items > 0 && <LookInside overview={o} commit={commit} pin={pin} />}
      <div className="dataset-columns">
      <section className="panel card" aria-label={o.kind === 'model' ? 'Model card' : 'Dataset card'}>
        <h2>{o.kind === 'model' ? 'Model card' : 'Dataset card'}</h2>
        <p className="engraved data">
          {o.items.toLocaleString()} {o.items === 1 ? 'item' : 'items'} · {humanBytes(o.bytes)}
          {o.classes.length > 0 && <> · {o.classes.length} classes</>}
        </p>
        {/* The pinned release's own words, when its maker gave it any. */}
        {pinned && o.commits.find((c) => c.release === pinned)?.notes && (
          <p className="release-notes">
            <span className="release-tag">{pinned}</span> {o.commits.find((c) => c.release === pinned)!.notes}
          </p>
        )}
        {o.policy && (
          <p className="quiet card-policy">
            Annotations made under labelling policy <span className="data">{o.policy}</span>.
          </p>
        )}
        {o.types.length > 0 && (
          <table className="count-table">
            <caption>Items by type</caption>
            <thead>
              <tr>
                <th scope="col">type</th>
                <th scope="col" className="count">
                  items
                </th>
                <th scope="col" className="count">
                  size
                </th>
              </tr>
            </thead>
            <tbody>
              {o.types.slice(0, shownTypes).map((t) => (
                <tr key={t.name}>
                  <td className="data">
                    <Link
                      to="/d/$"
                      params={{ _splat: o.name }}
                      search={{ view: 'browse', ...pin, type: t.name }}
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
          // Class balance: most first, each class in its overlay colour.
          <BarTable
            caption="Annotations by class"
            noun="annotations"
            rows={o.classes.map((c) => ({ name: c.name, value: c.count, dot: classColor(c.name) }))}
          />
        )}
        {o.splits.length > 0 && (
          <BarTable caption="Items by split" noun="items" rows={o.splits.map((s) => ({ name: s.name, value: s.count }))} />
        )}
        <Lineage overview={o} />
        <DeployKeys name={o.name} noun={o.kind === 'model' ? 'model' : 'dataset'} />
        <p className="quiet">
          Purpose, collection method and known gaps are written by the owners in the{' '}
          {o.kind === 'model' ? "model's" : "dataset's"} card; each release keeps a copy, shown in its git repository's README.
        </p>
      </section>

      <UseThisDataset overview={o} pinned={pinned} commit={commit} pin={pin} />
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

/** A file whose name starts with a dot: cid's or a tool's settings, not data. */
function dotfile(path: string): boolean {
  return (path.split('/').pop() ?? '').startsWith('.');
}

// A look inside: eight items spread over the version, the same eight each
// time (chosen by a hash of their paths), as Browse shows them (real
// previews with their annotations drawn, or type tiles), each opening in
// Browse. One request for a wider sample and one for its thumbnails; the
// eight shown are those with a picture first, a settings file such as
// .cidkeys last, in the sample's own order.
const shown_inside = 8;
const sampled_inside = 24;
function LookInside({ overview: o, commit, pin }: { overview: Overview; commit: string; pin: Pin }) {
  const sample = useQuery({
    queryKey: ['look-inside', o.name, commit],
    queryFn: async () => {
      const page = await getBrowse(o.name, commit, { limit: sampled_inside, facets: false, sample: true });
      const thumbs = new Map((await thumbsFor(o.name, page.items)).map((t) => [t.hash, t.url]));
      const rank = (path: string, hash: string) => (thumbs.has(hash) ? 0 : 1) + (dotfile(path) ? 2 : 0);
      const items = page.items
        .map((item, i) => ({ item, i }))
        .sort((x, y) => rank(x.item.path, x.item.hash) - rank(y.item.path, y.item.hash) || x.i - y.i)
        .slice(0, shown_inside)
        .map((x) => x.item);
      return { items, thumbs };
    },
  });
  // Its room is kept while the sample is on its way (U3: nothing jumps).
  if (sample.isPending)
    return (
      <section className="look-inside" aria-label="A look inside" aria-busy="true">
        <div className="look-inside-head">
          <h2>A look inside</h2>
        </div>
        <ul className="look-inside-strip">
          {Array.from({ length: Math.min(shown_inside, o.items) }, (_, i) => (
            <li key={i}>
              <span className="tile look-tile tile--skeleton">
                <span className="skeleton-block tile-skeleton-media" />
                <Bar width="60%" />
              </span>
            </li>
          ))}
        </ul>
      </section>
    );
  if (!sample.data || sample.data.items.length === 0) return null;
  const { items, thumbs } = sample.data;
  return (
    <section className="look-inside" aria-label="A look inside">
      <div className="look-inside-head">
        <h2>A look inside</h2>
        <Link to="/d/$" params={{ _splat: o.name }} search={{ view: 'browse', ...pin }}>
          Browse all {o.items.toLocaleString()} {o.items === 1 ? 'item' : 'items'}
        </Link>
      </div>
      <ul className="look-inside-strip">
        {items.map((item) => (
          <li key={item.path}>
            <Link
              to="/d/$"
              params={{ _splat: o.name }}
              search={{ view: 'browse', ...pin, item: item.path }}
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
              ) : textLike.test(item.path) ? (
                <TextTile name={o.name} hash={item.hash} path={item.path} restricted={o.restricted} />
              ) : (
                <TypeTile path={item.path} />
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
  pin,
}: {
  overview: Overview;
  pinned: string | null;
  commit: string | null;
  pin: Pin;
}) {
  // A commit pinned with no release on it, or another branch's head: the
  // clone, then a checkout of it.
  const atCommit = pinned === null && pin.commit !== undefined && commit !== null ? commit : null;
  const atBranch = pinned === null && atCommit === null && pin.branch !== undefined ? pin.branch : null;
  const formats =
    o.kind === 'annotated' ? (['files', 'jsonl', 'yolo', 'coco', 'voc'] as const) : (['files'] as const);
  const defaultFormat = o.kind === 'annotated' ? o.default_format : 'files';
  const [format, setFormat] = useState<string>(defaultFormat);
  const [splits, setSplits] = useState<ReadonlySet<string>>(new Set());
  const [classes, setClasses] = useState<ReadonlySet<string>>(new Set());
  const [copied, setCopied] = useState<'command' | 'snippet' | 'hf' | null>(null);
  // One tab per way in (roadmap U13): the cid command, the Hugging Face
  // libraries through the door, and an agent's client through the MCP
  // door. Each is what a test drives for real (tests/hf_client.sh,
  // tests/mcp_client.sh); nothing is offered that nobody ran.
  type Way = 'cid' | 'lib' | 'hub' | 'fiftyone' | 'agent';
  const ways: (readonly [Way, string])[] = [
    ['cid', 'cid'],
    ['lib', o.kind === 'model' ? 'transformers' : 'datasets'],
    ['hub', 'huggingface_hub'],
    // An annotated dataset's yolo clone opens in FiftyOne as it is
    // (tests/fiftyone_client.sh loads one for real).
    ...(o.kind === 'annotated' ? ([['fiftyone', 'FiftyOne']] as const) : []),
    ['agent', 'AI agent'],
  ];
  const [way, setWay] = useState<Way>('cid');

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
    .join(' ')
    .concat(atCommit ? ` && cd ${folder} && cid checkout ${atCommit}` : atBranch ? ` && cd ${folder} && cid checkout ${atBranch}` : '');
  const snippet = pythonFor(format, folder);
  const revision = pinned ?? (atCommit ? commitAlias(atCommit) : atBranch);
  const hf =
    way === 'hub'
      ? hubSnippet(o, revision)
      : way === 'agent'
        ? agentSnippet()
        : way === 'fiftyone'
          ? fiftyoneSnippet(o, pinned, folder)
          : hfSnippet(o, revision);

  function copy(what: 'command' | 'snippet' | 'hf', text: string) {
    void navigator.clipboard.writeText(text).then(() => {
      setCopied(what);
      setTimeout(() => setCopied(null), 1600);
    });
  }

  return (
    <section className="panel panel--release card" aria-label={o.kind === 'model' ? 'Use this model' : 'Use this dataset'}>
      <h2>{o.kind === 'model' ? 'Use this model' : 'Use this dataset'}</h2>
      <div className="use-tabs" role="tablist" aria-label="Ways to use it">
        {ways.map(([id, label], i) => (
          <button
            key={id}
            id={`use-tab-${id}`}
            role="tab"
            aria-selected={way === id}
            aria-controls="use-panel"
            tabIndex={way === id ? 0 : -1}
            className={way === id ? 'use-tab use-tab--on' : 'use-tab'}
            onClick={() => setWay(id)}
            // The arrows move along the tabs, as tabs do.
            onKeyDown={(e) => {
              const step = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
              if (step === 0) return;
              e.preventDefault();
              const next = ways[(i + step + ways.length) % ways.length][0];
              setWay(next);
              document.getElementById(`use-tab-${next}`)?.focus();
            }}
          >
            {label}
          </button>
        ))}
      </div>

      <div id="use-panel" role="tabpanel" aria-labelledby={`use-tab-${way}`}>
        {way === 'cid' ? (
          <>
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
            <code className="command data" tabIndex={0}>{command}</code>
            <button className="action" onClick={() => copy('command', command)}>
              <Icon name={copied === 'command' ? 'pass' : 'copy'} /> {copied === 'command' ? 'Copied' : 'Copy'}
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
            {pinned
              ? `Pinned to ${pinned}.`
              : atCommit
                ? `Pinned to commit ${atCommit.slice(0, 13)}, which is not a release.`
                : atBranch
                  ? `The newest commit on ${atBranch}, a draft line of work.`
                  : 'No releases yet, so this clones the newest commit.'}
          </p>

          <div className="snippet">
            <div className="snippet-head">
              <span className="quiet">Then, in Python</span>
              <button className="action action--quiet" onClick={() => copy('snippet', snippet)}>
                <Icon name={copied === 'snippet' ? 'pass' : 'copy'} /> {copied === 'snippet' ? 'Copied' : 'Copy'}
              </button>
            </div>
            <pre className="data">
              <code>{snippet}</code>
            </pre>
          </div>
          </>
        ) : (
          <section
            className="snippet snippet--first"
            aria-label={way === 'agent' ? 'With an AI agent' : way === 'fiftyone' ? 'In FiftyOne' : 'With Hugging Face libraries'}
          >
            <div className="snippet-head">
              <span className="quiet">
                {way === 'agent'
                  ? 'Give an agent this server to read, no clone'
                  : way === 'fiftyone'
                    ? 'Clone it as yolo, then open it in FiftyOne'
                    : way === 'hub'
                      ? 'The files of this version, into the Hugging Face cache'
                    : 'Read it with Hugging Face libraries, no clone'}
              </span>
              <button className="action action--quiet" onClick={() => copy('hf', hf)}>
                <Icon name={copied === 'hf' ? 'pass' : 'copy'} /> {copied === 'hf' ? 'Copied' : 'Copy'}
              </button>
            </div>
            <pre className="data">
              <code>{hf}</code>
            </pre>
            {way === 'agent' ? (
              <p className="quiet">
                The token is a personal one from your <a href="/tokens">Tokens</a> page; any MCP client takes the
                same address. Then ask it about <code className="data">{o.name}</code>
                {revision ? (
                  <>
                    {' '}
                    at <code className="data">{revision}</code>
                  </>
                ) : null}
                : its releases, items, what changed, its health. Read only.
              </p>
            ) : way === 'fiftyone' ? (
              <p className="quiet">
                The first line is a shell command; your SSH key is the login. A split at a time:{' '}
                {o.splits.length > 0 ? o.splits.map((x) => x.name).join(', ') : 'this version has none, and FiftyOne asks for one'}.
                Annotations change in the annotation platform, not in FiftyOne.
              </p>
            ) : (
              <p className="quiet">
                HF_TOKEN is a personal token from your <a href="/tokens">Tokens</a> page. Read only: changes go
                through <code className="data">cid push</code>.
              </p>
            )}
          </section>
        )}
      </div>
    </section>
  );
}

// The files of a version through the same door, as huggingface_hub
// downloads them: a folder in its cache, each file checked.
function hubSnippet(o: Overview, pinned: string | null): string {
  const env = `# export HF_ENDPOINT=${location.origin} HF_TOKEN=<your cid personal token>\n`;
  const kind = o.kind === 'model' ? '' : 'repo_type="dataset", ';
  return `${env}from huggingface_hub import snapshot_download\n\nfolder = snapshot_download("${hfRepoId(o.name)}", ${kind}revision="${pinned ?? 'main'}")`;
}

// FiftyOne reads a yolo clone with no argument but the split: cid keeps
// the images under images/, where FiftyOne looks for them.
function fiftyoneSnippet(o: Overview, pinned: string | null, folder: string): string {
  const split = o.splits.some((x) => x.name === 'train') ? 'train' : (o.splits[0]?.name ?? 'train');
  const clone = `cid clone cid@${location.hostname}:${o.name}${pinned ? ` --release ${pinned}` : ''} --format yolo`;
  return `# ${clone}\nimport fiftyone as fo\n\nds = fo.Dataset.from_dir(\n    dataset_dir="${folder}",\n    dataset_type=fo.types.YOLOv5Dataset,\n    split="${split}",\n)\nfo.launch_app(ds)`;
}

// The MCP door (src/server/mcp.zig): one line makes this server's read
// tools an agent's.
function agentSnippet(): string {
  return `claude mcp add --transport http cid ${location.origin}/mcp \\\n  --header "Authorization: Bearer <your cid personal token>"`;
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
          className={chosen.has(v) ? 'subset-chip subset-chip--on' : 'subset-chip'}
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
      <span className="quiet subset-hint">{chosen.size === 0 ? 'all of them; pick to narrow' : `${chosen.size} picked`}</span>
    </div>
  );
}

// Two lines that read the folder the command just wrote. Documentation
// shaped as code: cid ships no Python package, and needs none.
function pythonFor(format: string, folder: string): string {
  if (format === 'yolo') {
    return `from ultralytics import YOLO\n\nYOLO("yolov8n.pt").train(data="${folder}/dataset.yaml")`;
  }
  if (format === 'coco') {
    return `from pycocotools.coco import COCO\n\ncoco = COCO("${folder}/annotations/instances_train.json")`;
  }
  if (format === 'voc') {
    return `import xml.etree.ElementTree as ET\n\nids = open("${folder}/ImageSets/Main/train.txt").read().split()\nboxes = {i: ET.parse(f"${folder}/Annotations/{i}.xml").findall("object") for i in ids}`;
  }
  if (format === 'jsonl') {
    return `import json\n\nitems = [json.loads(line) for line in open("${folder}/annotations.jsonl")]`;
  }
  return `from pathlib import Path\n\nfiles = sorted(p for p in Path("${folder}").rglob("*")\n               if p.is_file() and ".cid" not in p.parts)`;
}

// A dataset's deploy keys, for its owners: read here, changed with
// `cid deploy-key` (invariant 17: the dashboard changes no data). Anyone
// else is refused by the server, and sees nothing of them.
function DeployKeys({ name, noun }: { name: string; noun: string }) {
  const keys = useQuery({
    queryKey: ['deploy-keys', name],
    queryFn: () => getDeployKeys(name),
    retry: (count, err) => !(err instanceof ApiError && (err.status === 401 || err.status === 403)) && count < 2,
  });
  if (!keys.data) return null;
  return (
    <section className="deploy-keys" aria-label="Deploy keys">
      <table className="count-table">
        <caption>Deploy keys (owners only)</caption>
        <tbody>
          {keys.data.keys.map((k) => (
            <tr key={k.name} title={k.fingerprint}>
              <td className="data">{k.name}</td>
              <td>{k.level}</td>
              <td className="quiet">last used {k.last_used_at ? k.last_used_at.slice(0, 10) : 'never'}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="quiet">
        {keys.data.keys.length === 0 ? 'None yet. ' : ''}A machine (CI) reaches this {noun} with its own SSH key:{' '}
        <code className="data">cid deploy-key add &lt;name&gt; &lt;key.pub&gt; [--write]</code> in a clone.
      </p>
    </section>
  );
}
