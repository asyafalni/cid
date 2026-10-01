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
        {commits.length === 1 ? '1 commit' : `${commits.length} commits`} ·{' '}
        {countReleases(commits)} — each tag pins the page to that release
      </p>
    </nav>
  );
}

function countReleases(commits: TapeCommit[]): string {
  const n = commits.filter((c) => c.release !== null).length;
  return n === 1 ? '1 release' : `${n} releases`;
}
