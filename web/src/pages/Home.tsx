import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Link, useNavigate, useSearch } from '@tanstack/react-router';
import { ApiError, getMe, listDatasets, setStar, type DatasetSummary } from '../api';
import { humanBytes } from '../format';
import { recentDatasets } from '../recent';

type HomeSearch = {
  q?: string;
  kind?: 'files' | 'annotated';
  type?: string;
  released?: 'yes' | 'no';
  restricted?: 'yes' | 'no';
};

// Datasets home (docs/dashboard.md §4.1): the fleet, one row per dataset.
// Rows, not a card grid — a manifest reads downward — but each row is the
// card: a mosaic of real previews (or type tiles for data that is not
// visual), the kind, the file types, the size, the newest release and the
// last activity. Search and filters live in the URL, like Browse's.
export function Home() {
  const search = useSearch({ strict: false }) as HomeSearch;
  const navigate = useNavigate();
  const query = useQuery({ queryKey: ['datasets'], queryFn: listDatasets });
  const me = useQuery({ queryKey: ['me'], queryFn: getMe });
  const person = me.data?.via === 'gitlab';
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

  if (query.isPending) {
    return <p className="quiet">Reading the manifest…</p>;
  }
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
        <h2>No datasets yet</h2>
        <p>Create the first one from a folder of files:</p>
        <code className="chip">cid init cid@host:org/datasets/name --git &lt;git-url&gt;</code>
      </div>
    );
  }

  const shown = datasets.filter((d) => matches(d, search));
  const filtered = Boolean(search.q || search.kind || search.type || search.released || search.restricted);
  const allTypes = [...new Set(datasets.flatMap((d) => d.types.map((t) => t.ext)))].sort();
  const anyRestricted = datasets.some((d) => d.restricted);
  const byName = new Map(datasets.map((d) => [d.name, d]));
  const recent = recentDatasets().filter((n) => byName.has(n));
  const starred = datasets.filter((d) => d.starred);

  return (
    <>
      <header className="deck-head">
        <h1>Datasets</h1>
        <p className="quiet" aria-live="polite">
          {filtered
            ? `${shown.length} of ${datasets.length} datasets`
            : `${datasets.length} ${datasets.length === 1 ? 'dataset' : 'datasets'} on this server`}
        </p>
      </header>

      {!filtered && starred.length > 0 && (
        <nav className="recent" aria-label="Starred">
          <span className="quiet">Starred</span>
          {starred.map((d) => (
            <Link key={d.name} to="/d/$" params={{ _splat: d.name }} className="chip data">
              {d.name}
            </Link>
          ))}
        </nav>
      )}

      {!filtered && recent.length > 0 && (
        <nav className="recent" aria-label="Recently viewed">
          <span className="quiet">Recently viewed</span>
          {recent.map((n) => (
            <Link key={n} to="/d/$" params={{ _splat: n }} className="chip data">
              {n}
            </Link>
          ))}
        </nav>
      )}

      <div className="filter-bar" role="search">
        <input
          type="search"
          className="filter-q data"
          placeholder="name, class, file type or owner…"
          aria-label="Search datasets"
          value={typed}
          onChange={(e) => setTyped(e.target.value)}
        />
        <Picker
          label="kind"
          value={search.kind}
          options={[
            ['files', 'files'],
            ['annotated', 'annotated'],
          ]}
          onChange={(v) => setSearch({ kind: v as HomeSearch['kind'] })}
        />
        <Picker
          label="type"
          value={search.type}
          options={allTypes.map((t) => [t, t === 'file' ? 'no extension' : t])}
          onChange={(v) => setSearch({ type: v })}
        />
        <Picker
          label="releases"
          value={search.released}
          options={[
            ['yes', 'has releases'],
            ['no', 'none yet'],
          ]}
          onChange={(v) => setSearch({ released: v as HomeSearch['released'] })}
        />
        {anyRestricted && (
          <Picker
            label="restricted"
            value={search.restricted}
            options={[
              ['yes', 'restricted'],
              ['no', 'open'],
            ]}
            onChange={(v) => setSearch({ restricted: v as HomeSearch['restricted'] })}
          />
        )}
        {filtered && (
          <button
            className="filter-clear"
            onClick={() =>
              setSearch({ q: undefined, kind: undefined, type: undefined, released: undefined, restricted: undefined })
            }
          >
            Clear filters
          </button>
        )}
      </div>

      {shown.length === 0 ? (
        <div className="empty blueprint">
          <h2>No dataset matches</h2>
          <p className="quiet">Search looks at names, classes and file types. Clear the filters to see every dataset.</p>
        </div>
      ) : (
        <ul className="manifest">
          {shown.map((d) => (
            <li key={d.name} className="manifest-row panel">
              <Mosaic dataset={d} />
              <div className="manifest-main">
                <Link to="/d/$" params={{ _splat: d.name }} className="data manifest-name">
                  {d.name}
                </Link>
                <span className="manifest-kind">{d.kind === 'annotated' ? 'annotated' : 'files'}</span>
                {d.restricted && <span className="chip restricted-badge">restricted</span>}
                {d.owners.length > 0 && (
                  <span className="quiet manifest-owners">owned by {d.owners.join(', ')}</span>
                )}
                <p className="manifest-facts quiet data">
                  {d.items.toLocaleString()} {d.items === 1 ? 'item' : 'items'} · {humanBytes(d.bytes)}
                  {d.types.length > 0 && <> · {d.types.slice(0, 4).map((t) => t.ext).join(' ')}</>}
                  {d.classes.length > 0 && (
                    <> · {d.classes.length} {d.classes.length === 1 ? 'class' : 'classes'}</>
                  )}
                </p>
              </div>
              <div className="manifest-side">
                {person && (
                  <button
                    className={d.starred ? 'star star--on' : 'star'}
                    aria-pressed={d.starred}
                    aria-label={d.starred ? `Unstar ${d.name}` : `Star ${d.name}`}
                    onClick={() => toggleStar.mutate({ name: d.name, on: !d.starred })}
                  >
                    {d.starred ? '★' : '☆'}
                  </button>
                )}
                {d.latest_release ? (
                  <span className="release-tag">{d.latest_release}</span>
                ) : (
                  <span className="quiet">no releases yet</span>
                )}
                {d.last_push && <span className="quiet data">{d.last_push.slice(0, 10)}</span>}
              </div>
            </li>
          ))}
        </ul>
      )}
    </>
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
          <img key={m.hash} src={m.url} alt="" loading="lazy" />
        ))}
      </span>
    );
  }
  const tiles = d.types.slice(0, 4);
  return (
    <span className={`mosaic mosaic--types mosaic--${Math.max(1, tiles.length)}`} aria-hidden="true">
      {tiles.length === 0 ? (
        <span className="mosaic-type data">empty</span>
      ) : (
        tiles.map((t) => (
          <span key={t.ext} className="mosaic-type data">
            {t.ext === 'file' ? '·' : t.ext}
          </span>
        ))
      )}
    </span>
  );
}

