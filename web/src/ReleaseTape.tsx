import type { TapeCommit } from './api';

// The release tape: the one bold element of the dashboard. An
// altimeter-style strip of the dataset's history — a brass tick per
// commit, an engraved tag per release, the aether needle on the pinned
// position. It earns its decoration by being navigation: every tag is a
// button that pins the page to that release.
export function ReleaseTape({
  commits,
  pinned,
  onPick,
}: {
  commits: TapeCommit[]; // newest first
  pinned: string | null;
  onPick: (release: string) => void;
}) {
  if (commits.length === 0) {
    return (
      <div className="tape tape--empty blueprint" role="note">
        <p className="quiet">No commits yet — the tape starts at the first push.</p>
      </div>
    );
  }

  // Oldest on the left, like a tape that has been running.
  const run = [...commits].reverse();
  const releases = commits.filter((c) => c.release !== null).length;
  const commitCount = commits.length === 1 ? '1 commit' : `${commits.length} commits`;

  // Commits but no release: nothing to pin yet, so no tape, just the facts.
  if (releases === 0) {
    return (
      <nav className="tape tape--unreleased" aria-label="Releases and commits">
        <p className="tape-legend quiet">{commitCount}, no releases yet. The page shows the newest commit.</p>
      </nav>
    );
  }

  return (
    <nav className="tape" aria-label="Releases and commits">
      <ol className="tape-run">
        {run.map((c) => (
          <li
            key={c.id}
            className={c.release ? 'tick tick--release' : 'tick'}
            title={`${c.message} — ${c.author}`}
          >
            {c.release ? (
              <button
                className={pinned === c.release ? 'tag tag--pinned' : 'tag'}
                aria-pressed={pinned === c.release}
                onClick={() => onPick(c.release!)}
              >
                {c.release}
              </button>
            ) : (
              <span className="tick-mark" aria-hidden="true" />
            )}
          </li>
        ))}
      </ol>
      <p className="tape-legend quiet">
        {commitCount}, {releases === 1 ? '1 release' : `${releases} releases`}. Pick a release to pin
        the page to it.
      </p>
    </nav>
  );
}
