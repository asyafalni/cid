import { useQuery } from '@tanstack/react-query';
import { Link, useNavigate, useParams, useSearch } from '@tanstack/react-router';
import { ApiError, getOverview } from '../api';
import { ReleaseTape } from '../ReleaseTape';
import { gitWebUrl } from '../format';
import { OverviewTab } from './OverviewTab';
import { BrowseTab } from './BrowseTab';

// The dataset page: sky-band header, the release tape, then the tabs.
// The tab, the pinned release and the open item all live in the URL, so
// pasting a link shows exactly the same thing.
export function DatasetOverview() {
  const { _splat: name = '' } = useParams({ strict: false });
  const search = useSearch({ strict: false }) as {
    view?: 'overview' | 'browse';
    release?: string;
    item?: string;
  };
  const navigate = useNavigate();
  const query = useQuery({
    queryKey: ['overview', name],
    queryFn: () => getOverview(name),
  });

  if (query.isPending) return <p className="quiet">Reading {name}…</p>;
  if (query.isError) {
    const err = query.error;
    return (
      <div className="panel notice" role="alert">
        <p>{err instanceof ApiError ? err.message : 'The server did not answer.'}</p>
        {err instanceof ApiError && err.next && <p className="quiet">{err.next}</p>}
      </div>
    );
  }

  const o = query.data;
  const releases = o.commits.filter((c) => c.release !== null);
  const pinned = search.release ?? releases[0]?.release ?? null;
  const pinnedCommit =
    o.commits.find((c) => c.release === pinned)?.id ?? o.commits[0]?.id ?? null;
  const view = search.view ?? 'overview';

  function setSearch(patch: Record<string, string | undefined>) {
    void navigate({
      to: '/d/$',
      params: { _splat: name },
      search: (old: Record<string, unknown>) => ({ ...old, ...patch }),
    });
  }

  return (
    <article className="dataset">
      <header className="dataset-head sky-band">
        <div className="dataset-head-inner">
          <h1 className="data dataset-name">{o.name}</h1>
          <p className="dataset-meta">
            {o.kind === 'annotated' ? 'annotated dataset' : 'file dataset'}
            {' — '}
            <a href={gitWebUrl(o.git_url)} target="_blank" rel="noreferrer">
              view in git
            </a>
          </p>
        </div>
      </header>

      <ReleaseTape
        commits={o.commits}
        pinned={pinned}
        onPick={(r) => setSearch({ release: r })}
      />

      <nav className="tabs" aria-label="Dataset views">
        <Link
          to="/d/$"
          params={{ _splat: name }}
          search={{ view: 'overview', release: search.release }}
          className={view === 'overview' ? 'tab on' : 'tab'}
          aria-current={view === 'overview' ? 'page' : undefined}
        >
          Overview
        </Link>
        <Link
          to="/d/$"
          params={{ _splat: name }}
          search={{ view: 'browse', release: search.release }}
          className={view === 'browse' ? 'tab on' : 'tab'}
          aria-current={view === 'browse' ? 'page' : undefined}
        >
          Browse
        </Link>
      </nav>

      {view === 'overview' ? (
        <OverviewTab overview={o} pinned={pinned} />
      ) : (
        <BrowseTab
          name={name}
          overview={o}
          commit={pinnedCommit}
          openItem={search.item}
          onOpenItem={(path) => setSearch({ item: path })}
        />
      )}
    </article>
  );
}

