import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { ApiError, getThumbs, runSql } from './api';
import { looksVisual } from './thumbs';
import { Thumb } from './Thumb';
import { extOf } from './browseFilter';

// The SQL console (docs/dashboard.md, 4.3): one SELECT over the version
// on screen, as two views, `items` and `annotations`, run on the server in
// a sandbox of its own. The query lives in the URL, so a query is a link
// and opens already run; results come as a table, and as a gallery when
// they name items (a `path` and a `hash`). Never on a restricted dataset.

const examples: [string, string][] = [
  ['items per split', 'SELECT split, count(*) AS items FROM items GROUP BY split ORDER BY items DESC'],
  ['boxes per class', "SELECT class, count(*) AS boxes FROM annotations WHERE kind = 'box' GROUP BY class ORDER BY boxes DESC"],
  ['busiest items', 'SELECT path, hash, annotations FROM items ORDER BY annotations DESC LIMIT 60'],
  ['who annotated', 'SELECT author, count(*) AS annotations FROM annotations GROUP BY author ORDER BY annotations DESC'],
];

export function SqlConsole({
  name,
  commit,
  sql,
  onSql,
  onOpenItem,
}: {
  name: string;
  commit: string | null;
  sql: string | undefined;
  onSql: (sql: string | undefined) => void;
  onOpenItem: (path: string) => void;
}) {
  const [typed, setTyped] = useState(sql ?? examples[0][1]);
  const [seen, setSeen] = useState(sql);
  if (sql !== seen) {
    setSeen(sql);
    if (sql !== undefined) setTyped(sql);
  }
  const [asGallery, setAsGallery] = useState(false);
  const result = useQuery({
    queryKey: ['sql', name, commit, sql],
    queryFn: () => runSql(name, commit!, sql!),
    enabled: commit !== null && sql !== undefined && sql.trim() !== '',
    retry: false,
    staleTime: Infinity,
  });
  const run = () => onSql(typed.trim() === '' ? undefined : typed.trim());
  const data = result.data;
  const names = data?.columns.map((c) => c.name) ?? [];
  const showsItems = names.includes('path') && names.includes('hash');

  return (
    <section className="sql-console" aria-label="SQL console">
      <p className="quiet">
        One <code className="data">SELECT</code> over this version: <code className="data">items</code> (path, hash,
        size, split, type, item_id, annotations, classes, attributes, identities, authors, policies) and{' '}
        <code className="data">annotations</code> (id, item_id, kind, class, geometry, attributes, author,
        policy_ver). Read-only, at most 1,000 rows, 10 seconds.
      </p>
      <textarea
        className="sql-input data"
        aria-label="SQL query"
        spellCheck={false}
        rows={4}
        value={typed}
        onChange={(e) => setTyped(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
            e.preventDefault();
            run();
          }
        }}
      />
      <div className="sql-actions">
        <button className="action" onClick={run} disabled={commit === null} title="Run (Ctrl+Enter)">
          Run
        </button>
        <span className="quiet">Try:</span>
        {examples.map(([label, q]) => (
          <button key={label} className="filter-clear" onClick={() => setTyped(q)}>
            {label}
          </button>
        ))}
      </div>

      {result.isFetching && <p className="quiet">Running…</p>}
      {result.isError && (
        <p className="problem" role="alert">
          {result.error instanceof ApiError ? result.error.message : 'The query could not be run just now.'}
          {result.error instanceof ApiError && result.error.next ? ` ${result.error.next}` : ''}
        </p>
      )}
      {data && !result.isFetching && (
        <>
          <p className="quiet data" role="status">
            {data.rows.length.toLocaleString()} {data.rows.length === 1 ? 'row' : 'rows'}
            {data.truncated ? ', the first only: narrow the query (a WHERE, a LIMIT) for the rest' : ''}
          </p>
          {showsItems && (
            <div className="format-picker format-picker--ui" role="radiogroup" aria-label="Show results as">
              {(['table', 'gallery'] as const).map((m) => (
                <button
                  key={m}
                  role="radio"
                  aria-checked={(m === 'gallery') === asGallery}
                  className={(m === 'gallery') === asGallery ? 'format on' : 'format'}
                  onClick={() => setAsGallery(m === 'gallery')}
                >
                  {m}
                </button>
              ))}
            </div>
          )}
          {showsItems && asGallery ? (
            <ResultGallery name={name} rows={data.rows} onOpenItem={onOpenItem} />
          ) : (
            <div className="table-scroll">
              <table className="browse-table sql-result">
                <thead>
                  <tr>
                    {data.columns.map((c) => (
                      <th key={c.name} title={c.type}>
                        {c.name}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {data.rows.map((row, i) => (
                    <tr key={i}>
                      {data.columns.map((c) => (
                        <td key={c.name} className="data">
                          {c.name === 'path' && typeof row.path === 'string' ? (
                            <button className="row-link data" onClick={() => onOpenItem(row.path as string)}>
                              {row.path}
                            </button>
                          ) : (
                            cell(row[c.name])
                          )}
                        </td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </section>
  );
}

// The rows that name items, as tiles: thumbnails where the worker built
// them, type tiles otherwise; a tile opens its item.
function ResultGallery({ name, rows, onOpenItem }: { name: string; rows: Record<string, unknown>[]; onOpenItem: (path: string) => void }) {
  const items = rows
    .filter((r) => typeof r.path === 'string' && typeof r.hash === 'string')
    .map((r) => ({ path: r.path as string, hash: r.hash as string }));
  const visual = [...new Set(items.filter((i) => looksVisual(i.path)).map((i) => i.hash))].slice(0, 400);
  const thumbs = useQuery({
    queryKey: ['thumbs', name, 'sql', visual.join(',')],
    queryFn: () => getThumbs(name, visual),
    enabled: visual.length > 0,
  });
  const by = new Map((thumbs.data?.thumbs ?? []).map((t) => [t.hash, t.url]));
  return (
    <ul className="sql-gallery">
      {items.map((it) => (
        <li key={it.path}>
          <button className="tile" onClick={() => onOpenItem(it.path)}>
            {by.has(it.hash) ? (
              <Thumb src={by.get(it.hash)} alt={it.path} label={extOf(it.path)} lazy />
            ) : (
              <span className="tile-type data">{extOf(it.path)}</span>
            )}
            <span className="tile-path data">{it.path}</span>
          </button>
        </li>
      ))}
    </ul>
  );
}

function cell(v: unknown): string {
  if (v === null || v === undefined) return '∅';
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}
