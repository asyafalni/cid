import { useInfiniteQuery, useQuery } from '@tanstack/react-query';
import { getCompare, getRowDiff, getThumbs, type CompareSide, type Overview, type StateAnnotation, type TapeCommit } from '../api';
import { AnnotationOverlay } from '../overlays';
import { humanBytes } from '../format';

// Releases & history: the timeline, and compare between any two
// versions. A and B live in the URL, so a comparison is a link.
export function ReleasesTab({
  name,
  overview,
  a,
  b,
  onPick,
}: {
  name: string;
  overview: Overview;
  a: string | undefined;
  b: string | undefined;
  onPick: (patch: { a?: string; b?: string }) => void;
}) {
  const commits = overview.commits; // newest first
  const releases = commits.filter((c) => c.release !== null);

  // Default comparison: the two newest releases, else newest two commits.
  const pool = releases.length >= 2 ? releases : commits;
  const bSel = b ?? labelOf(pool[0]);
  const aSel = a ?? labelOf(pool[1] ?? pool[0]);

  return (
    <div className="releases">
      <section aria-label="Compare two versions" className="panel card compare-picker">
        <h2>Compare</h2>
        <div className="compare-row">
          <VersionSelect
            label="from"
            commits={commits}
            value={aSel}
            onChange={(v) => onPick({ a: v })}
          />
          <span aria-hidden="true" className="quiet">
            to
          </span>
          <VersionSelect
            label="to"
            commits={commits}
            value={bSel}
            onChange={(v) => onPick({ b: v })}
          />
        </div>
        {aSel && bSel && aSel !== bSel && (
          <Comparison name={name} overview={overview} aLabel={aSel} bLabel={bSel} />
        )}
        {aSel === bSel && <p className="quiet">Pick two different versions to compare.</p>}
      </section>

      <section aria-label="History">
        <h2 className="history-title">History</h2>
        <ol className="timeline">
          {commits.map((c) => (
            <li key={c.id} className={c.release ? 'moment moment--release' : 'moment'}>
              <div className="moment-line">
                {c.release && <span className="release-tag">{c.release}</span>}
                <span className="moment-message">{c.message}</span>
                {c.release && c.git_pending && (
                  <span
                    className="quiet moment-git"
                    title="The release is made; the server writes it to the dataset's git repository and retries until it lands."
                  >
                    not in git yet
                  </span>
                )}
              </div>
              <p className="quiet moment-meta">
                <span className="data">{new Date(c.at_ms).toISOString().slice(0, 10)}</span>
                {' — '}
                {c.author} · <span className="data">{c.id.slice(0, 13)}</span>
              </p>
            </li>
          ))}
        </ol>
      </section>
    </div>
  );
}

function VersionSelect({
  label,
  commits,
  value,
  onChange,
}: {
  label: string;
  commits: TapeCommit[];
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <label className="compare-select">
      <span className="quiet">{label}</span>
      <select value={value} onChange={(e) => onChange(e.target.value)}>
        {commits.map((c) => (
          <option key={c.id} value={labelOf(c)}>
            {c.release ?? `${c.id.slice(0, 13)} — ${c.message.slice(0, 32)}`}
          </option>
        ))}
      </select>
    </label>
  );
}

