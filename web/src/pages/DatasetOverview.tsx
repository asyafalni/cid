import { useEffect, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Link, useNavigate, useParams, useSearch } from '@tanstack/react-router';
import { ApiError, getOverview, type Pin } from '../api';
import { ReleaseTape } from '../ReleaseTape';
import { commandFor, type Shown } from '../command';
import { gitWebUrl, humanBytes } from '../format';
import { OverviewTab } from './OverviewTab';
import { BrowseTab } from './BrowseTab';
import { ReleasesTab } from './ReleasesTab';
import { FilesTab } from './FilesTab';
import { ActivityTab } from './ActivityTab';
import { noteVisit } from '../recent';
import { NotFound } from './NotFound';

// The dataset page: the sky header (name, facts, the release tape), then
// the tabs.
// The tab, the pinned release and the open item all live in the URL, so
// pasting a link shows exactly the same thing.
export function DatasetOverview() {
  const { _splat: name = '' } = useParams({ strict: false });
  const search = useSearch({ strict: false }) as {
    view?: 'overview' | 'browse' | 'releases' | 'files' | 'activity';
    release?: string;
    commit?: string;
    branch?: string;
    item?: string;
    a?: string;
    b?: string;
    dir?: string;
    mode?: 'table';
    q?: string;
    split?: string;
    class?: string;
    type?: string;
    what?: string;
    who?: string;
  };
  const navigate = useNavigate();
  // A view affordance, not a view: kept while moving between tabs, not in the URL.
  const [showCommand, setShowCommand] = useState(false);
  const query = useQuery({
    queryKey: ['overview', name, search.release ?? null, search.commit ?? null, search.branch ?? null],
    queryFn: () => getOverview(name, search.release, search.commit, search.branch),
    // Pinning another release keeps the page up while its counts arrive.
    placeholderData: (previous, previousQuery) =>
      previousQuery?.queryKey[1] === name ? previous : undefined,
  });
  // Remembered only once the dataset answered: a mistyped link is not a visit.
  const found = query.isSuccess;
  useEffect(() => {
    if (found) noteVisit(name);
  }, [found, name]);

  if (query.isPending) return <p className="quiet">Reading {name}…</p>;
  if (query.isError) {
    const err = query.error;
    if (err instanceof ApiError && err.status === 404) {
      return <NotFound what={`No dataset is named ${name}, or it is not open to you.`} next={err.next} />;
    }
    return (
      <div className="panel notice" role="alert">
        <p>{err instanceof ApiError ? err.message : 'The server did not answer.'}</p>
        {err instanceof ApiError && err.next && <p className="quiet">{err.next}</p>}
      </div>
    );
  }

  const o = query.data;
  const releases = o.commits.filter((c) => c.release !== null);
  const waitingForGit = releases.filter((c) => c.git_pending);
  // The release pinned: the one asked for, the one at the pinned commit, or
  // with neither asked for, the newest.
  // On another branch, its head unless a version was asked for.
  const pinned =
    search.commit || (search.branch && !search.release)
      ? query.isPlaceholderData
        ? null
        : o.pinned_release
      : (search.release ?? releases[0]?.release ?? null);
  // What rides on every link of the page, so a pinned commit or branch stays.
  const pin: Pin = {
    ...(search.branch ? { branch: search.branch } : {}),
    ...(search.commit ? { commit: search.commit } : search.release ? { release: search.release } : {}),
  };
  // The server names the pinned version (a release older than the tape
  // still pins); while another release's answer is on its way, the tape does.
  const pinnedCommit =
    (query.isPlaceholderData ? null : o.pinned_commit) ??
    search.commit ??
    o.commits.find((c) => c.release === pinned)?.id ??
    o.commits[0]?.id ??
    null;
  const view = search.view ?? 'overview';
  // The path's last part is the dataset's name; the rest says whose it is.
  const cut = o.name.lastIndexOf('/');
  const owner = cut >= 0 ? o.name.slice(0, cut + 1) : '';
  const leaf = o.name.slice(cut + 1);

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
        <div className="sky-clouds" aria-hidden="true" />
        <div className="dataset-head-inner">
          <div className="dataset-title">
            <h1 className="dataset-name">
              {owner && <span className="dataset-owner data">{owner}</span>}
              <span className="dataset-leaf">{leaf}</span>
            </h1>
            <p className="dataset-meta">
              <span className="dataset-fact">
                {o.kind === 'annotated' ? 'Annotated dataset' : o.kind === 'model' ? 'Model' : 'File dataset'}
                {o.restricted && <span className="chip restricted-badge">restricted</span>}
              </span>
              <span className="dataset-fact">
                {o.items.toLocaleString()} {o.items === 1 ? 'item' : 'items'}, {humanBytes(o.bytes)}
              </span>
              {o.owners.length > 0 && <span className="dataset-fact">owned by {o.owners.join(', ')}</span>}
              <span className="dataset-fact">
                <a href={gitWebUrl(o.git_url)} target="_blank" rel="noreferrer">
                  View in git
                </a>
                {releases.length > 0 && (
                  <span
                    className="quiet git-status"
                    title={
                      waitingForGit.length > 0
                        ? "Made, and on their way: the server writes each release to the dataset's git repository and retries until it lands."
                        : "Every release on this tape is in the dataset's git repository."
                    }
                  >
                    {waitingForGit.length === 0
                      ? 'up to date'
                      : `${waitingForGit.map((c) => c.release).join(', ')} not there yet`}
                  </span>
                )}
              </span>
            </p>
          </div>
          {o.branches.length > 1 && (
            <label className="branch-picker">
              <span className="quiet">branch</span>
              <select
                aria-label="Branch"
                value={o.branch}
                onChange={(e) =>
                  setSearch({
                    branch: e.target.value === 'main' ? undefined : e.target.value,
                    release: undefined,
                    commit: undefined,
                    a: undefined,
                    b: undefined,
                  })
                }
              >
                {o.branches.map((b) => (
                  <option key={b} value={b}>
                    {b}
                  </option>
                ))}
              </select>
            </label>
          )}
          <ReleaseTape
            branch={o.branch}
            commits={o.commits}
            pinned={pinned}
            pinnedCommit={search.commit ? pinnedCommit : null}
            onPick={(r) => setSearch({ release: r, commit: undefined })}
            onPickCommit={(id) => setSearch({ commit: id, release: undefined })}
          />
        </div>
      </header>

      <nav className="tabs" aria-label="Dataset views">
        <Link
          to="/d/$"
          params={{ _splat: name }}
          search={{ view: 'overview', ...pin }}
          className={view === 'overview' ? 'tab on' : 'tab'}
          aria-current={view === 'overview' ? 'page' : undefined}
        >
          Overview
        </Link>
        <Link
          to="/d/$"
          params={{ _splat: name }}
          search={{ view: 'browse', ...pin }}
          className={view === 'browse' ? 'tab on' : 'tab'}
          aria-current={view === 'browse' ? 'page' : undefined}
        >
          Browse
        </Link>
        <Link
          to="/d/$"
          params={{ _splat: name }}
          search={{ view: 'releases', ...pin }}
          className={view === 'releases' ? 'tab on' : 'tab'}
          aria-current={view === 'releases' ? 'page' : undefined}
        >
          Releases
        </Link>
        <Link
          to="/d/$"
          params={{ _splat: name }}
          search={{ view: 'files', ...pin }}
          className={view === 'files' ? 'tab on' : 'tab'}
          aria-current={view === 'files' ? 'page' : undefined}
        >
          Files
        </Link>
        <Link
          to="/d/$"
          params={{ _splat: name }}
          search={{ view: 'activity', ...pin }}
          className={view === 'activity' ? 'tab on' : 'tab'}
          aria-current={view === 'activity' ? 'page' : undefined}
        >
          Activity
        </Link>
        <button
          className="show-command"
          aria-pressed={showCommand}
          onClick={() => setShowCommand((v) => !v)}
          title="The cid command that reaches this view from a terminal"
        >
          Show command
        </button>
      </nav>
      {showCommand && (
        <CommandBar
          shown={commandFor(
            o,
            {
              view,
              pinned,
              commit: pinnedCommit,
              pin,
              split: search.split,
              cls: search.class,
              q: search.q,
              type: search.type,
              a: search.a,
              b: search.b,
              dir: search.dir,
            },
            location.hostname,
          )}
        />
      )}

      {view === 'overview' ? (
        <OverviewTab overview={o} pinned={pinned} commit={pinnedCommit} pin={pin} />
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
        <ActivityTab
          name={name}
          what={search.what}
          who={search.who}
          onFilter={(patch) => setSearch(patch)}
        />
      ) : (
        <FilesTab
          name={name}
          commit={pinnedCommit}
          pin={pin}
          openDir={search.dir}
          onOpenDir={(dir) => setSearch({ dir })}
        />
      )}
    </article>
  );
}


// The command for the view on screen, ready to paste (docs/dashboard.md:
// every action shows its command).
function CommandBar({ shown }: { shown: Shown | null }) {
  const [copied, setCopied] = useState(false);
  if (!shown) {
    return (
      <section className="command-bar" aria-label="Command">
        <p className="quiet">The activity log is the server's own record; no command shows it.</p>
      </section>
    );
  }
  return (
    <section className="command-bar" aria-label="Command">
      <div className="command-row">
        <code className="command data">{shown.command}</code>
        <button
          className="action"
          onClick={() =>
            void navigator.clipboard.writeText(shown.command).then(() => {
              setCopied(true);
              setTimeout(() => setCopied(false), 1600);
            })
          }
        >
          {copied ? 'Copied' : 'Copy'}
        </button>
      </div>
      {shown.note && <p className="quiet">{shown.note}</p>}
    </section>
  );
}