function Picker({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: string | undefined;
  options: [string, string][];
  onChange: (value: string | undefined) => void;
}) {
  return (
    <label className="facet">
      <span className="facet-label" aria-hidden="true">
        {label}
      </span>
      <select
        aria-label={`Filter by ${label}`}
        value={value ?? '\u0000any'}
        onChange={(e) => onChange(e.target.value === '\u0000any' ? undefined : e.target.value)}
      >
        <option value={'\u0000any'}>any</option>
        {options.map(([v, text]) => (
          <option key={v} value={v}>
            {text}
          </option>
        ))}
      </select>
    </label>
  );
}

function matches(d: DatasetSummary, s: HomeSearch): boolean {
  if (s.kind && d.kind !== s.kind) return false;
  if (s.type && !d.types.some((t) => t.ext === s.type)) return false;
  if (s.released === 'yes' && !d.latest_release) return false;
  if (s.released === 'no' && d.latest_release) return false;
  if (s.restricted === 'yes' && !d.restricted) return false;
  if (s.restricted === 'no' && d.restricted) return false;
  if (s.q) {
    const q = s.q.toLowerCase();
    const hit =
      d.name.toLowerCase().includes(q) ||
      d.classes.some((c) => c.toLowerCase().includes(q)) ||
      d.types.some((t) => t.ext.toLowerCase().includes(q)) ||
      d.owners.some((o) => o.toLowerCase().includes(q));
    if (!hit) return false;
  }
  return true;
}
