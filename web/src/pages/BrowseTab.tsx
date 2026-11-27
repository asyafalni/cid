import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode, type RefObject } from 'react';
import { useWindowVirtualizer } from '@tanstack/react-virtual';
import { useInfiniteQuery, useQuery } from '@tanstack/react-query';
import { Link } from '@tanstack/react-router';
import { GridSkeleton } from '../Skeleton';
import {
  ApiError,
  getBrowse,
  getDownloads,
  getHistory,
  getPdfPages,
  getText,
  reveal,
  type BrowseItem,
  type NumHist,
  type NumKey,
  type Revealed,
  type TextHead,
  type Overview,
  type StateAnnotation,
  type StateItem,
} from '../api';
import { humanBytes } from '../format';
import { AnnotationOverlay } from '../overlays';
import { classColor, clock, parseSpan, parseTime } from '../shapes';
import { MediaTimeline } from '../MediaTimeline';
import { SpannedText } from '../SpannedText';
import { ShortcutsPanel } from '../Shortcuts';
import { typingIn } from '../keys';
import { SqlConsole } from '../SqlConsole';
import { timeline } from '../history';
import { TableView } from '../TableView';
import { ClipThumb, Thumb } from '../Thumb';
import { thumbsFor } from '../thumbs';
import { anyFilter, extOf, type FilterPatch, type Filters } from '../browseFilter';

