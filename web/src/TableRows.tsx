import { useEffect, useRef, useState } from 'react';
import { useInfiniteQuery } from '@tanstack/react-query';
import { getRows, type ColumnHist, type RowFilter, type TableStats } from './api';

// A table item's rows (docs/roadmap.md, U6): every row, 50 at a time,
// each column's distribution above it, and a click on a bar or a value
// narrowing the rows to it. Each distribution is counted against the other
// columns' filters, as Browse's facets are, so a column always shows what
// is there to pick. The filters live in the URL: a narrowed table is a
// link. One hue for every bar (--data); the numbers are in each bar's
// name and title, never in its colour.

export function TableRows({
  name,
  hash,
  path,
  where,
  onWhere,
  row,
  onRow,
  fallback,
}: {
  name: string;
  hash: string;
  path: string;
  where: string | undefined;
  onWhere: (where: string | undefined) => void;
  /** The linked row, from 1 (U7): the rows open at it, highlighted. */
  row?: string;
  onRow?: (row: string | undefined) => void;
  /** The first rows from the statistics, shown where rows cannot be had. */
  fallback: TableStats | null;
}) {
  const filters = parseWhere(where);
  // The file's row index (from 0) of the linked row.
  const at = row !== undefined && /^\d+$/.test(row) && Number(row) > 0 ? Number(row) - 1 : undefined;
  const pages = useInfiniteQuery({
    queryKey: ['rows', name, hash, path, JSON.stringify(filters), at ?? null],
    // The first page is the one that holds the linked row; then on from it.
    queryFn: ({ pageParam }) =>
      pageParam === -1 ? getRows(name, hash, path, filters, 0, at) : getRows(name, hash, path, filters, pageParam),
    initialPageParam: at === undefined ? 0 : -1,
    getNextPageParam: (last) => {
      const p = last.page;
      if (!p) return undefined;
      const next = p.offset + p.rows.length;
      return next < p.matched && p.rows.length > 0 ? next : undefined;
    },
  });
  const set = (next: RowFilter[]) => onWhere(next.length > 0 ? JSON.stringify(next) : undefined);
  // Scrolled to once its page arrives.
  const linked = useRef<HTMLTableRowElement>(null);
  const arrived = pages.isSuccess;
  useEffect(() => {
    if (arrived) linked.current?.scrollIntoView({ block: 'center' });
  }, [arrived, at]);
  const toggle = (f: RowFilter) => {
    const others = filters.filter((x) => x.column !== f.column);
    const same = filters.find((x) => x.column === f.column);
    set(same && sameFilter(same, f) ? others : [...others, f]);
  };

  if (pages.isPending) return <p className="quiet">Reading the rows…</p>;
  const first = pages.data?.pages[0];
  if (pages.isError || !first || first.status !== 'done' || !first.page) {
    return (
      <>
        <p className="quiet">
          {first?.reason
            ? `Rows are not browsable: ${first.reason}.`
            : 'The rows could not be read just now; reload to try again.'}
        </p>
        {fallback && <FirstRows stats={fallback} />}
      </>
    );
  }
  const head = first.page;
  const rows = pages.data.pages.flatMap((p) => p.page?.rows ?? []);
  const linkedShown = at !== undefined && rows.some((r) => Number(r.__row) === at);
  const cols = head.columns;
  return (
    <section className="table-rows" aria-label="Rows">
      <div className="row-filter-bar">
        <RowSearch
          value={filters.find((f) => f.column === '*')?.contains}
          onSearch={(words) => set([...filters.filter((f) => f.column !== '*'), ...(words ? [{ column: '*', contains: words }] : [])])}
        />
        <p className="quiet data" aria-live="polite">
          {filters.length > 0
            ? `${head.matched.toLocaleString()} of ${head.total.toLocaleString()} rows`
            : `${head.total.toLocaleString()} rows`}
        </p>
        {filters.map((f) => (
          <button key={f.column} className="class-chip" onClick={() => toggle(f)} aria-label={`Remove the filter ${describe(f, cols)}`}>
            {describe(f, cols)} <span aria-hidden="true">×</span>
          </button>
        ))}
        {filters.length > 1 && (
          <button className="filter-clear" onClick={() => set([])}>
            Clear row filters
          </button>
        )}
      </div>
      {head.offset > 0 && (
        <p className="quiet data">
          From row {(head.offset + 1).toLocaleString()} of the {filters.length > 0 ? 'filtered ' : ''}rows
          {onRow && row !== undefined && (
            <>
              {' '}
              ·{' '}
              <button className="filter-clear" onClick={() => onRow(undefined)}>
                Back to the first row
              </button>
            </>
          )}
        </p>
      )}
      {at !== undefined && !linkedShown && (
        <p className="quiet">Row {(at + 1).toLocaleString()} is not among these rows: a filter leaves it out, or the file has fewer.</p>
      )}
      <div className="table-scroll">
        <table className="browse-table table-sample table-rows-grid">
          <thead>
            <tr>
              <th className="num quiet">#</th>
              {cols.map((c) => (
                <th key={c.name}>{c.name}</th>
              ))}
            </tr>
            <tr className="hist-row">
              <td />
              {cols.map((c) => (
                <td key={c.name} className="hist-cell">
                  {c.hist && (
                    <Histogram column={c.name} hist={c.hist} active={filters.find((f) => f.column === c.name)} onPick={toggle} />
                  )}
                </td>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const index = Number(r.__row);
              const here = index === at;
              return (
                <tr key={String(r.__row)} ref={here ? linked : undefined} className={here ? 'row--linked' : undefined} aria-current={here ? 'true' : undefined}>
                  <td className="data num quiet">
                    {onRow ? (
                      // Its number links to it: the URL then opens here.
                      <button className="row-link data" aria-label={`Link to row ${index + 1}`} onClick={() => onRow(String(index + 1))}>
                        {index + 1}
                      </button>
                    ) : (
                      index + 1
                    )}
                  </td>
                  {cols.map((c) => (
                    <td key={c.name} className="data">
                      {cell(r[c.name])}
                    </td>
                  ))}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      {head.matched === 0 && <p className="quiet">No row matches. Remove a filter above to see more.</p>}
      {pages.hasNextPage && (
        <button className="filter-clear" disabled={pages.isFetchingNextPage} onClick={() => void pages.fetchNextPage()}>
          {pages.isFetchingNextPage ? 'Reading…' : `Show more rows (${rows.length.toLocaleString()} of ${head.matched.toLocaleString()} shown)`}
        </button>
      )}
    </section>
  );
}

// Search inside the table (U8): the words in any text column, ignoring
// case; committed on Enter or when the box is left, so a half-typed word
// never reads the table.
function RowSearch({ value, onSearch }: { value: string | undefined; onSearch: (words: string | undefined) => void }) {
  const [typed, setTyped] = useState(value ?? '');
  const [seen, setSeen] = useState(value);
  if (value !== seen) {
    setSeen(value);
    setTyped(value ?? '');
  }
  const commit = () => {
    const v = typed.trim();
    if (v !== (value ?? '')) onSearch(v === '' ? undefined : v);
  };
  return (
    <input
      type="search"
      className="filter-q row-search"
      placeholder="Search the rows"
      aria-label="Search the rows' text"
      value={typed}
      onChange={(e) => setTyped(e.target.value)}
      onKeyDown={(e) => {
        if (e.key === 'Enter') commit();
      }}
      onBlur={commit}
    />
  );
}

function Histogram({
  column,
  hist,
  active,
  onPick,
}: {
  column: string;
  hist: ColumnHist;
  active: RowFilter | undefined;
  onPick: (f: RowFilter) => void;
}) {
  if (hist.kind === 'bins') {
    const max = Math.max(1, ...hist.counts);
    const width = hist.lo !== null && hist.hi !== null ? (hist.hi - hist.lo) / hist.counts.length : 0;
    return (
      <div className="hist" role="group" aria-label={`${column}: distribution`}>
        <div className="hist-bins">
          {hist.counts.map((n, i) => {
            const lo = (hist.lo ?? 0) + i * width;
            const label = `${column} ${num(lo)} to ${num(lo + width)}: ${n.toLocaleString()} ${n === 1 ? 'row' : 'rows'}`;
            const on = active?.bin === i;
            return (
              <button
                key={i}
                className={on ? 'hist-bin on' : 'hist-bin'}
                aria-label={label}
                aria-pressed={on}
                title={label}
                disabled={n === 0 && !on}
                onClick={() => onPick({ column, bin: i })}
              >
                <span style={{ height: `${n === 0 ? 0 : Math.max(8, (n / max) * 100)}%` }} />
              </button>
            );
          })}
        </div>
        <div className="hist-range data quiet">
          <span>{hist.lo === null ? '—' : num(hist.lo)}</span>
          <span>{hist.hi === null ? '—' : num(hist.hi)}</span>
        </div>
        {(hist.nulls > 0 || active?.null) && <Empty column={column} n={hist.nulls} active={active} onPick={onPick} />}
      </div>
    );
  }
  const max = Math.max(1, ...hist.top.map((t) => t.n));
  const other = hist.nonnull - hist.top.reduce((sum, t) => sum + t.n, 0);
  return (
    <div className="hist" role="group" aria-label={`${column}: most common values`}>
      {hist.top.slice(0, 5).map((t) => {
        const on = active?.value === t.v;
        const label = `${column} = ${t.v}: ${t.n.toLocaleString()} ${t.n === 1 ? 'row' : 'rows'}`;
        return (
          <button
            key={t.v}
            className={on ? 'hist-value on' : 'hist-value'}
            aria-label={label}
            aria-pressed={on}
            title={label}
            onClick={() => onPick({ column, value: t.v })}
          >
            <span className="hist-value-bar" style={{ width: `${(t.n / max) * 100}%` }} />
            <span className="hist-value-text data">{t.v}</span>
          </button>
        );
      })}
      {(hist.top.length > 5 || other > 0) && (
        <p className="quiet hist-more data">
          +{(hist.top.slice(5).reduce((sum, t) => sum + t.n, 0) + other).toLocaleString()} other
        </p>
      )}
      {(hist.nulls > 0 || active?.null) && <Empty column={column} n={hist.nulls} active={active} onPick={onPick} />}
    </div>
  );
}

function Empty({ column, n, active, onPick }: { column: string; n: number; active: RowFilter | undefined; onPick: (f: RowFilter) => void }) {
  const on = active?.null === true;
  return (
    <button
      className={on ? 'hist-empty on data' : 'hist-empty data'}
      aria-pressed={on}
      aria-label={`${column} is empty: ${n.toLocaleString()} ${n === 1 ? 'row' : 'rows'}`}
      onClick={() => onPick({ column, null: true })}
    >
      ∅ {n.toLocaleString()}
    </button>
  );
}

function FirstRows({ stats }: { stats: TableStats }) {
  if (stats.sample.length === 0) return null;
  return (
    <div className="table-scroll">
      <table className="browse-table table-sample">
        <caption className="quiet">
          First {stats.sample.length} of {stats.rows.toLocaleString()} rows
        </caption>
        <thead>
          <tr>
            {stats.columns.map((c) => (
              <th key={c.name}>{c.name}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {stats.sample.map((row, i) => (
            <tr key={i}>
              {stats.columns.map((c) => (
                <td key={c.name} className="data">
                  {cell(row[c.name])}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** The filters in the URL, or none when they do not read as filters. */
function parseWhere(where: string | undefined): RowFilter[] {
  if (!where) return [];
  try {
    const v: unknown = JSON.parse(where);
    if (!Array.isArray(v)) return [];
    return v.filter(
      (f): f is RowFilter => typeof f === 'object' && f !== null && typeof (f as RowFilter).column === 'string',
    );
  } catch {
    return [];
  }
}

function sameFilter(a: RowFilter, b: RowFilter): boolean {
  return a.bin === b.bin && a.value === b.value && (a.null ?? false) === (b.null ?? false) && a.contains === b.contains;
}

function describe(f: RowFilter, cols: { name: string; hist: ColumnHist | null }[]): string {
  if (f.column === '*') return `contains “${f.contains ?? ''}”`;
  if (f.null) return `${f.column} is empty`;
  if (f.value !== undefined) return `${f.column} = ${f.value}`;
  const h = cols.find((c) => c.name === f.column)?.hist;
  if (f.bin !== undefined && h?.kind === 'bins' && h.lo !== null && h.hi !== null) {
    const w = (h.hi - h.lo) / h.counts.length;
    return `${f.column} ${num(h.lo + f.bin * w)} to ${num(h.lo + (f.bin + 1) * w)}`;
  }
  return f.column;
}

function num(v: number): string {
  return Number.isInteger(v) ? v.toLocaleString() : v.toLocaleString(undefined, { maximumSignificantDigits: 4 });
}

function cell(v: unknown): string {
  if (v === null || v === undefined) return '∅';
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}
