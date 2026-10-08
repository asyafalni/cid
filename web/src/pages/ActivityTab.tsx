import { useQuery } from '@tanstack/react-query';
import { ApiError, getActivity } from '../api';

// Activity (docs/dashboard.md §4.7): who did what to this dataset, newest
// first. It names who revealed restricted items, so only owners read it;
// anyone else is told so in words, never a blank page.
export function ActivityTab({ name }: { name: string }) {
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
  return (
    <table className="browse-table activity-table">
      <caption className="quiet">Newest first; the last 200 events.</caption>
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
            <td className="data">{e.ref ? `${e.ref.slice(0, 12)}…` : describe(e.detail)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
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
