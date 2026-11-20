// "Show command" (docs/dashboard.md, principle: every action shows its
// command): the cid command that reaches the view on screen from a
// terminal. Pure, so the page and its tests compute the same thing.
import type { Overview, Pin, TapeCommit } from './api';

export type View = 'overview' | 'browse' | 'releases' | 'files' | 'activity';

export type ViewState = {
  view: View;
  /** The release pinned (by name), if any. */
  pinned: string | null;
  /** The commit the page shows. */
  commit: string | null;
  pin: Pin;
  split?: string;
  cls?: string;
  q?: string;
  type?: string;
  anns?: string;
  a?: string;
  b?: string;
  dir?: string;
};

export type Shown = { command: string; note?: string };

/** The pair a compare shows: as asked, else the two newest releases (else commits). */
export function comparePair(commits: TapeCommit[], a?: string, b?: string): { a: string | null; b: string | null } {
  const releases = commits.filter((c) => c.release !== null);
  const pool = releases.length >= 2 ? releases : commits;
  const label = (c: TapeCommit | undefined) => (c ? (c.release ?? c.id) : null);
  return { a: a ?? label(pool[1] ?? pool[0]), b: b ?? label(pool[0]) };
}

export function commandFor(o: Overview, s: ViewState, host: string): Shown | null {
  if (s.view === 'activity') return null;
  const folder = o.name.slice(o.name.lastIndexOf('/') + 1);
  const notes: string[] = [];
  const clone = ['cid clone', `cid@${host}:${o.name}`];
  if (s.pinned) clone.push(`--release ${s.pinned}`);
  if (s.view === 'browse') {
    if (s.split !== undefined) {
      if (s.split === '') notes.push('No clone flag keeps only the items without a split; this clones every split.');
      else clone.push(`--split ${s.split}`);
    }
    if (s.cls !== undefined) clone.push(`--class ${s.cls}`);
    if (s.q || s.type || s.anns) notes.push('The path search and the type and annotations filters have no clone flag; the folder holds every path.');
  }
  const steps = [clone.join(' ')];
  // A version that is no release: the clone, then a checkout of it.
  if (!s.pinned && s.pin.commit && s.commit) steps.push(`cd ${folder}`, `cid checkout ${s.commit}`);
  else if (!s.pinned && s.pin.branch) steps.push(`cd ${folder}`, `cid checkout ${s.pin.branch}`);
  const inFolder = () => {
    if (!steps.includes(`cd ${folder}`)) steps.push(`cd ${folder}`);
  };
  if (s.view === 'releases') {
    const pair = comparePair(o.commits, s.a, s.b);
    if (pair.a && pair.b && pair.a !== pair.b) {
      inFolder();
      steps.push(`cid diff ${pair.a} ${pair.b}`);
    }
  }
  if (s.view === 'files' && s.dir) {
    inFolder();
    steps.push(`ls ${s.dir}`);
  }
  return { command: steps.join(' && '), note: notes.length > 0 ? notes.join(' ') : undefined };
}
