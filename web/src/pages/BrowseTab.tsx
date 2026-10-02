import { useEffect, useRef, useState } from 'react';
import { useInfiniteQuery, useQuery } from '@tanstack/react-query';
import {
  ApiError,
  getBrowse,
  getDownloads,
  getHistory,
  getThumbs,
  reveal,
  type Revealed,
  type Overview,
  type StateAnnotation,
  type StateItem,
} from '../api';
import { humanBytes } from '../format';
import { AnnotationOverlay } from '../overlays';
import { classColor } from '../shapes';
import { timeline } from '../history';
import { TableView } from '../TableView';
import { anyFilter, extOf, type FilterPatch, type Filters } from '../browseFilter';

// A page of the gallery or table: what the server answers per request,
// and what one scroll to the bottom asks for next.
const pageSize = 120;

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
  // The URL moved under the box (back button, a pasted link): follow it.
  // Adjusted during render, React's pattern for state derived from props.
  const [seenQ, setSeenQ] = useState(filters.q);
  if (filters.q !== seenQ) {
    setSeenQ(filters.q);
    setTyped(filters.q ?? '');
  }
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

  // The version a page at a time, filtered on the server (DuckDB over the
  // version's Parquet index in the server build): the page never holds
  // more than what was scrolled to, whatever the dataset's size. Each
  // page brings its own thumbnails; a page whose thumbnails cannot be had
  // still shows every item, as type tiles.
  const query = { q: filters.q, split: filters.split, cls: filters.cls, type: filters.type };
  const pages = useInfiniteQuery({
    queryKey: ['browse', name, commit, query],
    queryFn: async ({ pageParam }) => {
      const page = await getBrowse(name, commit!, { ...query, after: pageParam, limit: pageSize });
      return { ...page, thumbs: await thumbsFor(name, page.items) };
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last) => last.next ?? undefined,
    enabled: commit !== null,
  });
  const loaded = pages.data?.pages.flatMap((p) => p.items) ?? [];
  const openLoaded = loaded.find((i) => i.path === openItem);
  // A shared link can open an item no loaded page holds yet.
  const openFetched = useQuery({
    queryKey: ['browse-open', name, commit, openItem],
    queryFn: async () => {
      const page = await getBrowse(name, commit!, { item: openItem, limit: 1 });
      return page.open ? { item: page.open, thumbs: await thumbsFor(name, [page.open]) } : null;
    },
    enabled: commit !== null && openItem !== undefined && openLoaded === undefined && pages.isSuccess,
  });

  if (commit === null) return <p className="quiet">Nothing to browse until the first push.</p>;
  if (pages.isPending) return <p className="quiet">Reading the manifest…</p>;
  if (pages.isError) {
    const indexing = pages.error instanceof ApiError && pages.error.status === 503;
    return (
      <div className="panel notice" role="alert">
        <p>
          {indexing
            ? 'The server is indexing another version. Reload in a moment.'
            : 'Could not read this version. Run the link again, or pick another release.'}
        </p>
      </div>
    );
  }

  const first = pages.data.pages[0];
  const total = first.total;
  const matched = first.matched;
  const items = loaded;
  const splitFacet = first.facets.split;
  const classFacet = first.facets.class;
  const typeFacet = first.facets.type;
  const filtered = anyFilter(filters);
  const thumbByHash = new Map(
    [...pages.data.pages.flatMap((p) => p.thumbs), ...(openFetched.data?.thumbs ?? [])].map((t) => [t.hash, t.url]),
  );
  const classes = first.classes.map((c) => ({ name: c.value, count: c.count }));
  const open = openLoaded ?? openFetched.data?.item;

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
        {overview.restricted && (
          <p className="chip restricted-badge">restricted · blurred until revealed</p>
        )}
        <p className="quiet data" aria-live="polite">
          {filtered
            ? `${matched.toLocaleString()} of ${total.toLocaleString()} items`
            : `${total.toLocaleString()} items`}
        </p>
      </div>

      {total > 0 && (
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

      {total === 0 ? (
        <div className="empty blueprint">
          <h2>This version is empty</h2>
          <p>Every item was deleted by this point in history.</p>
        </div>
      ) : matched === 0 ? (
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
            to see all {total.toLocaleString()} items at this version.
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
                          annotations={item.annotations}
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

      {pages.hasNextPage && (
        <MoreItems
          shown={items.length}
          matched={matched}
          loading={pages.isFetchingNextPage}
          onMore={() => void pages.fetchNextPage()}
        />
      )}

      {open && (
        <ItemDrawer
          name={name}
          item={open}
          annotated={overview.kind === 'annotated'}
          restricted={overview.restricted}
          annotations={open.annotations}
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
  restricted,
  annotations,
  thumb,
  hidden,
  opacity,
  onClose,
}: {
  name: string;
  item: StateItem;
  annotated: boolean;
  restricted: boolean;
  annotations: StateAnnotation[];
  thumb: string | undefined;
  hidden: ReadonlySet<string>;
  opacity: number;
  onClose: () => void;
}) {
  // A restricted item's bytes are never fetched just because its drawer
  // opened: that would log a download nobody chose. They come with a
  // reveal, which is logged and says so first (invariant 20).
  const download = useQuery({
    queryKey: ['download', name, item.hash],
    queryFn: () => getDownloads(name, [item.hash]),
    enabled: !restricted,
  });
  const [revealed, setRevealed] = useState<Revealed | null>(null);
  const [revealing, setRevealing] = useState(false);
  const url = restricted ? revealed?.download : download.data?.downloads[0]?.url;
  const shownThumb = revealed?.thumb ?? thumb;

  return (
    <aside className="drawer panel" aria-label={item.path}>
      <div className="drawer-head">
        <h2 className="data drawer-path">{item.path}</h2>
        <button className="drawer-close" onClick={onClose} aria-label="Close">
          ✕
        </button>
      </div>
      {shownThumb ? (
        item.item_id && item.width && item.height ? (
          <span
            className="drawer-media overlay-fit"
            style={{ aspectRatio: `${item.width} / ${item.height}` }}
          >
            <img src={shownThumb} alt={item.path} />
            <AnnotationOverlay
              width={item.width}
              height={item.height}
              annotations={annotations}
              hidden={hidden}
              opacity={opacity}
            />
          </span>
        ) : (
          <img className="drawer-media" src={shownThumb} alt={item.path} />
        )
      ) : (
        isTable(item.path) ? (
          <TableView name={name} hash={item.hash} revealed={revealed?.table} />
        ) : (
          <div className="drawer-media drawer-media--none blueprint">
            <span className="data">{extOf(item.path)}</span>
            <p className="quiet">No preview for this file type yet; the bytes are one click away.</p>
          </div>
        )
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
      <ItemHistoryList name={name} path={item.path} />
      {restricted && !revealed && (
        <div className="reveal panel">
          <p>
            Restricted: shown blurred. Revealing shows the clear image and the file, and{' '}
            <strong>is logged</strong> with your name for the dataset's owners.
          </p>
          <button
            className="action"
            disabled={revealing}
            onClick={() => {
              setRevealing(true);
              void reveal(name, item.hash)
                .then(setRevealed)
                .finally(() => setRevealing(false));
            }}
          >
            {revealing ? 'Revealing…' : 'Reveal this item'}
          </button>
        </div>
      )}
      {restricted && revealed && <p className="quiet reveal-note">Revealed; this was logged.</p>}
      {url && (
        <a className="action drawer-download" href={url} download>
          Download the file
        </a>
      )}
    </aside>
  );
}

// The item's history: every change to the file and its annotations,
// newest first, with what changed and where it landed.
function ItemHistoryList({ name, path }: { name: string; path: string }) {
  const h = useQuery({ queryKey: ['history', name, path], queryFn: () => getHistory(name, path) });
  if (h.isPending) return <p className="quiet">Reading the history…</p>;
  if (h.isError) return <p className="quiet">The history could not be read; the rest of the item is above.</p>;
  const entries = timeline(h.data);
  return (
    <section aria-label="History" className="item-history">
      <h3>History</h3>
      <ol className="history-list">
        {entries.map((e, i) => (
          <li key={i}>
            <p>
              <strong>{e.what}</strong> <span className="quiet">by {e.who}</span>
            </p>
            {e.change && <p className="data history-change">{e.change}</p>}
            <p className="quiet history-where">
              {e.where} · <time dateTime={e.at}>{e.at.slice(0, 10)}</time>
            </p>
          </li>
        ))}
      </ol>
    </section>
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

/** Thumbnails for a page's visual items. Previews are optional: when they
 * cannot be had, the items show as type tiles, never as an error. */
async function thumbsFor(name: string, items: StateItem[]): Promise<{ hash: string; url: string }[]> {
  const hashes = items.filter((i) => looksVisual(i.path)).map((i) => i.hash);
  if (hashes.length === 0) return [];
  try {
    return (await getThumbs(name, hashes)).thumbs;
  } catch {
    return [];
  }
}

// The next page: fetched as the button scrolls into view, and a plain
// button for keyboards and anyone who would rather click.
function MoreItems({
  shown,
  matched,
  loading,
  onMore,
}: {
  shown: number;
  matched: number;
  loading: boolean;
  onMore: () => void;
}) {
  const ref = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || loading || typeof IntersectionObserver === 'undefined') return;
    const watch = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) onMore();
    });
    watch.observe(el);
    return () => watch.disconnect();
  }, [loading, onMore]);
  return (
    <button ref={ref} className="filter-clear more-items" disabled={loading} onClick={onMore}>
      {loading
        ? 'Loading more…'
        : `Show more (${shown.toLocaleString()} of ${matched.toLocaleString()} shown)`}
    </button>
  );
}

function isTable(path: string): boolean {
  return /\.(csv|parquet|jsonl|ndjson)$/i.test(path);
}

function looksVisual(path: string): boolean {
  return /\.(png|jpe?g|gif|webp|bmp|mp4|mov|mkv|avi)$/i.test(path);
}
