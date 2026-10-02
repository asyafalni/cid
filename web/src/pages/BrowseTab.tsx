import { useEffect, useState } from 'react';
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
import { AnnotationOverlay, classColor } from '../overlays';
import {
  anyFilter,
  applyFilters,
  classesByItem,
  extOf,
  facet,
  type FilterPatch,
  type Filters,
} from '../browseFilter';

// Browse: never "viewer not available". Every item renders — as its
// thumbnail when the worker has built one, as a type tile when not —
// and one broken file only ever breaks its own tile.
export function BrowseTab({
  name,
  overview,
  commit,
  openItem,
  onOpenItem,
  filters,
  onFilters,
}: {
  name: string;
  overview: Overview;
  commit: string | null;
  openItem: string | undefined;
  onOpenItem: (path: string | undefined) => void;
  filters: Filters;
  onFilters: (patch: FilterPatch) => void;
}) {
  const mode: 'gallery' | 'table' = filters.mode === 'table' ? 'table' : 'gallery';
  const setMode = (m: 'gallery' | 'table') => onFilters({ mode: m === 'table' ? 'table' : undefined });

  // `g` and `t`, the toggles docs/dashboard.md names — never while typing.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === 'g') onFilters({ mode: undefined });
      if (e.key === 't') onFilters({ mode: 'table' });
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onFilters]);

  // The search box commits to the URL after a pause, so typing a word is
  // one history entry, not one per letter.
  const [typed, setTyped] = useState(filters.q ?? '');
  useEffect(() => setTyped(filters.q ?? ''), [filters.q]);
  useEffect(() => {
    if (typed === (filters.q ?? '')) return;
    const timer = setTimeout(() => onFilters({ q: typed === '' ? undefined : typed }), 250);
    return () => clearTimeout(timer);
  }, [typed, filters.q, onFilters]);
  // Overlay affordances: which classes are hidden, and how loud the
  // shapes are. View affordances, not filters, so they stay local;
  // the filters that belong in the URL arrive with the filter slice.
  const [hidden, setHidden] = useState<ReadonlySet<string>>(new Set());
  const [opacity, setOpacity] = useState(0.9);

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

  const all = state.data.items;
  const annotations = state.data.annotations ?? [];
  const itemClasses = classesByItem(annotations);
  const items = applyFilters(all, filters, itemClasses);
  const splitFacet = facet(all, filters, itemClasses, 'split');
  const classFacet = facet(all, filters, itemClasses, 'cls');
  const typeFacet = facet(all, filters, itemClasses, 'type');
  const filtered = anyFilter(filters);
  const thumbByHash = new Map((thumbs.data?.thumbs ?? []).map((t) => [t.hash, t.url]));
  const annsByItem = groupAnnotations(annotations);
  const classes = classCounts(annotations);
  const open = all.find((i) => i.path === openItem);

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
        <p className="quiet data" aria-live="polite">
          {filtered
            ? `${items.length.toLocaleString()} of ${all.length.toLocaleString()} items`
            : `${all.length.toLocaleString()} items`}
        </p>
      </div>

      {all.length > 0 && (
        <div className="filter-bar" role="search">
          <input
            type="search"
            className="filter-q data"
            placeholder="path contains…"
            aria-label="Filter by path"
            value={typed}
            onChange={(e) => setTyped(e.target.value)}
          />
          <FacetSelect
            label="split"
            facets={splitFacet}
            value={filters.split}
            blank="no split"
            onChange={(v) => onFilters({ split: v })}
          />
          {classFacet.length > 0 && (
            <FacetSelect
              label="class"
              facets={classFacet}
              value={filters.cls}
              blank="unlabelled"
              onChange={(v) => onFilters({ class: v })}
            />
          )}
          <FacetSelect
            label="type"
            facets={typeFacet}
            value={filters.type}
            blank="no extension"
            onChange={(v) => onFilters({ type: v })}
          />
          {filtered && (
            <button
              className="filter-clear"
              onClick={() =>
                onFilters({ q: undefined, split: undefined, class: undefined, type: undefined })
              }
            >
              Clear filters
            </button>
          )}
        </div>
      )}

      {classes.length > 0 && (
        <div className="overlay-bar">
          <ul className="class-chips" aria-label="Annotation classes">
            {classes.map(({ name: cls, count }) => (
              <li key={cls}>
                <button
                  className={hidden.has(cls) ? 'class-chip class-chip--off' : 'class-chip'}
                  aria-pressed={!hidden.has(cls)}
                  onClick={() =>
                    setHidden((prev) => {
                      const next = new Set(prev);
                      if (next.has(cls)) next.delete(cls);
                      else next.add(cls);
                      return next;
                    })
                  }
                >
                  <span className="class-dot" style={{ background: classColor(cls) }} />
                  {cls || 'unlabelled'} <span className="quiet data">{count}</span>
                </button>
              </li>
            ))}
          </ul>
          <label className="overlay-opacity">
            overlay
            <input
              type="range"
              min={0}
              max={1}
              step={0.1}
              value={opacity}
              onChange={(e) => setOpacity(Number(e.target.value))}
              aria-label="Overlay opacity"
            />
          </label>
        </div>
      )}

      {all.length === 0 ? (
        <div className="empty blueprint">
          <h2>This version is empty</h2>
          <p>Every item was deleted by this point in history.</p>
        </div>
      ) : items.length === 0 ? (
        <div className="empty blueprint">
          <h2>No item matches these filters</h2>
          <p>
            <button
              className="filter-clear"
              onClick={() =>
                onFilters({ q: undefined, split: undefined, class: undefined, type: undefined })
              }
            >
              Clear filters
            </button>{' '}
            to see all {all.length.toLocaleString()} items at this version.
          </p>
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
                  item.item_id && item.width && item.height ? (
                    // The fit box pins the image's own aspect, so shapes in
                    // pixel space land where the pixels are: overlays never
                    // ride a cover-crop.
                    <span className="tile-media">
                      <span
                        className="overlay-fit"
                        style={{ aspectRatio: `${item.width} / ${item.height}` }}
                      >
                        <img src={thumbByHash.get(item.hash)} alt={item.path} loading="lazy" />
                        <AnnotationOverlay
                          width={item.width}
                          height={item.height}
                          annotations={annsByItem.get(item.item_id) ?? []}
                          hidden={hidden}
                          opacity={opacity}
                        />
                      </span>
                    </span>
                  ) : (
                    <img src={thumbByHash.get(item.hash)} alt={item.path} loading="lazy" />
                  )
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
          hidden={hidden}
          opacity={opacity}
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
  hidden,
  opacity,
  onClose,
}: {
  name: string;
  item: StateItem;
  annotated: boolean;
  annotations: StateAnnotation[];
  thumb: string | undefined;
  hidden: ReadonlySet<string>;
  opacity: number;
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
        item.item_id && item.width && item.height ? (
          <span
            className="drawer-media overlay-fit"
            style={{ aspectRatio: `${item.width} / ${item.height}` }}
          >
            <img src={thumb} alt={item.path} />
            <AnnotationOverlay
              width={item.width}
              height={item.height}
              annotations={annotations}
              hidden={hidden}
              opacity={opacity}
            />
          </span>
        ) : (
          <img className="drawer-media" src={thumb} alt={item.path} />
        )
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
                  <span className="class-dot" style={{ background: classColor(a.class) }} />
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

function FacetSelect({
  label,
  facets,
  value,
  blank,
  onChange,
}: {
  label: string;
  facets: { value: string; count: number }[];
  value: string | undefined;
  blank: string;
  onChange: (value: string | undefined) => void;
}) {
  return (
    <label className="facet">
      <span className="facet-label" aria-hidden="true">
        {label}
      </span>
      <select
        aria-label={`Filter by ${label}`}
        value={value === undefined ? '\u0000all' : value}
        onChange={(e) => onChange(e.target.value === '\u0000all' ? undefined : e.target.value)}
      >
        <option value={'\u0000all'}>any</option>
        {facets.map((f) => (
          <option key={f.value} value={f.value}>
            {f.value === '' ? blank : f.value} ({f.count.toLocaleString()})
          </option>
        ))}
      </select>
    </label>
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

function classCounts(annotations: StateAnnotation[]): { name: string; count: number }[] {
  const counts = new Map<string, number>();
  for (const a of annotations) {
    const cls = a.class ?? '';
    counts.set(cls, (counts.get(cls) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

function looksVisual(path: string): boolean {
  return /\.(png|jpe?g|gif|webp|bmp|mp4|mov|mkv|avi)$/i.test(path);
}
