import type { StateAnnotation, StateItem } from './api';

// Browse filters, as they live in the URL (docs/dashboard.md §4.3: every
// view is a link). Pure functions over the state the page already holds;
// the DuckDB browse engine replaces the evaluation, never this contract.

export type Filters = {
  mode?: 'table';
  q?: string;
  split?: string;
  /** Items carrying at least one annotation of this class. */
  cls?: string;
  /** A file extension with its dot, or 'file' for none. */
  type?: string;
};

/** The URL spelling of each filter, for patches back to the router. */
export type FilterPatch = {
  mode?: 'table' | undefined;
  q?: string | undefined;
  split?: string | undefined;
  class?: string | undefined;
  type?: string | undefined;
};

export function extOf(path: string): string {
  const base = path.slice(path.lastIndexOf('/') + 1);
  const dot = base.lastIndexOf('.');
  return dot > 0 ? base.slice(dot).toLowerCase() : 'file';
}

export function classesByItem(annotations: StateAnnotation[]): Map<string, Set<string>> {
  const map = new Map<string, Set<string>>();
  for (const a of annotations) {
    const set = map.get(a.item_id) ?? new Set<string>();
    set.add(a.class ?? '');
    map.set(a.item_id, set);
  }
  return map;
}

function matches(
  item: StateItem,
  f: Filters,
  classes: Map<string, Set<string>>,
  skip?: keyof Filters,
): boolean {
  if (skip !== 'q' && f.q && !item.path.toLowerCase().includes(f.q.toLowerCase())) return false;
  if (skip !== 'split' && f.split !== undefined && (item.split ?? '') !== f.split) return false;
  if (skip !== 'type' && f.type !== undefined && extOf(item.path) !== f.type) return false;
  if (skip !== 'cls' && f.cls !== undefined) {
    const has = item.item_id ? classes.get(item.item_id) : undefined;
    if (!has || !has.has(f.cls)) return false;
  }
  return true;
}

export function applyFilters(
  items: StateItem[],
  f: Filters,
  classes: Map<string, Set<string>>,
): StateItem[] {
  return items.filter((i) => matches(i, f, classes));
}

export type Facet = { value: string; count: number };

/**
 * The options for one filter, each counted against every *other* active
 * filter — the count beside an option is what you get if you pick it,
 * the faceting every good browser does. An active value with no matches
 * stays listed, so a shared link never shows a filter you cannot clear.
 */
export function facet(
  items: StateItem[],
  f: Filters,
  classes: Map<string, Set<string>>,
  key: 'split' | 'cls' | 'type',
): Facet[] {
  const counts = new Map<string, number>();
  for (const item of items) {
    if (!matches(item, f, classes, key)) continue;
    const values =
      key === 'split'
        ? [item.split ?? '']
        : key === 'type'
          ? [extOf(item.path)]
          : [...((item.item_id ? classes.get(item.item_id) : undefined) ?? [])];
    for (const v of values) counts.set(v, (counts.get(v) ?? 0) + 1);
  }
  const active = f[key];
  if (active !== undefined && !counts.has(active)) counts.set(active, 0);
  return [...counts.entries()]
    .map(([value, count]) => ({ value, count }))
    .sort((a, b) => b.count - a.count || a.value.localeCompare(b.value));
}

export function anyFilter(f: Filters): boolean {
  return Boolean(f.q) || f.split !== undefined || f.cls !== undefined || f.type !== undefined;
}