// The file types the preview worker draws: pictures, video posters and
// sound waveforms (src/preview/).
const previewable = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.tif', '.tiff', '.mp4', '.mov', '.webm', '.mkv', '.avi', '.wav', '.mp3', '.flac', '.ogg', '.m4a', '.pdf']);

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
  rowFilter,
  onRowFilter,
  row,
  onRow,
}: {
  name: string;
  overview: Overview;
  commit: string | null;
  openItem: string | undefined;
  onOpenItem: (path: string | undefined) => void;
  filters: Filters;
  onFilters: (patch: FilterPatch) => void;
  /** The open table item's row filters, as JSON, from the URL. */
  rowFilter?: string;
  onRowFilter?: (rows: string | undefined) => void;
  /** The open table item's linked row, from the URL. */
  row?: string;
  onRow?: (row: string | undefined) => void;
}) {
  const setMode = (m: 'gallery' | 'table' | 'list' | 'sql') => onFilters({ mode: m });

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
  const query = { q: filters.q, split: filters.split, cls: filters.cls, type: filters.type, anns: filters.anns, attr: filters.attr, identity: filters.identity, since: filters.since, size: filters.size, author: filters.author, policy: filters.policy, num: filters.num, numFrom: filters.numFrom, numTo: filters.numTo };
  const pages = useInfiniteQuery({
    queryKey: ['browse', name, commit, query],
    queryFn: async ({ pageParam }) => {
      // Counts and facets come with the first page only.
      const page = await getBrowse(name, commit!, { ...query, after: pageParam, limit: pageSize, facets: pageParam === undefined });
      return { ...page, thumbs: await thumbsFor(name, page.items) };
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last) => last.next ?? undefined,
    enabled: commit !== null,
  });
  const loaded = useMemo(() => pages.data?.pages.flatMap((p) => p.items) ?? [], [pages.data]);
  const openLoaded = loaded.find((i) => i.path === openItem);
  // A shared link can open an item no loaded page holds yet.
  const openFetched = useQuery({
    queryKey: ['browse-open', name, commit, openItem],
    queryFn: async () => {
      const page = await getBrowse(name, commit!, { item: openItem, limit: 1, facets: false });
      return page.open ? { item: page.open, thumbs: await thumbsFor(name, [page.open]) } : null;
    },
    enabled: commit !== null && openItem !== undefined && openLoaded === undefined && pages.isSuccess,
  });

  // The keyboard (docs/dashboard.md, principle 10), never while typing or
  // while a control or a player has the keys: `g`/`t` switch the view,
  // `j`/`k` move between items (the arrows too, while one is open, so
  // they still scroll the page otherwise), `/` searches, `?` lists them
  // all, Escape closes what is open.
  const searchRef = useRef<HTMLInputElement>(null);
  const [help, setHelp] = useState(false);
  const { hasNextPage, fetchNextPage, isFetchingNextPage } = pages;
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (typingIn(e)) return;
      const step = (by: 1 | -1) => {
        e.preventDefault();
        const at = loaded.findIndex((i) => i.path === openItem);
        const to = at < 0 ? (by === 1 ? 0 : -1) : at + by;
        if (to >= 0 && to < loaded.length) onOpenItem(loaded[to].path);
        else if (to >= loaded.length && hasNextPage && !isFetchingNextPage) void fetchNextPage();
      };
      switch (e.key) {
        case 'g':
          return onFilters({ mode: 'gallery' });
        case 't':
          return onFilters({ mode: 'table' });
        case 'l':
          return onFilters({ mode: 'list' });
        case 'j':
          return step(1);
        case 'k':
          return step(-1);
        case 'ArrowDown':
        case 'ArrowRight':
          if (openItem !== undefined) step(1);
          return;
        case 'ArrowUp':
        case 'ArrowLeft':
          if (openItem !== undefined) step(-1);
          return;
        case 'f': {
          // The first filter after the path search: the split, when the
          // version has splits.
          const first = searchRef.current?.parentElement?.querySelector('select');
          if (!first) return;
          e.preventDefault();
          first.focus();
          return;
        }
        case '/':
          if (!searchRef.current) return;
          e.preventDefault();
          searchRef.current.focus();
          return;
        case '?':
          return setHelp((h) => !h);
        case 'Escape':
          if (help) setHelp(false);
          else if (openItem !== undefined) onOpenItem(undefined);
          return;
      }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onFilters, onOpenItem, loaded, openItem, help, hasNextPage, isFetchingNextPage, fetchNextPage]);

  if (commit === null) return <p className="quiet">Nothing to browse until the first push.</p>;
  if (pages.isPending) return <GridSkeleton count={pageSize > 24 ? 24 : pageSize} />;
  if (pages.isError && filters.since !== undefined && pages.error instanceof ApiError && pages.error.status === 404) {
    // A release name no release has (a typo, a link from elsewhere): said,
    // with the way back, never an empty gallery.
    return (
      <div className="panel notice" role="alert">
        <p>{pages.error.message}.</p>
        <button className="filter-clear" onClick={() => onFilters({ since: undefined })}>
          Show every item
        </button>
      </div>
    );
  }
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
  // As asked; with nothing asked, the gallery, unless nothing in this
  // version can have a preview (no picture, video or sound): a wall of
  // identical type tiles says less than a table of paths and sizes. Decided
  // by the version, not the page, so a filter never flips the view.
  const mode: 'gallery' | 'table' | 'list' | 'sql' =
    filters.mode ?? (overview.types.length > 0 && !overview.types.some((t) => previewable.has(t.name)) ? 'table' : 'gallery');
  const total = first.total;
  const matched = first.matched;
  const items = loaded;
  const splitFacet = first.facets.split;
  // A version none of whose items has a split shows no split filter or
  // column: a choice of only "no split" says nothing.
  const hasSplits = overview.splits.length > 0 || filters.split !== undefined;
  const classFacet = first.facets.class;
  const typeFacet = first.facets.type;
  const filtered = anyFilter(filters);
  const allThumbs = [...pages.data.pages.flatMap((p) => p.thumbs), ...(openFetched.data?.thumbs ?? [])];
  const thumbByHash = new Map(allThumbs.map((t) => [t.hash, t.url]));
  // A video's short clip, played while its tile is pointed at.
  const clipByHash = new Map(allThumbs.flatMap((t) => (t.clip ? [[t.hash, t.clip] as const] : [])));
  const classes = first.classes.map((c) => ({ name: c.value, count: c.count }));
  const open = openLoaded ?? openFetched.data?.item;
  // Releases to compare against: every one on the tape but the version shown.
  const sinceChoices = overview.commits.filter((c) => c.release !== null && c.id !== commit).map((c) => c.release!);

  return (
    <div className="browse">
      <div className="browse-bar">
        <div className="format-picker format-picker--ui" role="radiogroup" aria-label="View">
          {/* The SQL console: never on a restricted dataset (its paths and
              annotations are content, and a query could read them all). */}
          {(overview.restricted ? (['gallery', 'table', 'list'] as const) : (['gallery', 'table', 'list', 'sql'] as const)).map((m) => (
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
            : `${total.toLocaleString()} ${total === 1 ? 'item' : 'items'}`}
        </p>
        <button
          className="shortcuts-toggle data"
          aria-label="Keyboard shortcuts"
          aria-expanded={help}
          title="Keyboard shortcuts (?)"
          onClick={() => setHelp((h) => !h)}
        >
          ?
        </button>
      </div>

      {help && (
        <ShortcutsPanel
          keys={shortcuts}
          note="The arrows move between items while one is open; otherwise they scroll."
          onClose={() => setHelp(false)}
        />
      )}

      {total > 0 && mode !== 'sql' && (
        <div className="filter-bar" role="search">
          <input
            ref={searchRef}
            type="search"
            className="filter-q"
            placeholder="Search paths"
            aria-label="Filter by path"
            value={typed}
            onChange={(e) => setTyped(e.target.value)}
          />
          {hasSplits && (
            <FacetSelect
              label="split"
              facets={splitFacet}
              value={filters.split}
              blank="no split"
              onChange={(v) => onFilters({ split: v })}
            />
          )}
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
          {overview.kind === 'annotated' && (
            // How many annotations an item has, a histogram as much as a
            // filter: "0" finds what is left to label.
            <FacetSelect
              label="annotations"
              facets={first.facets.anns.map((f) => ({ ...f, value: f.value }))}
              value={filters.anns}
              blank="none"
              onChange={(v) => onFilters({ anns: v })}
            />
          )}
          {/* A histogram as much as a filter: the size buckets in order. */}
          <FacetSelect
            label="size"
            facets={first.facets.size}
            value={filters.size}
            blank="none"
            show={sizeWords}
            onChange={(v) => onFilters({ size: v })}
          />
          {(first.facets.attr.length > 0 || filters.attr !== undefined) && (
            // Attribute values the annotations carry ("occluded=true"), the
            // most common first.
            <FacetSelect
              label="attribute"
              facets={first.facets.attr}
              value={filters.attr}
              blank="none"
              onChange={(v) => onFilters({ attr: v })}
            />
          )}
          {(first.facets.author.length > 0 || filters.author !== undefined) && (
            // Who made the annotations (an agent or a person), and under
            // which labelling policy version: the items an agent or a
            // policy touched, to review them together.
            <FacetSelect
              label="author"
              facets={first.facets.author}
              value={filters.author}
              blank="none"
              onChange={(v) => onFilters({ author: v })}
            />
          )}
          {(first.facets.policy.length > 0 || filters.policy !== undefined) && (
            <FacetSelect
              label="policy"
              facets={first.facets.policy}
              value={filters.policy}
              blank="none"
              onChange={(v) => onFilters({ policy: v })}
            />
          )}
          {((overview.identities ?? 0) > 0 || filters.identity !== undefined) && (
            // Who or what an annotation names: typed, matched exactly; no
            // list, since a face set names thousands.
            <IdentityFilter value={filters.identity} onChange={(v) => onFilters({ identity: v })} />
          )}
          {(sinceChoices.length > 0 || filters.since !== undefined) && (
            // What the loop added: items new, re-encoded, moved to another
            // split or re-annotated since a release (deleted ones are not
            // here to show; Releases' compare lists them).
            <label className="facet">
              <span className="facet-label" aria-hidden="true">
                changed since
              </span>
              <select
                aria-label="Filter to items changed since a release"
                value={filters.since ?? '\u0000all'}
                onChange={(e) => onFilters({ since: e.target.value === '\u0000all' ? undefined : e.target.value })}
              >
                <option value={'\u0000all'}>any time</option>
                {(filters.since !== undefined && !sinceChoices.includes(filters.since)
                  ? [filters.since, ...sinceChoices]
                  : sinceChoices
                ).map((r) => (
                  <option key={r} value={r}>
                    {r}
                  </option>
                ))}
              </select>
            </label>
          )}
          {filtered && (
            <button
              className="filter-clear"
              onClick={() =>
                onFilters({ q: undefined, split: undefined, class: undefined, type: undefined, anns: undefined, attr: undefined, identity: undefined, since: undefined, size: undefined, author: undefined, policy: undefined, num_from: undefined, num_to: undefined })
              }
            >
              Clear filters
            </button>
          )}
        </div>
      )}

      {mode !== 'sql' && (first.facets.nums.length > 0 || filters.num !== undefined) && (
        <NumbersFilter
          keys={first.facets.nums}
          hist={first.facets.hist}
          num={filters.num}
          from={filters.numFrom}
          to={filters.numTo}
          onFilters={onFilters}
        />
      )}

      {classes.length > 0 && mode !== 'sql' && (
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

      {mode === 'sql' ? (
        <SqlConsole
          name={name}
          commit={commit}
          sql={filters.sql}
          onSql={(sql) => onFilters({ sql })}
          onOpenItem={onOpenItem}
        />
      ) : total === 0 ? (
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
                onFilters({ q: undefined, split: undefined, class: undefined, type: undefined, anns: undefined, attr: undefined, identity: undefined })
              }
            >
              Clear filters
            </button>{' '}
            to see all {total.toLocaleString()} items at this version.
          </p>
        </div>
      ) : mode === 'gallery' ? (
        <VirtualGallery
          items={items}
          openItem={openItem}
          renderTile={(item) => (
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
                    <span className="overlay-fit" style={{ aspectRatio: `${item.width} / ${item.height}` }}>
                      <Thumb src={thumbByHash.get(item.hash)} alt={item.path} label={extOf(item.path)} lazy>
                        <AnnotationOverlay
                          width={item.width}
                          height={item.height}
                          annotations={item.annotations}
                          hidden={hidden}
                          opacity={opacity}
                        />
                      </Thumb>
                    </span>
                  </span>
                ) : clipByHash.has(item.hash) ? (
                  <ClipThumb src={thumbByHash.get(item.hash)} clip={clipByHash.get(item.hash)!} alt={item.path} label={extOf(item.path)} />
                ) : (
                  <Thumb src={thumbByHash.get(item.hash)} alt={item.path} label={extOf(item.path)} lazy />
                )
              ) : (
                <span className="tile-type data">{extOf(item.path)}</span>
              )}
              <span className="tile-path data">{item.path}</span>
            </button>
          )}
        />
      ) : mode === 'list' ? (
        <VirtualList
          name={name}
          items={items}
          thumbs={thumbByHash}
          annotated={overview.kind === 'annotated'}
          restricted={overview.restricted}
          openItem={openItem}
          onOpenItem={onOpenItem}
        />
      ) : (
        <VirtualTable items={items} splits={hasSplits} openItem={openItem} onOpenItem={onOpenItem} />
      )}

      {pages.hasNextPage && mode !== 'sql' && (
        <MoreItems
          shown={items.length}
          matched={matched}
          loading={pages.isFetchingNextPage}
          onMore={() => void pages.fetchNextPage()}
        />
      )}

      {openItem !== undefined && !open && openFetched.isSuccess && (
        <MissingItem name={name} path={openItem} onClose={() => onOpenItem(undefined)} />
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
          rowFilter={rowFilter}
          onRowFilter={onRowFilter}
          row={row}
          onRow={onRow}
          onFilters={onFilters}
          onClose={() => onOpenItem(undefined)}
        />
      )}
    </div>
  );
}

