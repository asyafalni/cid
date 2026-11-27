import { useEffect, useRef, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Link, useNavigate, useSearch } from '@tanstack/react-router';
import { ApiError, getMe, kindLabel, listDatasets, setStar, type DatasetSummary } from '../api';
import { humanBytes } from '../format';
import { Thumb } from '../Thumb';
import { Airship } from '../Airship';
import { HomeSkeleton } from '../Skeleton';
import { recentDatasets } from '../recent';
import { HomeSidebar } from '../HomeSidebar';
import { facetKeys, facetTitle, matching, valueLabel, type HomeSearch } from '../homeFilter';
import { typingIn } from '../keys';

// Datasets home (docs/dashboard.md §4.1): the fleet. A sky with the search
// in it, then a card per dataset, led by a mosaic of real previews (or type
// tiles for data that is not visual), with the kind, file types, size,
// newest release and last activity; or the same as compact rows (List).
// Beside them, a sidebar: the way back to starred and recent datasets,
// the path tree, and each filter as a list with its counts (roadmap U12).
// Search, filters, the sort and the layout live in the URL, like Browse's.
export function Home() {
  const search = useSearch({ strict: false }) as HomeSearch;
  const navigate = useNavigate();
  const query = useQuery({ queryKey: ['datasets'], queryFn: listDatasets });
  const me = useQuery({ queryKey: ['me'], queryFn: getMe });
  const person = me.data?.via !== undefined && me.data.via !== 'token';
  const client = useQueryClient();
  const toggleStar = useMutation({
    mutationFn: ({ name, on }: { name: string; on: boolean }) => setStar(name, on),
    onSuccess: () => client.invalidateQueries({ queryKey: ['datasets'] }),
  });

  const setSearch = (patch: Partial<HomeSearch>) =>
    void navigate({ to: '/', search: (old: Record<string, unknown>) => ({ ...old, ...patch }) });

  // The search box commits after a pause: one history entry per word.
  const [typed, setTyped] = useState(search.q ?? '');
  // The URL moved under the box (back button, a pasted link): follow it.
  // Adjusted during render, React's pattern for state derived from props.
  const [seenQ, setSeenQ] = useState(search.q);
  if (search.q !== seenQ) {
    setSeenQ(search.q);
    setTyped(search.q ?? '');
  }
  useEffect(() => {
    if (typed === (search.q ?? '')) return;
    const timer = setTimeout(() => setSearch({ q: typed === '' ? undefined : typed }), 250);
    return () => clearTimeout(timer);
  });

  // `/` goes to the search and `f` to the first filter, as in Browse.
  const searchRef = useRef<HTMLInputElement>(null);
  const sideRef = useRef<HTMLElement>(null);
  // On a narrow screen the sidebar is folded under a button.
  const [filtersOpen, setFiltersOpen] = useState(false);
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (typingIn(e) || e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.key === '/') {
        e.preventDefault();
        searchRef.current?.focus();
      } else if (e.key === 'f') {
        e.preventDefault();
        setFiltersOpen(true);
        // After the fold opens, when it was shut.
        requestAnimationFrame(() => sideRef.current?.querySelector<HTMLElement>('.side-value:not(:disabled)')?.focus());
      }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  if (query.isPending) return <HomeSkeleton />;
  if (query.isError) {
    const err = query.error;
    return (
      <div className="panel notice" role="alert">
        <p>{err instanceof ApiError ? err.message : 'The server did not answer.'}</p>
        {err instanceof ApiError && err.next && <p className="quiet">{err.next}</p>}
      </div>
    );
  }

  const datasets = query.data.datasets;
  if (datasets.length === 0) {
    return (
      <div className="empty blueprint">
        <Airship className="empty-airship" />
        <h2>No datasets yet</h2>
        <p>The hangar is empty. Create the first dataset from a folder of files:</p>
        <code className="chip">cid init cid@host:org/datasets/name --git &lt;git-url&gt;</code>
      </div>
    );
  }

  const shown = sorted(matching(datasets, search), search.sort);
  const on = facetKeys.filter((k) => search[k] !== undefined);
  const filtered = Boolean(search.q) || on.length > 0;
  const none = Object.fromEntries(facetKeys.map((k) => [k, undefined])) as Partial<HomeSearch>;
  const byName = new Map(datasets.map((d) => [d.name, d]));
  const recent = recentDatasets().filter((n) => byName.has(n));
  const starred = datasets.filter((d) => d.starred).map((d) => d.name);
  const list = search.layout === 'list';

  const star = (d: DatasetSummary) =>
    person && (
      <button
        className={d.starred ? 'star star--on' : 'star'}
        aria-pressed={d.starred}
        aria-label={d.starred ? `Unstar ${d.name}` : `Star ${d.name}`}
        onClick={() => toggleStar.mutate({ name: d.name, on: !d.starred })}
      >
        {d.starred ? '★' : '☆'}
      </button>
    );

  return (
    <div className="home">
      <header className="home-hero sky-band">
        <div className="sky-clouds" aria-hidden="true" />
        <Airship className="home-airship" />
        <div className="home-hero-inner">
          <h1>Datasets</h1>
          <p className="home-count" aria-live="polite">
            {filtered
              ? `${shown.length} of ${datasets.length} datasets`
              : `${datasets.length} ${datasets.length === 1 ? 'dataset' : 'datasets'} on this server`}
          </p>
          <input
            type="search"
            className="home-search"
            placeholder="Search datasets"
            aria-label="Search datasets"
            ref={searchRef}
            value={typed}
            onChange={(e) => setTyped(e.target.value)}
          />
          <p className="home-hint">Names, classes, file types and owners.</p>
        </div>
      </header>

      <div className="home-body">
        <button
          className="home-filters-toggle"
          aria-expanded={filtersOpen}
          aria-controls="home-side"
          onClick={() => setFiltersOpen((o) => !o)}
        >
          Filters{on.length > 0 ? ` (${on.length} on)` : ''}
        </button>
        <aside id="home-side" ref={sideRef} className={filtersOpen ? 'home-side home-side--open' : 'home-side'} aria-label="Filter datasets">
          <HomeSidebar datasets={datasets} search={search} starred={starred} recent={recent} onPick={setSearch} />
        </aside>

        <div className="home-main">
          <div className="home-bar">
            {/* What is on, each with its own way off. */}
            {on.map((k) => (
              <button
                key={k}
                className="chip home-on"
                aria-label={`Remove the filter ${facetTitle[k]}: ${valueLabel(k, search[k]!)}`}
                onClick={() => setSearch({ [k]: undefined })}
              >
                <span className="quiet">{facetTitle[k].toLowerCase()}</span> {valueLabel(k, search[k]!)}
                <span aria-hidden="true"> ×</span>
              </button>
            ))}
            {filtered && (
              <button className="filter-clear" onClick={() => setSearch({ q: undefined, ...none })}>
                Clear filters
              </button>
            )}
            <label className="facet home-sort">
              <span className="facet-label" aria-hidden="true">
                sort
              </span>
              <select
                aria-label="Sort datasets"
                value={search.sort ?? 'pushed'}
                onChange={(e) => setSearch({ sort: e.target.value === 'pushed' ? undefined : (e.target.value as HomeSearch['sort']) })}
              >
                <option value="pushed">newest push</option>
                <option value="name">name</option>
                <option value="size">size</option>
                <option value="items">items</option>
              </select>
            </label>
            <div className="format-picker home-layout" role="radiogroup" aria-label="Layout">
              {(['cards', 'list'] as const).map((m) => (
                <button
                  key={m}
                  role="radio"
                  aria-checked={(m === 'list') === list}
                  className={(m === 'list') === list ? 'format on' : 'format'}
                  onClick={() => setSearch({ layout: m === 'list' ? 'list' : undefined })}
                >
                  {m}
                </button>
              ))}
            </div>
          </div>

          {shown.length === 0 ? (
            <div className="empty blueprint">
              <h2>No dataset matches</h2>
              <p className="quiet">Search looks at names, classes, file types and owners. Clear the filters to see every dataset.</p>
            </div>
          ) : list ? (
            <ul className="manifest">
              {shown.map((d) => (
                <li key={d.name} className="manifest-row panel">
                  <Mosaic dataset={d} />
                  <div className="manifest-main">
                    <Link to="/d/$" params={{ _splat: d.name }} className="data manifest-name">
                      {d.name}
                    </Link>
                    <span className="manifest-kind">{kindLabel(d.kind)}</span>
                    {d.restricted && <span className="chip restricted-badge">restricted</span>}
                    {d.owners.length > 0 && <span className="quiet manifest-owners">owned by {d.owners.join(', ')}</span>}
                    <p className="manifest-facts quiet data">
                      <Facts d={d} />
                    </p>
                  </div>
                  <div className="manifest-side">
                    {star(d)}
                    <Release d={d} />
                  </div>
                </li>
              ))}
            </ul>
          ) : (
            <ul className="ds-cards">
              {shown.map((d) => (
                <li key={d.name} className="ds-card panel">
                  <Mosaic dataset={d} />
                  <div className="ds-card-body">
                    <div className="ds-card-title">
                      {/* The whole card is the link's target area (::after). */}
                      <Link to="/d/$" params={{ _splat: d.name }} className="ds-card-link data">
                        {d.name}
                      </Link>
                      {star(d)}
                    </div>
                    <p className="ds-card-kind">
                      {kindLabel(d.kind)}
                      {d.restricted && <span className="chip restricted-badge">restricted</span>}
                      {d.owners.length > 0 && <span className="quiet"> · owned by {d.owners.join(', ')}</span>}
                    </p>
                    <p className="ds-card-facts data">
                      <Facts d={d} />
                    </p>
                    <div className="ds-card-foot">
                      <Release d={d} />
                    </div>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  );
}

/** Newest push first unless asked otherwise; a name settles every tie, so
 * the order never depends on the server's. */
function sorted(datasets: DatasetSummary[], sort: HomeSearch['sort']): DatasetSummary[] {
  const by = (d: DatasetSummary) => (sort === 'size' ? d.bytes : sort === 'items' ? d.items : 0);
  return [...datasets].sort((a, b) => {
    if (sort === 'name') return a.name.localeCompare(b.name);
    if (sort === undefined) return (b.last_push ?? '').localeCompare(a.last_push ?? '') || a.name.localeCompare(b.name);
    return by(b) - by(a) || a.name.localeCompare(b.name);
  });
}

function Facts({ d }: { d: DatasetSummary }) {
  return (
    <>
      {d.items.toLocaleString()} {d.items === 1 ? 'item' : 'items'} · {humanBytes(d.bytes)}
      {d.types.length > 0 && <> · {d.types.slice(0, 4).map((t) => t.ext).join(' ')}</>}
      {d.classes.length > 0 && (
        <> · {d.classes.length} {d.classes.length === 1 ? 'class' : 'classes'}</>
      )}
    </>
  );
}

function Release({ d }: { d: DatasetSummary }) {
  return (
    <>
      {d.latest_release ? (
        <span className="release-tag">{d.latest_release}</span>
      ) : (
        <span className="quiet">no releases yet</span>
      )}
      {d.last_push && <span className="quiet data">{d.last_push.slice(0, 10)}</span>}
      <HealthMark d={d} />
    </>
  );
}

// The head's checks, as an icon and words (never colour alone), a link to
// the Health tab; nothing until the server has kept them.
function HealthMark({ d }: { d: DatasetSummary }) {
  const h = d.health;
  if (!h) return null;
  const words =
    h.fail === 0 && h.warn === 0
      ? 'checks pass'
      : [h.fail > 0 ? `${h.fail} failed` : null, h.warn > 0 ? `${h.warn} ${h.warn === 1 ? 'warning' : 'warnings'}` : null]
          .filter(Boolean)
          .join(', ');
  const level = h.fail > 0 ? 'fail' : h.warn > 0 ? 'warn' : 'pass';
  return (
    <Link
      to="/d/$"
      params={{ _splat: d.name }}
      search={{ view: 'health' }}
      className={`ds-card-health ds-card-health--${level} data`}
      aria-label={`Health: ${words}`}
    >
      <span aria-hidden="true">{level === 'pass' ? '✓' : level === 'warn' ? '!' : '✕'}</span> {words}
    </Link>
  );
}

// Real previews where the worker has built them; otherwise the dataset's
// most common file types as tiles — never a blank square, and never a
// clear thumbnail of a restricted dataset (the server sends none).
function Mosaic({ dataset: d }: { dataset: DatasetSummary }) {
  if (d.mosaic.length > 0) {
    return (
      <span className={`mosaic mosaic--${Math.min(d.mosaic.length, 4)}`} aria-hidden="true">
        {d.mosaic.slice(0, 4).map((m) => (
          <Thumb key={m.hash} src={m.url} alt="" label="" lazy />
        ))}
      </span>
    );
  }
  const tiles = d.types.slice(0, 4);
  return (
    <span className={`mosaic mosaic--types mosaic--${Math.max(1, tiles.length)}`} aria-hidden="true">
      {tiles.length === 0 ? (
        <span className="mosaic-type mosaic-type--empty data">no items yet</span>
      ) : (
        // Data that is not pictures: each kind of file with how many, so a
        // card says what the dataset holds instead of showing a pale tile.
        tiles.map((t) => (
          <span key={t.ext} className="mosaic-type data">
            <span className="mosaic-type-ext">{t.ext}</span>
            <span className="mosaic-type-count">{t.count.toLocaleString()}</span>
          </span>
        ))
      )}
    </span>
  );
}