function Comparison({
  name,
  overview,
  aLabel,
  bLabel,
}: {
  name: string;
  overview: Overview;
  aLabel: string;
  bLabel: string;
}) {
  const aCommit = resolve(overview.commits, aLabel);
  const bCommit = resolve(overview.commits, bLabel);
  // Compared on the server (DuckDB over both versions' indexes): the
  // summary and the visual diff come with the first page; further item
  // changes a page at a time. Nothing here holds either version.
  const pages = useInfiniteQuery({
    queryKey: ['compare', name, aCommit, bCommit],
    queryFn: ({ pageParam }) => getCompare(name, aCommit!, bCommit!, pageParam),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last) => last.next ?? undefined,
    enabled: aCommit !== null && bCommit !== null,
  });
  const first = pages.data?.pages[0];
  const changes = pages.data?.pages.flatMap((p) => p.changes) ?? [];
  const visual = first?.visual ?? [];

  // Before/after thumbs: changed files, and the items behind the visual diff.
  const pairHashes = [
    ...new Set([
      ...changes.filter((c) => c.change === 'modified').flatMap((c) => [c.hash_a!, c.hash_b!]),
      ...visual.flatMap((v) => [v.before?.hash, v.after?.hash].filter((h): h is string => !!h)),
    ]),
  ].slice(0, 400);
  const thumbs = useQuery({
    queryKey: ['thumbs', name, 'cmp', aCommit, bCommit, pairHashes.length],
    queryFn: () => getThumbs(name, pairHashes),
    enabled: pairHashes.length > 0,
  });
  const thumbBy = new Map((thumbs.data?.thumbs ?? []).map((t) => [t.hash, t.url]));

  if (pages.isPending) return <p className="quiet">Comparing…</p>;
  if (pages.isError || !first)
    return (
      <p className="quiet" role="alert">
        Could not compare these versions; pick again or reload.
      </p>
    );

  const s = first.summary;
  const anyItems = s.added + s.modified + s.deleted > 0;
  const anyAnns = s.ann_added + s.ann_changed + s.ann_removed > 0;

  return (
    <div className="comparison">
      <p className="engraved data">
        {s.added.toLocaleString()} added · {s.modified.toLocaleString()} modified · {s.deleted.toLocaleString()} deleted
        {overview.kind === 'annotated' && (
          <>
            {' '}
            — annotations: {s.ann_added.toLocaleString()} added · {s.ann_changed.toLocaleString()} changed ·{' '}
            {s.ann_removed.toLocaleString()} removed
          </>
        )}
      </p>

      {!anyItems && !anyAnns && <p className="quiet">These two versions hold exactly the same data.</p>}

      {changes.length > 0 && (
        <ul className="change-list">
          {changes.map((c) => (
            <li key={c.path} className="change">
              <span className={`change-verb change-verb--${c.change}`}>{c.change}</span>
              <span className="data change-path">{c.path}</span>
              {c.size_b !== null && <span className="quiet data">{humanBytes(c.size_b)}</span>}
              {c.change === 'modified' && thumbBy.has(c.hash_a!) && thumbBy.has(c.hash_b!) && (
                <span className="before-after">
                  <img src={thumbBy.get(c.hash_a!)} alt={`${c.path} before`} />
                  <span aria-hidden="true">→</span>
                  <img src={thumbBy.get(c.hash_b!)} alt={`${c.path} after`} />
                </span>
              )}
              {c.change === 'modified' && isTable(c.path) && (
                <RowChanges name={name} path={c.path} a={c.hash_a!} b={c.hash_b!} />
              )}
            </li>
          ))}
        </ul>
      )}
      {pages.hasNextPage && (
        <button
          className="filter-clear more-items"
          disabled={pages.isFetchingNextPage}
          onClick={() => void pages.fetchNextPage()}
        >
          {pages.isFetchingNextPage
            ? 'Loading more…'
            : `Show more changes (${changes.length.toLocaleString()} of ${(s.added + s.modified + s.deleted).toLocaleString()} shown)`}
        </button>
      )}

      {visual.length > 0 && (
        <section className="visual-diff" aria-label="Changed items, before and after">
          <p className="quiet visual-diff-key">
            <span className="key-before">dashed</span> {aLabel} ·{' '}
            <span className="key-after">solid</span> {bLabel}
          </p>
          <ul className="visual-diff-list">
            {visual.map((v) => (
              <li key={v.path} className="visual-diff-item">
                <p className="data change-path">{v.path}</p>
                <div className="before-after-pair">
                  <DiffSide
                    label={aLabel}
                    item={v.before ?? undefined}
                    annotations={v.shapes_before}
                    variant="before"
                    thumb={v.before ? thumbBy.get(v.before.hash) : undefined}
                  />
                  <DiffSide
                    label={bLabel}
                    item={v.after ?? undefined}
                    annotations={v.shapes_after}
                    variant="after"
                    thumb={v.after ? thumbBy.get(v.after.hash) : undefined}
                  />
                </div>
              </li>
            ))}
          </ul>
        </section>
      )}

      {first.ann_changes.length > 0 && (
        <ul className="change-list">
          {first.ann_changes.map((c, i) => (
            <li key={i} className="change">
              <span className={`change-verb change-verb--${c.change === 'removed' ? 'deleted' : c.change === 'changed' ? 'modified' : 'added'}`}>
                {c.change}
              </span>
              <span>
                {c.kind ?? '?'} {c.class ?? ''}
              </span>
              <span className="quiet data">on {c.item_path ?? '?'}</span>
            </li>
          ))}
        </ul>
      )}
      {s.ann_added + s.ann_changed + s.ann_removed > first.ann_changes.length && (
        <p className="quiet">
          The first {first.ann_changes.length.toLocaleString()} annotation changes are listed. For all of them, run{' '}
          <code className="data">cid diff {aLabel} {bLabel}</code>.
        </p>
      )}
    </div>
  );
}