// A link to an item this version does not hold (a path from another
// release, a typo, a deleted file): said in words, with the releases that
// do hold it, from its history; never a page that silently shows nothing.
export function MissingItem({ name, path, onClose }: { name: string; path: string; onClose: () => void }) {
  const history = useQuery({ queryKey: ['history', name, path], queryFn: () => getHistory(name, path) });
  const holding = [
    ...new Set(
      (history.data?.changes ?? []).filter((c) => c.op !== 'delete' && c.release !== null).map((c) => c.release!),
    ),
  ];
  return (
    <section className="panel notice missing-item" role="status" aria-label="Item not in this version">
      <p>
        <span className="data">{path}</span> is not in this version.
      </p>
      {history.isPending ? (
        <p className="quiet">Looking for the releases that hold it…</p>
      ) : holding.length > 0 ? (
        <p>
          It is in{' '}
          {holding.slice(0, 5).map((r, i) => (
            <span key={r}>
              {i > 0 && ', '}
              <Link to="/d/$" params={{ _splat: name }} search={{ view: 'browse', release: r, item: path }}>
                {r}
              </Link>
            </span>
          ))}
          {holding.length > 5 && ` and ${holding.length - 5} more releases`}.
        </p>
      ) : (
        <p className="quiet">No release holds it: it may be on another branch, not released yet, or never added.</p>
      )}
      <button className="filter-clear" onClick={onClose}>
        Close
      </button>
    </section>
  );
}

