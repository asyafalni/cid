// Client-side compare: the same walk cid diff does, over two states the
// page already has. Geometry and attrs compare canonically (sorted-key
// JSON), so the same box written differently is never a phantom change.

import type { StateAnnotation, StateItem } from './api';

export type ItemChange = {
  kind: 'added' | 'modified' | 'deleted';
  path: string;
  hash_a?: string;
  hash_b?: string;
  size_b?: number;
};

export function diffItems(a: StateItem[], b: StateItem[]): ItemChange[] {
  const out: ItemChange[] = [];
  let i = 0;
  let j = 0;
  // Both sorted by path, as the server returns them.
  while (i < a.length || j < b.length) {
    const order =
      i >= a.length ? 1 : j >= b.length ? -1 : a[i].path < b[j].path ? -1 : a[i].path > b[j].path ? 1 : 0;
    if (order < 0) {
      out.push({ kind: 'deleted', path: a[i].path, hash_a: a[i].hash });
      i += 1;
    } else if (order > 0) {
      out.push({ kind: 'added', path: b[j].path, hash_b: b[j].hash, size_b: b[j].size });
      j += 1;
    } else {
      if (a[i].hash !== b[j].hash) {
        out.push({
          kind: 'modified',
          path: a[i].path,
          hash_a: a[i].hash,
          hash_b: b[j].hash,
          size_b: b[j].size,
        });
      }
      i += 1;
      j += 1;
    }
  }
  return out;
}

export type AnnChange = {
  kind: 'added' | 'changed' | 'removed';
  annKind: string | null;
  cls: string | null;
  itemPath: string;
};

export function diffAnnotations(
  aItems: StateItem[],
  bItems: StateItem[],
  a: StateAnnotation[],
  b: StateAnnotation[],
): AnnChange[] {
  const paths = new Map<string, string>();
  for (const item of aItems) if (item.item_id) paths.set(item.item_id, item.path);
  for (const item of bItems) if (item.item_id) paths.set(item.item_id, item.path);
  const aById = new Map(a.map((x) => [x.id, x]));

  const out: AnnChange[] = [];
  for (const ann of b) {
    const old = aById.get(ann.id);
    if (!old) {
      out.push({
        kind: 'added',
        annKind: ann.kind,
        cls: ann.class,
        itemPath: paths.get(ann.item_id) ?? '?',
      });
      continue;
    }
    aById.delete(ann.id);
    const same =
      old.kind === ann.kind &&
      old.class === ann.class &&
      canonical(old.geometry) === canonical(ann.geometry) &&
      canonical(old.attrs) === canonical(ann.attrs);
    if (!same) {
      out.push({
        kind: 'changed',
        annKind: ann.kind,
        cls: ann.class,
        itemPath: paths.get(ann.item_id) ?? '?',
      });
    }
  }
  for (const old of aById.values()) {
    out.push({
      kind: 'removed',
      annKind: old.kind,
      cls: old.class,
      itemPath: paths.get(old.item_id) ?? '?',
    });
  }
  return out;
}

// Sorted-key JSON: enough canonicalization for equality of values that
// came through the same server (numbers already normalized by jsonb).
export function canonical(value: unknown): string {
  if (value === null || value === undefined) return 'null';
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (typeof value === 'object') {
    const keys = Object.keys(value as Record<string, unknown>).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical((value as Record<string, unknown>)[k])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}