// One side of a before/after pair. A side whose version lacks the item
// says so in words; a side with no preview yet says that instead —
// never a blank box (one bad file never breaks a view).
function DiffSide({
  label,
  item,
  annotations,
  variant,
  thumb,
}: {
  label: string;
  item: CompareSide | undefined;
  annotations: StateAnnotation[];
  variant: 'before' | 'after';
  thumb: string | undefined;
}) {
  return (
    <figure className="diff-side">
      {!item ? (
        <div className="diff-side-none blueprint">
          <span className="quiet">Not in {label}</span>
        </div>
      ) : thumb && item.width && item.height ? (
        <span className="overlay-fit" style={{ aspectRatio: `${item.width} / ${item.height}` }}>
          <img src={thumb} alt={`${item.path} at ${label}`} />
          <AnnotationOverlay
            width={item.width}
            height={item.height}
            annotations={annotations}
            hidden={new Set()}
            opacity={1}
            variant={variant}
          />
        </span>
      ) : (
        <div className="diff-side-none blueprint">
          <span className="quiet">No preview yet</span>
        </div>
      )}
      <figcaption className="data">
        {label} · {annotations.length} shape{annotations.length === 1 ? '' : 's'}
      </figcaption>
    </figure>
  );
}

const tableExt = /\.(csv|parquet|jsonl|ndjson)$/i;
function isTable(path: string): boolean {
  return tableExt.test(path);
}

// A modified table file, by rows (CLAUDE.md, Formats): what was added and
// removed, with the rows themselves one click away. Computed once on the
// server; when it cannot be, the line says why, and the file line above
// already says the file changed.
function RowChanges({ name, path, a, b }: { name: string; path: string; a: string; b: string }) {
  const answer = useQuery({
    queryKey: ['rowdiff', name, a, b],
    queryFn: () => getRowDiff(name, path, a, b),
    staleTime: Infinity,
  });
  if (answer.isPending) return <p className="row-changes quiet">Comparing rows…</p>;
  if (answer.isError)
    return <p className="row-changes quiet">The rows could not be compared just now; reload to try again.</p>;
  const r = answer.data;
  if (r.status !== 'done' || !r.diff)
    return <p className="row-changes quiet">Rows not compared: {r.reason ?? r.status}.</p>;
  const d = r.diff;
  if (d.columns_changed) {
    const gone = d.columns_a.filter((col) => !d.columns_b.includes(col));
    const came = d.columns_b.filter((col) => !d.columns_a.includes(col));
    return (
      <div className="row-changes">
        <p className="data">
          Columns changed, so rows are not compared ({d.rows_a.toLocaleString()} → {d.rows_b.toLocaleString()} rows)
        </p>
        <ul className="row-columns data">
          {gone.map((col) => (
            <li key={`-${col}`} className="change-verb--deleted">
              removed {col}
            </li>
          ))}
          {came.map((col) => (
            <li key={`+${col}`} className="change-verb--added">
              added {col}
            </li>
          ))}
          {gone.length === 0 && came.length === 0 && <li className="quiet">same columns, new order</li>}
        </ul>
      </div>
    );
  }
  const added = d.added ?? 0;
  const removed = d.removed ?? 0;
  if (added === 0 && removed === 0)
    return (
      <p className="row-changes quiet">The same {d.rows_b.toLocaleString()} rows, in another order or format.</p>
    );
  return (
    <div className="row-changes">
      <p className="data">
        <span className="change-verb--added">{added.toLocaleString()} rows added</span>,{' '}
        <span className="change-verb--deleted">{removed.toLocaleString()} removed</span>{' '}
        <span className="quiet">
          ({d.rows_a.toLocaleString()} → {d.rows_b.toLocaleString()} rows; an edited row counts as one removed and one added)
        </span>
      </p>
      {r.withheld ? (
        <p className="quiet">The rows themselves are withheld: this dataset is restricted.</p>
      ) : (
        <details>
          <summary>Show the changed rows</summary>
          <SampleTable caption="Removed" total={removed} rows={d.removed_sample ?? []} />
          <SampleTable caption="Added" total={added} rows={d.added_sample ?? []} />
        </details>
      )}
    </div>
  );
}

function SampleTable({ caption, total, rows }: { caption: string; total: number; rows: Record<string, unknown>[] }) {
  if (rows.length === 0) return null;
  const cols = Object.keys(rows[0]);
  return (
    <div className="table-scroll">
      <table className="browse-table">
        <caption className="quiet">
          {caption}: {rows.length < total ? `first ${rows.length} of ${total.toLocaleString()}` : `${total.toLocaleString()}`}
        </caption>
        <thead>
          <tr>
            {cols.map((c) => (
              <th key={c}>{c}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr key={i}>
              {cols.map((c) => (
                <td key={c} className="data">
                  {row[c] === null || row[c] === undefined ? '—' : String(row[c])}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function labelOf(c: TapeCommit): string {
  return c.release ?? c.id;
}

function resolve(commits: TapeCommit[], label: string): string | null {
  const byRelease = commits.find((c) => c.release === label);
  if (byRelease) return byRelease.id;
  const byId = commits.find((c) => c.id === label);
  return byId ? byId.id : null;
}
