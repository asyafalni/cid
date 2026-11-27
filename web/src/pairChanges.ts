// What changed in one of Compare's pairs, worked out from the two versions'
// shapes: each annotation matched by its id, and the pair said in words.
// Kept apart from the components that show it (VisualDiff.tsx), and tested
// on its own.
import type { CompareSide, StateAnnotation } from './api';

export type VisualPair = {
  path: string;
  before: CompareSide | null;
  after: CompareSide | null;
  shapes_before: StateAnnotation[];
  shapes_after: StateAnnotation[];
};

/** One annotation's change between the two versions, matched by its id. */
export type ShapeChange = {
  id: string;
  kind: string | null;
  what: 'added' | 'removed' | 'changed';
  classBefore: string | null;
  classAfter: string | null;
  /** How far its box's corner moved, in pixels, when it is a box that moved. */
  moved: { dx: number; dy: number } | null;
  /** Its shape changed in a way that is not a plain move (a resize, new points). */
  reshaped: boolean;
  attrsChanged: boolean;
  authorAfter: string | null;
};

/** Key order never counts: the same JSON written two ways is the same. */
function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (v && typeof v === 'object')
    return `{${Object.keys(v as object)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonical((v as Record<string, unknown>)[k])}`)
      .join(',')}}`;
  return JSON.stringify(v ?? null);
}

type Box = { x: number; y: number; w: number; h: number };
function boxOf(g: unknown): Box | null {
  if (!g || typeof g !== 'object') return null;
  const b = g as Record<string, unknown>;
  return ['x', 'y', 'w', 'h'].every((k) => typeof b[k] === 'number') ? (b as unknown as Box) : null;
}

export function shapeChanges(pair: VisualPair): ShapeChange[] {
  const before = new Map(pair.shapes_before.map((s) => [s.id, s]));
  const after = new Map(pair.shapes_after.map((s) => [s.id, s]));
  const out: ShapeChange[] = [];
  for (const [id, a] of after) {
    const b = before.get(id);
    if (!b) {
      out.push({ id, kind: a.kind, what: 'added', classBefore: null, classAfter: a.class, moved: null, reshaped: false, attrsChanged: false, authorAfter: a.author });
      continue;
    }
    const geometrySame = canonical(a.geometry) === canonical(b.geometry);
    const ba = boxOf(b.geometry);
    const aa = boxOf(a.geometry);
    const plainMove = !geometrySame && ba && aa && ba.w === aa.w && ba.h === aa.h;
    const change: ShapeChange = {
      id,
      kind: a.kind,
      what: 'changed',
      classBefore: b.class,
      classAfter: a.class,
      moved: plainMove ? { dx: Math.round(aa.x - ba.x), dy: Math.round(aa.y - ba.y) } : null,
      reshaped: !geometrySame && !plainMove,
      attrsChanged: canonical(a.attrs) !== canonical(b.attrs),
      authorAfter: a.author,
    };
    if (change.classBefore !== change.classAfter || change.moved || change.reshaped || change.attrsChanged || b.kind !== a.kind) out.push(change);
  }
  for (const [id, b] of before)
    if (!after.has(id))
      out.push({ id, kind: b.kind, what: 'removed', classBefore: b.class, classAfter: null, moved: null, reshaped: false, attrsChanged: false, authorAfter: null });
  return out;
}

export const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/** "car → truck · 2 moved · 1 removed": the pair's changes, in words. */
export function pairSummary(pair: VisualPair, changes: ShapeChange[]): string[] {
  const parts: string[] = [];
  if (!pair.before) parts.push('new item');
  else if (!pair.after) parts.push('item removed');
  else if (pair.before.hash !== pair.after.hash) parts.push('file changed');
  const renames = new Map<string, number>();
  for (const c of changes)
    if (c.what === 'changed' && c.classBefore !== c.classAfter) {
      const key = `${c.classBefore ?? 'no class'} → ${c.classAfter ?? 'no class'}`;
      renames.set(key, (renames.get(key) ?? 0) + 1);
    }
  for (const [rename, n] of renames) parts.push(n > 1 ? `${rename} ×${n}` : rename);
  const moved = changes.filter((c) => c.moved).length;
  const reshaped = changes.filter((c) => c.reshaped).length;
  const attrs = changes.filter((c) => c.what === 'changed' && c.attrsChanged).length;
  const added = changes.filter((c) => c.what === 'added').length;
  const removed = changes.filter((c) => c.what === 'removed').length;
  if (moved) parts.push(`${moved} moved`);
  if (reshaped) parts.push(`${reshaped} reshaped`);
  if (attrs) parts.push(plural(attrs, 'attribute change'));
  if (added) parts.push(`${added} added`);
  if (removed) parts.push(`${removed} removed`);
  return parts;
}
