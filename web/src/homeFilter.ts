import type { DatasetSummary } from './api';

// The home page's filters (docs/dashboard.md §4.1): what the sidebar
// offers, how a dataset answers each, and the counts beside every value.
// The listing is already in the browser, so all of it is arithmetic here:
// a click filters with no request.

export type HomeSearch = {
  q?: string;
  group?: string;
  kind?: 'files' | 'annotated' | 'model';
  type?: string;
  released?: 'yes' | 'no';
  restricted?: 'yes' | 'no';
  health?: 'fail' | 'warn' | 'pass';
  sort?: 'name' | 'size' | 'items';
  layout?: 'list';
};

/** The filters a facet group sets, in the order the sidebar draws them. */
export const facetKeys = ['group', 'kind', 'type', 'released', 'restricted', 'health'] as const;
export type FacetKey = (typeof facetKeys)[number];

export const facetTitle: Record<FacetKey, string> = {
  group: 'Groups',
  kind: 'Kind',
  type: 'File type',
  released: 'Releases',
  restricted: 'Access',
  health: 'Health',
};

/** A value as its group shows it. */
export function valueLabel(key: FacetKey, value: string): string {
  switch (key) {
    case 'type':
      return value === 'file' ? 'no extension' : value;
    case 'released':
      return value === 'yes' ? 'has releases' : 'none yet';
    case 'restricted':
      return value === 'yes' ? 'restricted' : 'open';
    case 'health':
      return value === 'fail' ? 'failing' : value === 'warn' ? 'warnings' : 'passing';
    default:
      return value;
  }
}

/** The head's checks as one word, or nothing while they are not kept yet. */
function healthOf(d: DatasetSummary): 'fail' | 'warn' | 'pass' | null {
  if (!d.health) return null;
  return d.health.fail > 0 ? 'fail' : d.health.warn > 0 ? 'warn' : 'pass';
}

/** Every group a dataset is in: each folder of its path, outermost first. */
function groupsOf(name: string): string[] {
  const parts = name.split('/').slice(0, -1);
  return parts.map((_, i) => parts.slice(0, i + 1).join('/'));
}

function passes(d: DatasetSummary, key: FacetKey | 'q', s: HomeSearch): boolean {
  switch (key) {
    case 'q': {
      if (!s.q) return true;
      const q = s.q.toLowerCase();
      return (
        d.name.toLowerCase().includes(q) ||
        d.classes.some((c) => c.toLowerCase().includes(q)) ||
        d.types.some((t) => t.ext.toLowerCase().includes(q)) ||
        d.owners.some((o) => o.toLowerCase().includes(q))
      );
    }
    case 'group':
      return !s.group || d.name.startsWith(`${s.group}/`);
    case 'kind':
      return !s.kind || d.kind === s.kind;
    case 'type':
      return !s.type || d.types.some((t) => t.ext === s.type);
    case 'released':
      return !s.released || (s.released === 'yes') === Boolean(d.latest_release);
    case 'restricted':
      return !s.restricted || (s.restricted === 'yes') === d.restricted;
    case 'health':
      return !s.health || healthOf(d) === s.health;
  }
}

/** The datasets the search and every filter let through, but `except`'s own. */
export function matching(datasets: DatasetSummary[], s: HomeSearch, except?: FacetKey): DatasetSummary[] {
  return datasets.filter((d) => passes(d, 'q', s) && facetKeys.every((k) => k === except || passes(d, k, s)));
}

export type FacetValue = { value: string; count: number; depth: number };

/** A group's values, each counted against the other filters (so a value
 * never promises more than a click on it gives), over every value the
 * server's datasets have: one that would give nothing stays, dimmed. */
export function facetValues(key: FacetKey, datasets: DatasetSummary[], s: HomeSearch): FacetValue[] {
  const valuesOf = (d: DatasetSummary): string[] => {
    switch (key) {
      case 'group':
        return groupsOf(d.name);
      case 'kind':
        return [d.kind];
      case 'type':
        return d.types.map((t) => t.ext);
      case 'released':
        return [d.latest_release ? 'yes' : 'no'];
      case 'restricted':
        return [d.restricted ? 'yes' : 'no'];
      case 'health': {
        const h = healthOf(d);
        return h ? [h] : [];
      }
    }
  };
  const counts = new Map<string, number>();
  // How common each value is over everything: the order, which a filter
  // must not shuffle under the pointer.
  const overall = new Map<string, number>();
  for (const d of datasets)
    for (const v of valuesOf(d)) {
      if (!counts.has(v)) counts.set(v, 0);
      overall.set(v, (overall.get(v) ?? 0) + 1);
    }
  for (const d of matching(datasets, s, key)) for (const v of valuesOf(d)) counts.set(v, (counts.get(v) ?? 0) + 1);
  const all = [...counts].map(([value, count]) => ({ value, count, depth: key === 'group' ? value.split('/').length - 1 : 0 }));
  const fixed: Partial<Record<FacetKey, string[]>> = {
    kind: ['annotated', 'files', 'model'],
    released: ['yes', 'no'],
    restricted: ['yes', 'no'],
    health: ['fail', 'warn', 'pass'],
  };
  const order = fixed[key];
  if (order) return all.sort((a, b) => order.indexOf(a.value) - order.indexOf(b.value));
  // Groups read as a tree, in path order; file types most common first.
  if (key === 'group') return all.sort((a, b) => a.value.localeCompare(b.value));
  return all.sort((a, b) => overall.get(b.value)! - overall.get(a.value)! || a.value.localeCompare(b.value));
}

/** A group is drawn when it has a choice to offer: two values, or one in
 * use. The path tree, when some folder does not hold every dataset. */
export function worthShowing(key: FacetKey, values: FacetValue[], s: HomeSearch, datasets: DatasetSummary[]): boolean {
  if (s[key] !== undefined) return true;
  if (key === 'group') return values.some((v) => datasets.some((d) => !d.name.startsWith(`${v.value}/`)));
  return values.length > 1;
}
