import { useQuery } from '@tanstack/react-query';
import { getRowDiff, getState, getThumbs, type Overview, type StateAnnotation, type StateItem, type TapeCommit } from '../api';
import { AnnotationOverlay } from '../overlays';
import { diffAnnotations, diffItems, type AnnChange } from '../diff';
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
  const stateA = useQuery({
    queryKey: ['state', name, aCommit],
    queryFn: () => getState(name, aCommit!),
    enabled: aCommit !== null,
  });
  const stateB = useQuery({
    queryKey: ['state', name, bCommit],
    queryFn: () => getState(name, bCommit!),
    enabled: bCommit !== null,
  });

  const changes =
    stateA.data && stateB.data ? diffItems(stateA.data.items, stateB.data.items) : [];
  const annChanges =
    stateA.data && stateB.data && overview.kind === 'annotated'
      ? diffAnnotations(
          stateA.data.items,
          stateB.data.items,
          stateA.data.annotations ?? [],
          stateB.data.annotations ?? [],
        )
      : [];

  // The visual diff: every item an annotation changed on, with the
  // shapes as each version had them. Items come from both sides, so an
  // item re-encoded between the versions shows each side's own pixels.
  const visual = visualDiff(stateA.data?.items ?? [], stateB.data?.items ?? [], annChanges).slice(0, 60);

  // Before/after thumbs: changed files, and the items behind the visual diff.
  const pairHashes = [
    ...new Set([
      ...changes.filter((c) => c.kind === 'modified').flatMap((c) => [c.hash_a!, c.hash_b!]),
      ...visual.flatMap((v) => [v.before?.hash, v.after?.hash].filter((h): h is string => !!h)),
    ]),
  ].slice(0, 200);
  const thumbs = useQuery({
    queryKey: ['thumbs', name, 'cmp', pairHashes.join(',').slice(0, 64)],
    queryFn: () => getThumbs(name, pairHashes),
    enabled: pairHashes.length > 0,
  });
  const thumbBy = new Map((thumbs.data?.thumbs ?? []).map((t) => [t.hash, t.url]));

  if (stateA.isPending || stateB.isPending) return <p className="quiet">Comparing…</p>;
  if (stateA.isError || stateB.isError)
    return (
      <p className="quiet" role="alert">
        Could not read one of the versions; pick again or reload.
      </p>
    );

  const added = changes.filter((c) => c.kind === 'added').length;
  const modified = changes.filter((c) => c.kind === 'modified').length;
  const deleted = changes.filter((c) => c.kind === 'deleted').length;

  return (
    <div className="comparison">
      <p className="engraved data">
        {added} added · {modified} modified · {deleted} deleted
        {overview.kind === 'annotated' && (
          <>
            {' '}
            — annotations: {annChanges.filter((c) => c.kind === 'added').length} added ·{' '}
            {annChanges.filter((c) => c.kind === 'changed').length} changed ·{' '}
            {annChanges.filter((c) => c.kind === 'removed').length} removed
          </>
        )}
      </p>

      {changes.length === 0 && annChanges.length === 0 && (
        <p className="quiet">These two versions hold exactly the same data.</p>
      )}

      {changes.length > 0 && (
        <ul className="change-list">
          {changes.slice(0, 200).map((c) => (
            <li key={c.path} className="change">
              <span className={`change-verb change-verb--${c.kind}`}>{c.kind}</span>
              <span className="data change-path">{c.path}</span>
              {c.size_b !== undefined && (
                <span className="quiet data">{humanBytes(c.size_b)}</span>
              )}
              {c.kind === 'modified' && thumbBy.has(c.hash_a!) && thumbBy.has(c.hash_b!) && (
                <span className="before-after">
                  <img src={thumbBy.get(c.hash_a!)} alt={`${c.path} before`} />
                  <span aria-hidden="true">→</span>
                  <img src={thumbBy.get(c.hash_b!)} alt={`${c.path} after`} />
                </span>
              )}
              {c.kind === 'modified' && isTable(c.path) && (
                <RowChanges name={name} path={c.path} a={c.hash_a!} b={c.hash_b!} />
              )}
            </li>
          ))}
        </ul>
      )}

      {visual.length > 0 && (
        <section className="visual-diff" aria-label="Changed items, before and after">
          <p className="quiet visual-diff-key">
            <span className="key-before">dashed</span> {aLabel} ·{' '}
            <span className="key-after">solid</span> {bLabel}
          </p>
          <ul className="visual-diff-list">
            {visual.map((v) => (
              <li key={v.itemId} className="visual-diff-item">
                <p className="data change-path">{(v.after ?? v.before)!.path}</p>
                <div className="before-after-pair">
                  <DiffSide
                    label={aLabel}
                    item={v.before}
                    annotations={v.shapesBefore}
                    variant="before"
                    thumb={v.before ? thumbBy.get(v.before.hash) : undefined}
                  />
                  <DiffSide
                    label={bLabel}
                    item={v.after}
                    annotations={v.shapesAfter}
                    variant="after"
                    thumb={v.after ? thumbBy.get(v.after.hash) : undefined}
                  />
                </div>
              </li>
            ))}
          </ul>
        </section>
      )}

      {annChanges.length > 0 && (
        <ul className="change-list">
          {annChanges.slice(0, 200).map((c, i) => (
            <li key={i} className="change">
              <span className={`change-verb change-verb--${c.kind === 'removed' ? 'deleted' : c.kind === 'changed' ? 'modified' : 'added'}`}>
                {c.kind}
              </span>
              <span>
                {c.annKind ?? '?'} {c.cls ?? ''}
              </span>
              <span className="quiet data">on {c.itemPath}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

type VisualRow = {
  itemId: string;
  before?: StateItem;
  after?: StateItem;
  shapesBefore: StateAnnotation[];
  shapesAfter: StateAnnotation[];
};

function visualDiff(aItems: StateItem[], bItems: StateItem[], changes: AnnChange[]): VisualRow[] {
  const aBy = new Map(aItems.filter((i) => i.item_id).map((i) => [i.item_id!, i]));
  const bBy = new Map(bItems.filter((i) => i.item_id).map((i) => [i.item_id!, i]));
  const rows = new Map<string, VisualRow>();
  for (const c of changes) {
    const row = rows.get(c.itemId) ?? {
      itemId: c.itemId,
      before: aBy.get(c.itemId),
      after: bBy.get(c.itemId),
      shapesBefore: [],
      shapesAfter: [],
    };
    if (c.before) row.shapesBefore.push(c.before);
    if (c.after) row.shapesAfter.push(c.after);
    rows.set(c.itemId, row);
  }
  return [...rows.values()].sort((x, y) =>
    ((x.after ?? x.before)?.path ?? '').localeCompare((y.after ?? y.before)?.path ?? ''),
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
  item: StateItem | undefined;
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
