// "Show command" (docs/dashboard.md, principle: every action shows its
// command): the cid command that reaches the view on screen from a
// terminal. Pure, so the page and its tests compute the same thing.
import type { Overview, Pin, TapeCommit } from './api';

export type View = 'overview' | 'browse' | 'releases' | 'health' | 'files' | 'activity';

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
  attr?: string;
  identity?: string;
  since?: string;
  size?: string;
  author?: string;
  policy?: string;
  numRange?: string;
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

/** The view state a page's URL and its overview stand for, as the dataset
 * page derives it (the palette's actions read it this way). */
export function viewStateOf(o: Overview, search: Record<string, unknown>): ViewState {
  const str = (k: string) => (typeof search[k] === 'string' ? (search[k] as string) : undefined);
  const release = str('release');
  const commit = str('commit');
  const branch = str('branch');
  const pinned = commit || (branch && !release) ? o.pinned_release : (release ?? o.commits.find((c) => c.release)?.release ?? null);
  const views = ['overview', 'browse', 'releases', 'health', 'files', 'activity'] as const;
  const view = views.find((v) => v === str('view')) ?? 'overview';
  return {
    view,
    pinned,
    commit: o.pinned_commit,
    pin: { ...(branch ? { branch } : {}), ...(commit ? { commit } : release ? { release } : {}) },
    split: str('split'),
    cls: str('class'),
    q: str('q'),
    type: str('type'),
    anns: search.anns === undefined ? undefined : String(search.anns),
    attr: str('attr'),
    identity: search.identity === undefined ? undefined : String(search.identity),
    since: str('since'),
    size: str('size'),
    author: str('author'),
    policy: str('policy'),
    numRange: search.num_from !== undefined || search.num_to !== undefined ? String(search.num ?? '') : undefined,
    a: str('a'),
    b: str('b'),
    dir: str('dir'),
  };
}

export function commandFor(o: Overview, s: ViewState, host: string): Shown | null {
  if (s.view === 'activity' || s.view === 'health') return null;
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
    if (s.q || s.type || s.anns || s.attr || s.identity || s.size || s.author || s.policy || s.numRange !== undefined)
      notes.push('The path search and the type, annotations, attribute, identity, size, author, policy and number filters have no clone flag; the folder holds every path.');
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
  // Changed since a release: the same changes, listed by `cid diff`.
  if (s.view === 'browse' && s.since) {
    const at = s.pinned ?? s.commit;
    if (at && at !== s.since) {
      inFolder();
      steps.push(`cid diff ${s.since} ${at}`);
    }
  }
  if (s.view === 'files' && s.dir) {
    inFolder();
    steps.push(`ls ${s.dir}`);
  }
  return { command: steps.join(' && '), note: notes.length > 0 ? notes.join(' ') : undefined };
}
