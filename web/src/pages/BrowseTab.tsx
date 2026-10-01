import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import {
  getDownloads,
  getState,
  getThumbs,
  type Overview,
  type StateAnnotation,
  type StateItem,
} from '../api';
import { humanBytes } from '../format';

// Browse: never "viewer not available". Every item renders — as its
// thumbnail when the worker has built one, as a type tile when not —
// and one broken file only ever breaks its own tile.
export function BrowseTab({
  name,
  overview,
  commit,
  openItem,
  onOpenItem,
}: {
  name: string;
  overview: Overview;
  commit: string | null;
  openItem: string | undefined;
  onOpenItem: (path: string | undefined) => void;
}) {
  const [mode, setMode] = useState<'gallery' | 'table'>('gallery');

  const state = useQuery({
    queryKey: ['state', name, commit],
    queryFn: () => getState(name, commit!),
    enabled: commit !== null,
  });
  const imageHashes =
    state.data?.items
      .filter((i) => looksVisual(i.path))
      .map((i) => i.hash)
      .slice(0, 500) ?? [];
  const thumbs = useQuery({
    queryKey: ['thumbs', name, commit, imageHashes.length],
    queryFn: () => getThumbs(name, imageHashes),
    enabled: imageHashes.length > 0,
  });

  if (commit === null) return <p className="quiet">Nothing to browse until the first push.</p>;
  if (state.isPending) return <p className="quiet">Reading the manifest…</p>;
  if (state.isError) {
    return (
      <div className="panel notice" role="alert">
        <p>Could not read this version. Run the link again, or pick another release.</p>
      </div>
    );
  }

  const items = state.data.items;
  const annotations = state.data.annotations ?? [];
  const thumbByHash = new Map((thumbs.data?.thumbs ?? []).map((t) => [t.hash, t.url]));
  const annsByItem = groupAnnotations(annotations);
  const open = items.find((i) => i.path === openItem);

  return (
    <div className="browse">
      <div className="browse-bar">
        <div className="format-picker" role="radiogroup" aria-label="View">
          {(['gallery', 'table'] as const).map((m) => (
            <button
              key={m}
              role="radio"
              aria-checked={mode === m}
              className={mode === m ? 'format on' : 'format'}
              onClick={() => setMode(m)}
            >
              {m}
            </button>
          ))}
        </div>
        <p className="quiet data">{items.length.toLocaleString()} items</p>
      </div>

      {items.length === 0 ? (
        <div className="empty blueprint">
          <h2>This version is empty</h2>
          <p>Every item was deleted by this point in history.</p>
        </div>
      ) : mode === 'gallery' ? (
        <ul className="gallery">
          {items.map((item) => (
            <li key={item.path}>
              <button
                className={openItem === item.path ? 'tile tile--open' : 'tile'}
                onClick={() => onOpenItem(item.path)}
                aria-pressed={openItem === item.path}
              >
                {thumbByHash.has(item.hash) ? (
                  <img src={thumbByHash.get(item.hash)} alt={item.path} loading="lazy" />
                ) : (
                  <span className="tile-type data">{extOf(item.path)}</span>
                )}
                <span className="tile-path data">{item.path}</span>
              </button>
            </li>
          ))}
        </ul>
      ) : (
        <table className="browse-table">
          <thead>
            <tr>
              <th>path</th>
              <th>size</th>
              <th>split</th>
              <th>hash</th>
            </tr>
          </thead>
          <tbody>
            {items.map((item) => (
              <tr
                key={item.path}
                className={openItem === item.path ? 'row--open' : undefined}
                onClick={() => onOpenItem(item.path)}
              >
                <td className="data">{item.path}</td>
                <td className="data">{humanBytes(item.size)}</td>
                <td>{item.split ?? '—'}</td>
                <td>
                  <HashChip hash={item.hash} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {open && (
        <ItemDrawer
          name={name}
          item={open}
          annotated={overview.kind === 'annotated'}
          annotations={open.item_id ? (annsByItem.get(open.item_id) ?? []) : []}
          thumb={thumbByHash.get(open.hash)}
          onClose={() => onOpenItem(undefined)}
        />
      )}
    </div>
  );
}

function ItemDrawer({
  name,
  item,
  annotated,
  annotations,
  thumb,
  onClose,
}: {
  name: string;
  item: StateItem;
  annotated: boolean;
  annotations: StateAnnotation[];
  thumb: string | undefined;
  onClose: () => void;
}) {
  const download = useQuery({
    queryKey: ['download', name, item.hash],
    queryFn: () => getDownloads(name, [item.hash]),
  });
  const url = download.data?.downloads[0]?.url;

  return (
    <aside className="drawer panel" aria-label={item.path}>
      <div className="drawer-head">
        <h2 className="data drawer-path">{item.path}</h2>
        <button className="drawer-close" onClick={onClose} aria-label="Close">
          ✕
        </button>
      </div>
      {thumb ? (
        <img className="drawer-media" src={thumb} alt={item.path} />
      ) : (
        <div className="drawer-media drawer-media--none blueprint">
          <span className="data">{extOf(item.path)}</span>
          <p className="quiet">No preview for this file type yet; the bytes are one click away.</p>
        </div>
      )}
      <dl className="drawer-facts">
        <dt>size</dt>
        <dd className="data">{humanBytes(item.size)}</dd>
        {item.split && (
          <>
            <dt>split</dt>
            <dd>{item.split}</dd>
          </>
        )}
        {item.width && item.height && (
          <>
            <dt>dimensions</dt>
            <dd className="data">
              {item.width}×{item.height}
            </dd>
          </>
        )}
        <dt>sha-256</dt>
        <dd>
          <HashChip hash={item.hash} />
        </dd>
      </dl>
      {annotated && (
        <section aria-label="Annotations">
          <h3>Annotations</h3>
          {annotations.length === 0 ? (
            <p className="quiet">None on this item at this version.</p>
          ) : (
            <ul className="ann-list">
              {annotations.map((a) => (
                <li key={a.id}>
                  <span className="chip">{a.kind ?? '?'}</span> {a.class ?? '—'}
                  <span className="quiet"> — {a.author}</span>
                </li>
              ))}
            </ul>
          )}
        </section>
      )}
      {url && (
        <a className="action drawer-download" href={url} download>
          Download the file
        </a>
      )}
    </aside>
  );
}

function HashChip({ hash }: { hash: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      className="chip"
      title="Copy the full hash"
      onClick={(e) => {
        e.stopPropagation();
        void navigator.clipboard.writeText(hash).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 1200);
        });
      }}
    >
      {copied ? 'copied' : hash.slice(0, 6)}
    </button>
  );
}

function groupAnnotations(annotations: StateAnnotation[]): Map<string, StateAnnotation[]> {
  const map = new Map<string, StateAnnotation[]>();
  for (const a of annotations) {
    const list = map.get(a.item_id);
    if (list) list.push(a);
    else map.set(a.item_id, [a]);
  }
  return map;
}

function extOf(path: string): string {
  const base = path.slice(path.lastIndexOf('/') + 1);
  const dot = base.lastIndexOf('.');
  return dot > 0 ? base.slice(dot) : 'file';
}

function looksVisual(path: string): boolean {
  return /\.(png|jpe?g|gif|webp|bmp|mp4|mov|mkv|avi)$/i.test(path);
}
