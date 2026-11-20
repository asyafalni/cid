import type { TapeCommit } from './api';

// The release tape: the one bold element of the dashboard. An
// altimeter-style strip of the dataset's history — a brass tick per
// commit, an engraved tag per release, the aether needle on the pinned
// position. It earns its decoration by being navigation: every tag is a
// button that pins the page to that release, and every tick pins it to
// that commit (by pointer; from the keyboard, the history lists every
// commit with a link, so the tape is not a hundred tab stops).
export function ReleaseTape({
  commits,
  pinned,
  pinnedCommit,
  onPick,
  onPickCommit,
}: {
  commits: TapeCommit[]; // newest first
  pinned: string | null;
  /** A commit pinned by `?commit=` (null when a release is). */
  pinnedCommit: string | null;
  onPick: (release: string) => void;
  onPickCommit: (id: string) => void;
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
            className={[c.release ? 'tick tick--release' : 'tick', pinnedCommit === c.id && !c.release ? 'tick--pinned' : '']
              .join(' ')
              .trim()}
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
              <button
                className="tick-mark"
                tabIndex={-1}
                aria-label={`Commit ${c.id.slice(0, 13)}: ${c.message}`}
                aria-pressed={pinnedCommit === c.id}
                onClick={() => onPickCommit(c.id)}
              />
            )}
          </li>
        ))}
      </ol>
      <p className="tape-legend quiet">
        {commitCount}, {releases === 1 ? '1 release' : `${releases} releases`}. Pick a release, or
        a commit's tick, to pin the page to it.
      </p>
    </nav>
  );
}
