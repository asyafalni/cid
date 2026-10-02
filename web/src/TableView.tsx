import { useQuery } from '@tanstack/react-query';
import { getTable, type TableStats } from './api';

// A table item, shown as a table (docs/dashboard.md: media-native, never
// "viewer not available"): its columns with type, range, distinct count
// and nulls, then its first rows. Built once by the preview worker; when
// it is not there yet, or cannot be, the drawer says so in words.
export function TableView({
  name,
  hash,
  revealed,
}: {
  name: string;
  hash: string;
  /** A reveal's full statistics, which replace the withheld shape. */
  revealed?: TableStats | null;
}) {
  const answer = useQuery({ queryKey: ['table', name, hash], queryFn: () => getTable(name, hash) });

  if (answer.isPending) return <p className="quiet">Reading the table…</p>;
  if (answer.isError) return <p className="quiet">The table's statistics could not be read; the file is still one click away.</p>;
  const a = answer.data;
  if (a.status !== 'done' || !a.stats) {
    return (
      <p className="quiet table-pending">
        {a.status === 'skipped'
          ? `No table view: ${a.reason ?? 'the worker could not read it'}.`
          : 'The table view is being built; it appears here when the preview worker reaches it.'}
      </p>
    );
  }
  const stats = revealed ?? a.stats;
  const withheld = !revealed && a.withheld === true;
  const cols = stats.columns;

  return (
    <section className="table-view" aria-label="Table">
      <p className="engraved data">
        {stats.rows.toLocaleString()} {stats.rows === 1 ? 'row' : 'rows'} · {cols.length}{' '}
        {cols.length === 1 ? 'column' : 'columns'}
      </p>
      <div className="table-scroll">
        <table className="browse-table table-columns">
          <caption className="quiet">Columns</caption>
          <thead>
            <tr>
              <th>column</th>
              <th>type</th>
              {!withheld && <th>range</th>}
              {!withheld && <th>distinct</th>}
              <th>nulls</th>
            </tr>
          </thead>
          <tbody>
            {cols.map((c) => (
              <tr key={c.name}>
                <td className="data">{c.name}</td>
                <td className="data quiet">{c.type}</td>
                {!withheld && (
                  <td className="data">{c.min === c.max ? (c.min ?? '—') : `${c.min ?? '—'} … ${c.max ?? '—'}`}</td>
                )}
                {!withheld && <td className="data">{c.distinct?.toLocaleString() ?? '—'}</td>}
                <td className="data">{c.null_percent === undefined ? '—' : `${Number(c.null_percent).toFixed(0)}%`}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {withheld ? (
        <p className="quiet">Values and rows are withheld: this dataset is restricted. Reveal the item to see them; the reveal is logged.</p>
      ) : (
        stats.sample.length > 0 && (
          <div className="table-scroll">
            <table className="browse-table table-sample">
              <caption className="quiet">
                First {stats.sample.length} of {stats.rows.toLocaleString()} rows
              </caption>
              <thead>
                <tr>
                  {cols.map((c) => (
                    <th key={c.name}>{c.name}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {stats.sample.map((row, i) => (
                  <tr key={i}>
                    {cols.map((c) => (
                      <td key={c.name} className="data">
                        {cell(row[c.name])}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )
      )}
    </section>
  );
}

function cell(v: unknown): string {
  if (v === null || v === undefined) return '∅';
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}
