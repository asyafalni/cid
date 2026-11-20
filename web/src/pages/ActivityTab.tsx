import { useQuery } from '@tanstack/react-query';
import { Link } from '@tanstack/react-router';
import { ApiError, getActivity } from '../api';

// Activity (docs/dashboard.md §4.7): who did what to this dataset, newest
// first. It names who revealed restricted items, so only owners read it;
// anyone else is told so in words, never a blank page.
export function ActivityTab({
  name,
  releases,
  what,
  who,
  onFilter,
}: {
  name: string;
  /** The dataset's releases, so an event about one links to it. */
  releases: ReadonlySet<string>;
  /** The action shown alone, from the URL. */
  what: string | undefined;
  /** The person shown alone (their account id), from the URL. */
  who: string | undefined;
  onFilter: (patch: { what?: string | undefined; who?: string | undefined }) => void;
}) {
  const log = useQuery({ queryKey: ['activity', name], queryFn: () => getActivity(name), retry: false });

  if (log.isPending) return <p className="quiet">Reading the log…</p>;
  if (log.isError) {
    const err = log.error;
    return (
      <div className="panel notice" role="alert">
        <p>{err instanceof ApiError ? err.message : 'The server did not answer.'}</p>
        {err instanceof ApiError && err.next && <p className="quiet">{err.next}</p>}
      </div>
    );
  }
  const events = log.data.events;
  if (events.length === 0) {
    return (
      <div className="empty blueprint">
        <h2>Nothing on the record yet</h2>
        <p className="quiet">Reveals, purges and, in a restricted dataset, every read of its content appear here as they happen.</p>
      </div>
    );
  }
  // Narrowing is over the events already here (the last 200), by what
  // was done and by whom; the choices are the ones the log holds.
  const actions = [...new Set(events.map((e) => e.action))].sort();
  const people = [...new Map(events.map((e) => [e.account_id, e.display_name ?? e.account_id]))].sort((x, y) =>
    x[1].localeCompare(y[1]),
  );
  const shown = events.filter((e) => (!what || e.action === what) && (!who || e.account_id === who));
  return (
    <>
    <div className="filter-bar" role="search" aria-label="Filter the log">
      <Narrow label="what" value={what} options={actions.map((a) => [a, a])} onChange={(v) => onFilter({ what: v })} />
      <Narrow label="who" value={who} options={people} onChange={(v) => onFilter({ who: v })} />
      {(what || who) && (
        <button className="filter-clear" onClick={() => onFilter({ what: undefined, who: undefined })}>
          Clear
        </button>
      )}
    </div>
    {shown.length === 0 && <p className="quiet">Nothing in the last 200 events matches; clear a filter to see them all.</p>}
    <table className="browse-table activity-table">
      <caption className="quiet">
        Newest first;{' '}
        {shown.length === events.length
          ? events.length < 200
            ? `all ${events.length} ${events.length === 1 ? 'event' : 'events'}`
            : 'the last 200 events'
          : `${shown.length} of the last ${events.length} events`}
        .
      </caption>
      <thead>
        <tr>
          <th>when (UTC)</th>
          <th>who</th>
          <th>what</th>
          <th>which</th>
        </tr>
      </thead>
      <tbody>
        {shown.map((e, i) => (
          <tr key={i}>
            <td className="data">{e.at.replace('T', ' ').replace('Z', '')}</td>
            <td title={e.account_id}>{e.display_name ?? e.account_id}</td>
            <td>
              <span className="chip">{e.action}</span>
            </td>
            <td className="data">{e.ref ? <Which name={name} value={e.ref} releases={releases} /> : describe(e.detail)}</td>
          </tr>
        ))}
      </tbody>
    </table>
    </>
  );
}

const any = '\u0000any';

function Narrow({
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
  // A value from the URL that the log no longer holds still shows as chosen.
  const all = value !== undefined && !options.some(([v]) => v === value) ? [...options, [value, value] as [string, string]] : options;
  return (
    <label className="facet">
      <span className="facet-label" aria-hidden="true">
        {label}
      </span>
      <select
        aria-label={`Filter by ${label}`}
        value={value ?? any}
        onChange={(e) => onChange(e.target.value === any ? undefined : e.target.value)}
      >
        <option value={any}>any</option>
        {all.map(([v, text]) => (
          <option key={v} value={v}>
            {text}
          </option>
        ))}
      </select>
    </label>
  );
}

// What an event was about: a release or a commit is a link to that
// version; a content hash is cut, with the whole of it on hover; anything
// else is shown as it is.
function Which({ name, value, releases }: { name: string; value: string; releases: ReadonlySet<string> }) {
  if (releases.has(value))
    return (
      <Link to="/d/$" params={{ _splat: name }} search={{ release: value }}>
        {value}
      </Link>
    );
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value))
    return (
      <Link to="/d/$" params={{ _splat: name }} search={{ commit: value }} title={value}>
        {value.slice(0, 13)}
      </Link>
    );
  if (/^[0-9a-f]{64}$/.test(value)) return <span title={value}>{value.slice(0, 12)}…</span>;
  return <span>{value}</span>;
}

function describe(detail: string | null): string {
  if (!detail) return '';
  try {
    const d = JSON.parse(detail) as Record<string, unknown>;
    if (typeof d.items === 'number') return `${d.items} item${d.items === 1 ? '' : 's'}`;
    if (typeof d.reason === 'string') return d.reason;
  } catch {
    // an unreadable detail shows nothing rather than breaking the row
  }
  return '';
}
