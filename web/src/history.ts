import type { ItemHistory } from './api';

// An item's history as one timeline, newest first (docs/dashboard.md §4.3:
// "every change, with before/after"). Pure, so the pairing is easy to read.

export type HistoryEntry = {
  at: string;
  who: string;
  /** "file added", "box person moved", … */
  what: string;
  /** "x 20 → 45 · w 60 → 70", a hash change, or nothing. */
  change: string | null;
  /** Where it landed: a release, a commit, or not committed yet. */
  where: string;
};

export function timeline(h: ItemHistory): HistoryEntry[] {
  const out: (HistoryEntry & { order: string })[] = [];

  // Item changes: oldest first to know each one's predecessor.
  const items = [...h.changes].reverse();
  items.forEach((c, i) => {
    const prev = items[i - 1];
    out.push({
      order: c.at,
      at: c.at,
      who: c.author,
      what: c.op === 'add' ? 'file added' : c.op === 'delete' ? 'file deleted' : 'file changed',
      change:
        c.op === 'update' && prev?.hash && c.hash
          ? `${prev.hash.slice(0, 8)} → ${c.hash.slice(0, 8)}`
          : null,
      where: whereOf(c.release, c.commit, c.message, c.branch),
    });
  });

  // Annotation changes, paired with the same annotation's previous version.
  const anns = [...h.annotations].reverse();
  const lastSeen = new Map<string, (typeof anns)[number]>();
  for (const a of anns) {
    const prev = lastSeen.get(a.annotation_id);
    const label = `${a.kind ?? 'annotation'}${a.class ? ` ${a.class}` : ''}`;
    let what = `${label} added`;
    let change: string | null = null;
    if (a.op === 'delete') {
      what = `${label} removed`;
    } else if (a.op === 'update') {
      const moved = prev ? geometryDiff(prev.geometry, a.geometry) : null;
      const reclassed = prev && prev.class !== a.class ? `class ${prev.class ?? '—'} → ${a.class ?? '—'}` : null;
      what = moved ? `${label} moved` : reclassed ? `${label} relabelled` : `${label} changed`;
      change = [reclassed, moved].filter(Boolean).join(' · ') || null;
    }
    out.push({
      order: a.at,
      at: a.at,
      who: a.author,
      what,
      change,
      where: whereOf(a.release, a.commit, null, a.branch),
    });
    lastSeen.set(a.annotation_id, a);
  }

  return out.sort((x, y) => (x.order < y.order ? 1 : x.order > y.order ? -1 : 0)).map(({ order: _order, ...e }) => e);
}

function whereOf(release: string | null, commit: string | null, message: string | null, branch: string): string {
  const on = branch === 'main' ? '' : ` on ${branch}`;
  if (release) return `in ${release}${on}`;
  if (commit) return message ? `in “${message}”${on}` : `in commit ${commit.slice(0, 8)}${on}`;
  return `not committed yet${on}`;
}

/** Numeric fields that differ, in the geometry's own words. */
export function geometryDiff(before: unknown, after: unknown): string | null {
  if (!isObject(before) || !isObject(after)) return null;
  const parts: string[] = [];
  for (const key of Object.keys(after)) {
    const a = before[key];
    const b = after[key];
    if (typeof a === 'number' && typeof b === 'number' && a !== b) parts.push(`${key} ${a} → ${b}`);
  }
  return parts.length > 0 ? parts.join(' · ') : null;
}

function isObject(v: unknown): v is Record<string, unknown> {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}
