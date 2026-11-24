import { useInfiniteQuery, useQuery } from '@tanstack/react-query';
import { Link } from '@tanstack/react-router';
import { RowsSkeleton } from '../Skeleton';
import { ApiError, getActivity } from '../api';

// Activity (docs/dashboard.md §4.7): who did what to this dataset, newest
// first, as far back as the log goes. It names who revealed restricted items, so only owners read it;
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
  // Narrowed on the server, so a filter reaches the whole log; older
  // events a page of 200 at a time. The choices come from the whole log
  // too (the first page names them), unnarrowed so they never shrink.
  const log = useInfiniteQuery({
    queryKey: ['activity', name, what ?? null, who ?? null],
    queryFn: ({ pageParam }) => getActivity(name, { what, who, before: pageParam ?? undefined }),
    initialPageParam: null as string | null,
    getNextPageParam: (last) => last.next,
    retry: false,
  });
  const choices = useQuery({
    queryKey: ['activity', name, null, null],
    queryFn: () => getActivity(name),
    enabled: !!(what || who),
    retry: false,
    select: (p) => ({ actions: p.actions ?? [], people: p.people ?? [] }),
  });

  if (log.isPending) return <RowsSkeleton rows={6} cols={4} />;
  if (log.isError) {
    const err = log.error;
    return (
      <div className="panel notice" role="alert">
        <p>{err instanceof ApiError ? err.message : 'The server did not answer.'}</p>
        {err instanceof ApiError && err.next && <p className="quiet">{err.next}</p>}
      </div>
    );
  }
  const events = log.data.pages.flatMap((p) => p.events);
  const first = log.data.pages[0];
  const narrowed = !!(what || who);
  if (events.length === 0 && !narrowed) {
    return (
      <div className="empty blueprint">
        <h2>Nothing on the record yet</h2>
        <p className="quiet">Reveals, purges and, in a restricted dataset, every read of its content appear here as they happen.</p>
      </div>
    );
  }
  const actions = (narrowed ? choices.data?.actions : first.actions) ?? [];
  const people = ((narrowed ? choices.data?.people : first.people) ?? []).map(
    (p) => [p.account_id, p.display_name ?? p.account_id] as [string, string],
  );
  const more = log.hasNextPage;
  const noun = (n: number) => `${n.toLocaleString()} ${n === 1 ? 'event' : 'events'}`;
  return (
    <>
    <div className="filter-bar" role="search" aria-label="Filter the log">
      <Narrow label="what" value={what} options={actions.map((a) => [a, a])} onChange={(v) => onFilter({ what: v })} />
      <Narrow label="who" value={who} options={people} onChange={(v) => onFilter({ who: v })} />
      {narrowed && (
        <button className="filter-clear" onClick={() => onFilter({ what: undefined, who: undefined })}>
          Clear
        </button>
      )}
    </div>
    {events.length === 0 && <p className="quiet">Nothing in the log matches; clear a filter to see it all.</p>}
    {events.length > 0 && (
    <table className="browse-table activity-table">
      <caption className="quiet">
        Newest first;{' '}
        {more
          ? `the newest ${noun(events.length)}${narrowed ? ' that match' : ''}, older ones below`
          : narrowed
            ? `all ${noun(events.length)} that match`
            : `all ${noun(events.length)}`}
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
        {events.map((e, i) => (
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
    )}
    {more && (
      <button className="action more-items" disabled={log.isFetchingNextPage} onClick={() => void log.fetchNextPage()}>
        {log.isFetchingNextPage ? 'Reading…' : 'Show older events'}
      </button>
    )}
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