export function ItemDrawer({
  name,
  item,
  annotated,
  restricted,
  annotations,
  thumb,
  hidden,
  opacity,
  rowFilter,
  onRowFilter,
  row,
  onRow,
  onFilters,
  onClose,
  children,
}: {
  name: string;
  item: StateItem;
  annotated: boolean;
  restricted: boolean;
  annotations: StateAnnotation[];
  thumb: string | undefined;
  hidden: ReadonlySet<string>;
  opacity: number;
  rowFilter?: string;
  onRowFilter?: (rows: string | undefined) => void;
  row?: string;
  onRow?: (row: string | undefined) => void;
  /** Browse's filters: an attribute or identity in the list narrows to it. */
  onFilters?: (patch: FilterPatch) => void;
  onClose: () => void;
  /** Ways onward from where the drawer opened (the Files tab: into Browse). */
  children?: ReactNode;
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
  const [media, setMedia] = useState<HTMLMediaElement | null>(null);
  const timed = isVideo(item.path) || isAudio(item.path);

  return (
    <aside className="drawer panel" aria-label={item.path}>
      <div className="drawer-head">
        <h2 className="data drawer-path">{item.path}</h2>
        <button className="drawer-close" onClick={onClose} aria-label="Close">
          ✕
        </button>
      </div>
      {isVideo(item.path) && url ? (
        // Video plays where it is, its poster the thumbnail.
        <video ref={setMedia} className="drawer-media" controls preload="metadata" poster={shownThumb} src={url}>
          <track kind="captions" />
        </video>
      ) : isAudio(item.path) ? (
        // Audio: its waveform, and the sound itself.
        <div className="drawer-audio">
          {shownThumb ? (
            <Thumb className="drawer-waveform" src={shownThumb} alt={`${item.path} waveform`} label={extOf(item.path)} />
          ) : (
            <p className="quiet">The waveform appears when the preview worker reaches this file.</p>
          )}
          {url && <audio ref={setMedia} controls preload="none" src={url} aria-label={item.path} />}
        </div>
      ) : extOf(item.path) === '.pdf' ? (
        <PdfView name={name} hash={item.hash} path={item.path} thumb={shownThumb} />
      ) : shownThumb ? (
        item.item_id && item.width && item.height ? (
          <span
            className="drawer-media overlay-fit"
            style={{ aspectRatio: `${item.width} / ${item.height}` }}
          >
            <Thumb src={shownThumb} alt={item.path} label={extOf(item.path)}>
              <AnnotationOverlay
                width={item.width}
                height={item.height}
                annotations={annotations}
                hidden={hidden}
                opacity={opacity}
              />
            </Thumb>
          </span>
        ) : (
          <Thumb className="drawer-media" src={shownThumb} alt={item.path} label={extOf(item.path)} />
        )
      ) : isTable(item.path) ? (
        <TableView
          name={name}
          hash={item.hash}
          path={item.path}
          revealed={revealed?.table}
          where={rowFilter}
          onWhere={onRowFilter}
          row={row}
          onRow={onRow}
        />
      ) : (
        <TextView
          name={name}
          path={item.path}
          hash={item.hash}
          revealed={revealed?.text}
          annotations={annotations}
          hidden={hidden}
        />
      )}
      {timed && <MediaTimeline annotations={annotations} hidden={hidden} media={url ? media : null} />}
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
        {item.pages ? (
          <>
            <dt>pages</dt>
            <dd className="data">{item.pages.toLocaleString()}</dd>
          </>
        ) : null}
        <dt>blake3</dt>
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
                  <AnnWhere a={a} />
                  <AnnFacts a={a} onFilters={onFilters} />
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
      {(children || url) && (
        <div className="drawer-actions">
          {children}
          {url && (
            <a className="action drawer-download" href={url} download>
              Download the file
            </a>
          )}
        </div>
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

/** A size bucket as words: '1MB-10MB' reads "1–10 MB". */
function sizeWords(bucket: string): string {
  const words: Record<string, string> = {
    '<10KB': 'under 10 KB',
    '10KB-100KB': '10–100 KB',
    '100KB-1MB': '100 KB–1 MB',
    '1MB-10MB': '1–10 MB',
    '10MB-100MB': '10–100 MB',
    '100MB+': '100 MB or more',
  };
  return words[bucket] ?? bucket;
}

// A numeric attribute as a histogram (docs/dashboard.md, Filters): its
// values in equal bins across the version's whole range, counted against
// the other filters, each bar a button that narrows Browse to that range;
// pressed again, it lets go. Drawn as a table column's histogram is, in
// one hue, so the two read alike.
function NumbersFilter({
  keys,
  hist,
  num,
  from,
  to,
  onFilters,
}: {
  keys: NumKey[];
  hist: NumHist | null;
  num: string | undefined;
  from: string | undefined;
  to: string | undefined;
  onFilters: (patch: FilterPatch) => void;
}) {
  const ranged = from !== undefined || to !== undefined;
  const choices = num !== undefined && !keys.some((k) => k.key === num) ? [num, ...keys.map((k) => k.key)] : keys.map((k) => k.key);
  return (
    <section className="numbers panel" aria-label="Numeric attributes">
      <label className="facet">
        <span className="facet-label" aria-hidden="true">
          numbers
        </span>
        <select
          aria-label="Show a numeric attribute's histogram"
          value={num ?? '\u0000none'}
          onChange={(e) =>
            onFilters({ num: e.target.value === '\u0000none' ? undefined : e.target.value, num_from: undefined, num_to: undefined })
          }
        >
          <option value={'\u0000none'}>pick an attribute</option>
          {choices.map((k) => (
            <option key={k} value={k}>
              {k}
            </option>
          ))}
        </select>
      </label>
      {num !== undefined && hist === null && (
        <p className="quiet">No annotation here carries a number for {num}.</p>
      )}
      {hist && <NumBins hist={hist} from={from} to={to} onFilters={onFilters} />}
      {ranged && (
        <p className="numbers-range">
          <span className="data">
            {num} {from !== undefined ? `from ${num4(Number(from))}` : ''} {to !== undefined ? `to ${num4(Number(to))}` : 'and up'}
          </span>{' '}
          <button className="filter-clear" onClick={() => onFilters({ num_from: undefined, num_to: undefined })}>
            Clear range
          </button>
        </p>
      )}
    </section>
  );
}

function NumBins({
  hist,
  from,
  to,
  onFilters,
}: {
  hist: NumHist;
  from: string | undefined;
  to: string | undefined;
  onFilters: (patch: FilterPatch) => void;
}) {
  const n = hist.bins.length;
  const width = (hist.max - hist.min) / n;
  const top = Math.max(1, ...hist.bins);
  return (
    <div className="hist numbers-hist" role="group" aria-label={`${hist.key}: distribution`}>
      <div className="hist-bins">
        {hist.bins.map((count, i) => {
          const lo = hist.min + i * width;
          const last = i === n - 1;
          // The last bin holds the top value, so its range is left open.
          const binFrom = String(lo);
          const binTo = last ? undefined : String(hist.min + (i + 1) * width);
          // By value, not text: a link written by hand says 0.235 where
          // the edge works out to 0.23500000000000001.
          const near = (a: string | undefined, b: number) => a !== undefined && Math.abs(Number(a) - b) <= Math.abs(width) * 1e-6;
          const on = near(from, lo) && (last ? to === undefined : near(to, hist.min + (i + 1) * width));
          const label = `${hist.key} ${num4(lo)} to ${num4(last ? hist.max : lo + width)}: ${count.toLocaleString()} ${count === 1 ? 'value' : 'values'}`;
          return (
            <button
              key={i}
              className={on ? 'hist-bin on' : 'hist-bin'}
              aria-label={label}
              aria-pressed={on}
              title={label}
              disabled={count === 0 && !on}
              onClick={() => onFilters(on ? { num_from: undefined, num_to: undefined } : { num_from: binFrom, num_to: binTo })}
            >
              <span style={{ height: `${count === 0 ? 0 : Math.max(8, (count / top) * 100)}%` }} />
            </button>
          );
        })}
      </div>
      <div className="hist-range data quiet">
        <span>{num4(hist.min)}</span>
        <span>{num4(hist.max)}</span>
      </div>
    </div>
  );
}

function num4(v: number): string {
  return Number.isInteger(v) ? v.toLocaleString() : v.toLocaleString(undefined, { maximumSignificantDigits: 4 });
}

function FacetSelect({
  label,
  facets,
  value,
  blank,
  show,
  onChange,
}: {
  label: string;
  facets: { value: string; count: number }[];
  value: string | undefined;
  blank: string;
  /** How a value reads, when not as itself. */
  show?: (value: string) => string;
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
            {f.value === '' ? blank : show ? show(f.value) : f.value} ({f.count.toLocaleString()})
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

// The gallery and the table render only what is on screen (and a little
// either side): scrolled to the millionth item, the page holds the same
// few dozen tiles it held at the first (docs/dashboard.md: virtualised
// infinite scroll). Rows of tiles, as many columns as the CSS grid would
// fit; each row measured as it renders.
const tileMin = 140;

// The identity filter: committed on Enter or when the field is left, so
// a half-typed name never asks the server; the URL is the truth.
function IdentityFilter({ value, onChange }: { value: string | undefined; onChange: (v: string | undefined) => void }) {
  const [typed, setTyped] = useState(value ?? '');
  const [seen, setSeen] = useState(value);
  if (value !== seen) {
    setSeen(value);
    setTyped(value ?? '');
  }
  const commit = () => {
    const v = typed.trim();
    if (v !== (value ?? '')) onChange(v === '' ? undefined : v);
  };
  return (
    <label className="facet">
      <span className="facet-label" aria-hidden="true">
        identity
      </span>
      <input
        type="search"
        className="filter-identity data"
        placeholder="exact id"
        aria-label="Filter by identity"
        value={typed}
        onChange={(e) => setTyped(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter') commit();
        }}
        onBlur={commit}
      />
    </label>
  );
}

// What the keys do, listed where they work.
const shortcuts: [string, string][] = [
  ['j  ↓  →', 'next item'],
  ['k  ↑  ←', 'previous item'],
  ['/', 'search paths'],
  ['f', 'filters (split, class, type…)'],
  ['g', 'gallery'],
  ['t', 'table'],
  ['l', 'list (audio and text)'],
  ['Esc', 'close the item'],
  ['?', 'this list'],
];


// The open item's row (gallery or table) is brought into view when it
// is not already, so moving with the keys never leaves it off screen. Two
// steps: the virtualizer jumps near it (it may not be rendered yet, and on
// the first render its offset from the page top is not known), then the
// row itself, once drawn, is aligned exactly.
function useKeepInView(
  index: number,
  container: RefObject<HTMLElement | null>,
  scrollToIndex: (i: number, o: { align: 'auto' }) => void,
) {
  useEffect(() => {
    if (index < 0) return;
    const drawn = () => container.current?.querySelector(`[data-index="${index}"]`);
    // The virtualizer draws the rows for a new scroll position a frame or
    // two after it; a few frames is plenty.
    let frame = 0;
    const align = (tries: number) => {
      const row = drawn();
      if (row) row.scrollIntoView({ block: 'nearest' });
      else if (tries > 0) frame = requestAnimationFrame(() => align(tries - 1));
    };
    frame = requestAnimationFrame(() => {
      if (!drawn()) scrollToIndex(index, { align: 'auto' });
      frame = requestAnimationFrame(() => align(10));
    });
    return () => cancelAnimationFrame(frame);
    // Only a new index moves the view; the virtualizer's function is new every render.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, [index]);
}

// How far below the top of the page an element starts: the window
// virtualizer's scroll margin. Not `offsetTop`, which counts from the
// nearest positioned ancestor (from the <table>, for a <tbody>). Measured
// after layout and again whenever the page changes size, because what
// sits above (the filters, the shortcuts list) changes height.
function usePageTop(ref: RefObject<HTMLElement | null>): number {
  const [top, setTop] = useState(0);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => setTop(Math.round(el.getBoundingClientRect().top + window.scrollY));
    measure();
    const watch = new ResizeObserver(measure);
    watch.observe(document.body);
    return () => watch.disconnect();
  }, [ref]);
  return top;
}

function VirtualGallery({
  items,
  openItem,
  renderTile,
}: {
  items: BrowseItem[];
  openItem: string | undefined;
  renderTile: (item: BrowseItem) => ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  const [gap, setGap] = useState(12);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    setGap(parseFloat(getComputedStyle(el).rowGap) || 12);
    const watch = new ResizeObserver(() => setWidth(el.clientWidth));
    watch.observe(el);
    setWidth(el.clientWidth);
    return () => watch.disconnect();
  }, []);
  const cols = Math.max(1, Math.floor((width + gap) / (tileMin + gap)));
  const rows = Math.ceil(items.length / cols);
  const tile = width > 0 ? (width - gap * (cols - 1)) / cols : tileMin;
  const pageTop = usePageTop(ref);
  // The virtualizer's functions change every render on purpose; the
  // compiler is told so rather than memoizing them stale.
  // oxlint-disable-next-line react/incompatible-library
  const virtual = useWindowVirtualizer({
    count: rows,
    estimateSize: () => tile * 0.75 + 28 + gap,
    overscan: 3,
    scrollMargin: pageTop,
  });
  const openAt = openItem === undefined ? -1 : items.findIndex((i) => i.path === openItem);
  useKeepInView(openAt < 0 ? -1 : Math.floor(openAt / cols), ref, (i, o) => virtual.scrollToIndex(i, o));
  return (
    <div ref={ref} className="gallery-virtual" style={{ height: virtual.getTotalSize() }}>
      {virtual.getVirtualItems().map((row) => (
        <ul
          key={row.key}
          data-index={row.index}
          ref={virtual.measureElement}
          className="gallery"
          style={{
            gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`,
            transform: `translateY(${row.start - virtual.options.scrollMargin}px)`,
            paddingBottom: gap,
          }}
        >
          {items.slice(row.index * cols, row.index * cols + cols).map((item) => (
            <li key={item.path}>{renderTile(item)}</li>
          ))}
        </ul>
      ))}
    </div>
  );
}

// The table the same way: rows on screen, spacers for the rest, and the
// full count told to assistive technology.
function VirtualTable({
  items,
  splits,
  openItem,
  onOpenItem,
}: {
  items: BrowseItem[];
  splits: boolean;
  openItem: string | undefined;
  onOpenItem: (path: string | undefined) => void;
}) {
  const ref = useRef<HTMLTableSectionElement>(null);
  const pageTop = usePageTop(ref);
  // oxlint-disable-next-line react/incompatible-library
  const virtual = useWindowVirtualizer({
    count: items.length,
    estimateSize: () => 37,
    overscan: 12,
    scrollMargin: pageTop,
  });
  useKeepInView(openItem === undefined ? -1 : items.findIndex((i) => i.path === openItem), ref, (i, o) =>
    virtual.scrollToIndex(i, o),
  );
  const rows = virtual.getVirtualItems();
  const top = rows.length > 0 ? rows[0].start - virtual.options.scrollMargin : 0;
  const bottom = rows.length > 0 ? virtual.getTotalSize() - (rows[rows.length - 1].end - virtual.options.scrollMargin) : 0;
  return (
    <table className="browse-table" aria-rowcount={items.length + 1}>
      <thead>
        <tr aria-rowindex={1}>
          <th className="path-col">path</th>
          <th className="num">size</th>
          {splits && <th>split</th>}
          <th>hash</th>
        </tr>
      </thead>
      <tbody ref={ref}>
        {top > 0 && (
          <tr aria-hidden="true" className="spacer" style={{ height: top }}>
            <td colSpan={splits ? 4 : 3} />
          </tr>
        )}
        {rows.map((row) => {
          const item = items[row.index];
          return (
            <tr
              key={item.path}
              data-index={row.index}
              ref={virtual.measureElement}
              aria-rowindex={row.index + 2}
              className={openItem === item.path ? 'row--open' : undefined}
              onClick={() => onOpenItem(item.path)}
            >
              <td className="data">{item.path}</td>
              <td className="data num">{humanBytes(item.size)}</td>
              {splits && <td>{item.split ?? '—'}</td>}
              <td>
                <HashChip hash={item.hash} />
              </td>
            </tr>
          );
        })}
        {bottom > 0 && (
          <tr aria-hidden="true" className="spacer" style={{ height: bottom }}>
            <td colSpan={splits ? 4 : 3} />
          </tr>
        )}
      </tbody>
    </table>
  );
}

// The List view (docs/dashboard.md, 4.3), for audio and text: a row per
// item that says what it holds without opening it. Audio shows its
// waveform and plays in place, the sound fetched only when asked (never
// for a restricted item, whose bytes come with a logged reveal in the
// drawer); text shows its opening line, read for the rows on screen only;
// annotated items name their classes.
function VirtualList({
  name,
  items,
  thumbs,
  annotated,
  restricted,
  openItem,
  onOpenItem,
}: {
  name: string;
  items: BrowseItem[];
  thumbs: Map<string, string>;
  annotated: boolean;
  restricted: boolean;
  openItem: string | undefined;
  onOpenItem: (path: string | undefined) => void;
}) {
  const ref = useRef<HTMLUListElement>(null);
  const pageTop = usePageTop(ref);
  // oxlint-disable-next-line react/incompatible-library
  const virtual = useWindowVirtualizer({
    count: items.length,
    estimateSize: () => 64,
    overscan: 8,
    scrollMargin: pageTop,
  });
  useKeepInView(openItem === undefined ? -1 : items.findIndex((i) => i.path === openItem), ref, (i, o) =>
    virtual.scrollToIndex(i, o),
  );
  const rows = virtual.getVirtualItems();
  const top = rows.length > 0 ? rows[0].start - virtual.options.scrollMargin : 0;
  const bottom = rows.length > 0 ? virtual.getTotalSize() - (rows[rows.length - 1].end - virtual.options.scrollMargin) : 0;
  return (
    <ul className="browse-list" ref={ref} aria-label="Items" style={{ paddingTop: top, paddingBottom: bottom }}>
      {rows.map((row) => {
        const item = items[row.index];
        return (
          <li
            key={item.path}
            data-index={row.index}
            ref={virtual.measureElement}
            className={openItem === item.path ? 'list-row list-row--open' : 'list-row'}
          >
            <ListRow
              name={name}
              item={item}
              thumb={thumbs.get(item.hash)}
              annotated={annotated}
              restricted={restricted}
              onOpen={() => onOpenItem(item.path)}
            />
          </li>
        );
      })}
    </ul>
  );
}

function ListRow({
  name,
  item,
  thumb,
  annotated,
  restricted,
  onOpen,
}: {
  name: string;
  item: BrowseItem;
  thumb: string | undefined;
  annotated: boolean;
  restricted: boolean;
  onOpen: () => void;
}) {
  const audio = isAudio(item.path);
  const text = !audio && !isVideo(item.path) && textLike.test(item.path);
  const [play, setPlay] = useState(false);
  const sound = useQuery({
    queryKey: ['download', name, item.hash],
    queryFn: () => getDownloads(name, [item.hash]),
    enabled: play && !restricted,
  });
  const head = useQuery({ queryKey: ['text', name, item.hash], queryFn: () => getText(name, item.hash), enabled: text });
  const classes = [...new Set(item.annotations.map((a) => a.class).filter((c): c is string => !!c))];
  const opening = head.data && !head.data.withheld && !head.data.binary && head.data.text !== null
    ? head.data.text.split('\n').find((l) => l.trim() !== '') ?? ''
    : null;
  const url = sound.data?.downloads[0]?.url;
  return (
    <>
      <span className="list-media">
        {audio && thumb ? (
          <Thumb className="list-waveform" src={thumb} alt={`${item.path} waveform`} label={extOf(item.path)} lazy />
        ) : thumb ? (
          <Thumb className="list-thumb" src={thumb} alt={item.path} label={extOf(item.path)} lazy />
        ) : (
          <span className="tile-type data">{extOf(item.path)}</span>
        )}
      </span>
      <button className="list-main" onClick={onOpen} aria-label={`Open ${item.path}`}>
        <span className="data list-path">{item.path}</span>
        <span className="quiet data list-facts">
          {humanBytes(item.size)}
          {item.split ? ` · ${item.split}` : ''}
          {annotated ? ` · ${item.annotations.length} ${item.annotations.length === 1 ? 'annotation' : 'annotations'}` : ''}
          {classes.length > 0 ? ` · ${classes.slice(0, 5).join(', ')}${classes.length > 5 ? ` +${classes.length - 5}` : ''}` : ''}
        </span>
        {text && (
          <span className="list-opening data">
            {head.data?.withheld
              ? 'Restricted: the text is withheld until revealed.'
              : head.data?.binary
                ? 'Not text after all.'
                : opening === null
                  ? '…'
                  : opening === ''
                    ? '(empty)'
                    : opening}
          </span>
        )}
      </button>
      {audio && !restricted && (
        <span className="list-play">
          {url ? (
            // oxlint-disable-next-line jsx-a11y/media-has-caption
            <audio controls autoPlay preload="none" src={url} aria-label={`Play ${item.path}`} />
          ) : (
            <button className="filter-clear" onClick={() => setPlay(true)} aria-label={`Play ${item.path}`}>
              {play ? '…' : '▶ play'}
            </button>
          )}
        </span>
      )}
    </>
  );
}

/** Files whose opening line says what they are: plain text and its kin. */
const textLike = /\.(txt|md|json|jsonl|csv|tsv|srt|vtt|xml|ya?ml|log|ini|toml|html?)$/i;

// The next page: fetched while the button is still two screens below the
// view, so a quick scroll finds the items already there instead of
// waiting on the network at the end of them (docs/dashboard.md, gallery
// scrolling: no blank tiles after 200 ms); and a plain button for
// keyboards and anyone who would rather click.
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
    const watch = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) onMore();
      },
      { rootMargin: '0px 0px 200% 0px' },
    );
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

function isVideo(path: string): boolean {
  return /\.(mp4|mov|mkv|webm|avi)$/i.test(path);
}

function isAudio(path: string): boolean {
  return /\.(wav|mp3|flac|ogg|oga|m4a)$/i.test(path);
}

// Anything else opens as text when it is text: its first 64 KB, read on
// the server; a binary file says so in words, the bytes one click away.
function TextView({
  name,
  path,
  hash,
  revealed,
  annotations,
  hidden,
}: {
  name: string;
  path: string;
  hash: string;
  revealed: TextHead | null | undefined;
  annotations: StateAnnotation[];
  hidden: ReadonlySet<string>;
}) {
  const answer = useQuery({ queryKey: ['text', name, hash], queryFn: () => getText(name, hash) });
  const head = revealed ?? answer.data;
  if (!head) {
    return answer.isError ? (
      <NoPreview path={path} why="The file could not be read just now; the bytes are one click away." />
    ) : (
      <p className="quiet">Reading the file…</p>
    );
  }
  if (head.withheld)
    return <NoPreview path={path} why="Restricted: the text is withheld until you reveal this item; the reveal is logged." />;
  if (head.binary || head.text === null)
    return <NoPreview path={path} why="A binary file: no preview for its type; the bytes are one click away." />;
  return (
    <section className="drawer-text" aria-label="Text">
      {annotations.some((a) => a.kind === 'span') ? (
        <SpannedText text={head.text} annotations={annotations} hidden={hidden} />
      ) : (
        <pre className="data">{head.text}</pre>
      )}
      {head.truncated && (
        <p className="quiet">
          The first {humanBytes(head.text.length)} of {humanBytes(head.size)}; download the file for the rest.
        </p>
      )}
    </section>
  );
}

// Where an annotation sits, beside its class in the drawer's list, for
// the kinds whose place is not drawn on a picture: a time range, a
// transcript's words, a span's code points.
function AnnWhere({ a }: { a: StateAnnotation }) {
  const t = parseTime(a);
  if (t) {
    return (
      <span className="data">
        {' '}
        {clock(t.start)}–{clock(t.end)}
        {t.text !== null && <span className="ann-text"> “{t.text}”</span>}
      </span>
    );
  }
  const s = parseSpan(a);
  if (s) return <span className="data"> {`characters ${s.start.toLocaleString()}–${s.end.toLocaleString()}`}</span>;
  return null;
}

// An annotation's attributes and where it came from: each attribute as
// the attribute filter words it (`occluded=true`), a link that narrows
// Browse to the items carrying it, an identity to the identity filter;
// a value that is not one word, number or yes/no is shown, not offered.
// Then who made it and under which labelling policy.
function AnnFacts({ a, onFilters }: { a: StateAnnotation; onFilters?: (patch: FilterPatch) => void }) {
  const attrs = a.attrs !== null && typeof a.attrs === 'object' && !Array.isArray(a.attrs) ? Object.entries(a.attrs as Record<string, unknown>) : [];
  return (
    <div className="ann-facts">
      {attrs.map(([key, value]) => {
        const scalar = typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean';
        const text = `${key}=${scalar ? String(value) : JSON.stringify(value)}`;
        if (!scalar || !onFilters || (key === 'identity' && typeof value === 'boolean'))
          return (
            <span key={key} className="chip data ann-attr">
              {text}
            </span>
          );
        const patch: FilterPatch = key === 'identity' ? { identity: String(value) } : { attr: text };
        return (
          <button
            key={key}
            className="chip data ann-attr"
            title={key === 'identity' ? `Show the items naming ${String(value)}` : `Show the items with ${text}`}
            onClick={() => onFilters(patch)}
          >
            {text}
          </button>
        );
      })}
      <span className="quiet">
        by {a.author}
        {a.policy_ver ? ` · policy ${a.policy_ver}` : ''}
      </span>
    </div>
  );
}

function NoPreview({ path, why }: { path: string; why: string }) {
  return (
    <div className="drawer-media drawer-media--none blueprint">
      <span className="data">{extOf(path)}</span>
      <p className="quiet">{why}</p>
    </div>
  );
}

// A PDF: its pages as the worker drew them, one under another, the first
// ten at most; the thumbnail until they exist, and never a restricted
// dataset's (its pages are its text, withheld as text is).
function PdfView({ name, hash, path, thumb }: { name: string; hash: string; path: string; thumb: string | undefined }) {
  const pages = useQuery({ queryKey: ['pdf-pages', name, hash], queryFn: () => getPdfPages(name, hash) });
  const p = pages.data;
  if (!p || p.urls.length === 0)
    return thumb ? (
      <Thumb className="drawer-media" src={thumb} alt={path} label=".pdf" />
    ) : (
      <p className="quiet">{p?.withheld ? 'The pages of a restricted document are withheld.' : 'The pages appear when the preview worker reaches this file.'}</p>
    );
  return (
    <section className="pdf-pages" aria-label="Pages">
      {p.urls.map((url, i) => (
        <figure key={url} className="pdf-page">
          <img src={url} alt={`${path}, page ${i + 1}`} loading={i === 0 ? 'eager' : 'lazy'} />
          <figcaption className="quiet data">
            page {i + 1} of {p.pages.toLocaleString()}
          </figcaption>
        </figure>
      ))}
      {p.pages > p.urls.length && (
        <p className="quiet">
          The first {p.urls.length} of {p.pages.toLocaleString()} pages; download the file for the rest.
        </p>
      )}
    </section>
  );
}
