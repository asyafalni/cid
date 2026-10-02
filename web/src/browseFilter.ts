// Browse filters, as they live in the URL (docs/dashboard.md §4.3: every
// view is a link). The server evaluates them (the browse API: DuckDB over
// the version's Parquet index); this file is the URL side of the contract.

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

export type Facet = { value: string; count: number };

export function anyFilter(f: Filters): boolean {
  return Boolean(f.q) || f.split !== undefined || f.cls !== undefined || f.type !== undefined;
}
