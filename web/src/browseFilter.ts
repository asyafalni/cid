// Browse filters, as they live in the URL (docs/dashboard.md §4.3: every
// view is a link). The server evaluates them (the browse API: DuckDB over
// the version's Parquet index); this file is the URL side of the contract.

export type Filters = {
  /** Asked for; with none, the gallery, or the table when nothing on the first page has a preview. */
  mode?: 'table' | 'gallery' | 'list' | 'sql';
  q?: string;
  split?: string;
  /** Items carrying at least one annotation of this class. */
  cls?: string;
  /** A file extension with its dot, or 'file' for none. */
  type?: string;
  /** An annotation-count bucket: '0', '1', '2-4', '5-9' or '10+'. */
  anns?: string;
  /** An attribute value an annotation of the item carries: 'key=value'. */
  attr?: string;
  /** An identity an annotation of the item names (`attrs.identity`), exactly. */
  identity?: string;
  /** The SQL console's query (mode 'sql'), so a query is a link. */
  sql?: string;
  /** Items added, modified, moved or re-annotated since this release (by name). */
  since?: string;
};

/** The URL spelling of each filter, for patches back to the router. */
export type FilterPatch = {
  mode?: 'table' | 'gallery' | 'list' | 'sql' | undefined;
  q?: string | undefined;
  split?: string | undefined;
  class?: string | undefined;
  type?: string | undefined;
  anns?: string | undefined;
  attr?: string | undefined;
  identity?: string | undefined;
  sql?: string | undefined;
  since?: string | undefined;
};

export function extOf(path: string): string {
  const base = path.slice(path.lastIndexOf('/') + 1);
  const dot = base.lastIndexOf('.');
  return dot > 0 ? base.slice(dot).toLowerCase() : 'file';
}

export type Facet = { value: string; count: number };

export function anyFilter(f: Filters): boolean {
  return Boolean(f.q) || f.split !== undefined || f.cls !== undefined || f.type !== undefined || f.anns !== undefined || f.attr !== undefined || f.identity !== undefined || f.since !== undefined;
}
