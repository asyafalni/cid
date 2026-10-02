import { useEffect } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Link, useNavigate, useParams, useSearch } from '@tanstack/react-router';
import { ApiError, getOverview } from '../api';
import { ReleaseTape } from '../ReleaseTape';
import { gitWebUrl } from '../format';
import { OverviewTab } from './OverviewTab';
import { BrowseTab } from './BrowseTab';
import { ReleasesTab } from './ReleasesTab';
import { FilesTab } from './FilesTab';
import { ActivityTab } from './ActivityTab';
import { noteVisit } from '../recent';

// The dataset page: sky-band header, the release tape, then the tabs.
// The tab, the pinned release and the open item all live in the URL, so
// pasting a link shows exactly the same thing.
export function DatasetOverview() {
  const { _splat: name = '' } = useParams({ strict: false });
  const search = useSearch({ strict: false }) as {
    view?: 'overview' | 'browse' | 'releases' | 'files' | 'activity';
    release?: string;
    item?: string;
    a?: string;
    b?: string;
    dir?: string;
    mode?: 'table';
    q?: string;
    split?: string;
    class?: string;
    type?: string;
  };
  const navigate = useNavigate();
  const query = useQuery({
    queryKey: ['overview', name],
    queryFn: () => getOverview(name),
  });
  // Remembered only once the dataset answered: a mistyped link is not a visit.
  const found = query.isSuccess;
  useEffect(() => {
    if (found) noteVisit(name);
  }, [found, name]);

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
        <Link
          to="/d/$"
          params={{ _splat: name }}
          search={{ view: 'releases', release: search.release }}
          className={view === 'releases' ? 'tab on' : 'tab'}
          aria-current={view === 'releases' ? 'page' : undefined}
        >
          Releases
        </Link>
        <Link
          to="/d/$"
          params={{ _splat: name }}
          search={{ view: 'files', release: search.release }}
          className={view === 'files' ? 'tab on' : 'tab'}
          aria-current={view === 'files' ? 'page' : undefined}
        >
          Files
        </Link>
        <Link
          to="/d/$"
          params={{ _splat: name }}
          search={{ view: 'activity', release: search.release }}
          className={view === 'activity' ? 'tab on' : 'tab'}
          aria-current={view === 'activity' ? 'page' : undefined}
        >
          Activity
        </Link>
      </nav>

      {view === 'overview' ? (
        <OverviewTab overview={o} pinned={pinned} />
      ) : view === 'browse' ? (
        <BrowseTab
          name={name}
          overview={o}
          commit={pinnedCommit}
          openItem={search.item}
          onOpenItem={(path) => setSearch({ item: path })}
          filters={{ mode: search.mode, q: search.q, split: search.split, cls: search.class, type: search.type }}
          onFilters={(patch) => setSearch(patch)}
        />
      ) : view === 'releases' ? (
        <ReleasesTab
          name={name}
          overview={o}
          a={search.a}
          b={search.b}
          onPick={(patch) => setSearch(patch)}
        />
      ) : view === 'activity' ? (
        <ActivityTab name={name} />
      ) : (
        <FilesTab
          name={name}
          commit={pinnedCommit}
          openDir={search.dir}
          onOpenDir={(dir) => setSearch({ dir })}
        />
      )}
    </article>
  );
}

