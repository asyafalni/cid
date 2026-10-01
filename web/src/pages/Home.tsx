import { useQuery } from '@tanstack/react-query';
import { ApiError, listDatasets } from '../api';

// Datasets home: the fleet, one row per dataset. Rows, not a card grid —
// a manifest reads downward. The release tag wears brass; the kind and
// format are words, never color alone.
export function Home() {
  const query = useQuery({ queryKey: ['datasets'], queryFn: listDatasets });

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

  return (
    <>
      <header className="deck-head">
        <h1>Datasets</h1>
        <p className="quiet">
          {datasets.length} {datasets.length === 1 ? 'dataset' : 'datasets'} on this server
        </p>
      </header>
      <ul className="manifest">
        {datasets.map((d) => (
          <li key={d.name} className="manifest-row panel">
            <div className="manifest-main">
              <span className="data manifest-name">{d.name}</span>
              <span className="manifest-kind">{d.kind === 'annotated' ? 'annotated' : 'files'}</span>
            </div>
            <div className="manifest-side">
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
    </>
  );
}
