import { useInfiniteQuery, useQuery } from '@tanstack/react-query';
import { Link } from '@tanstack/react-router';
import { comparePair } from '../command';
import { RowsSkeleton } from '../Skeleton';
import { getCompare, getDownloads, getOverview, getRowDiff, getThumbs, type Overview, type TapeCommit } from '../api';
import { Thumb } from '../Thumb';
import { extOf } from '../browseFilter';
import { gitTagUrl, humanBytes } from '../format';
import { DumbbellTable, type PairRow } from '../Bars';
import { classColor } from '../shapes';
import { VisualDiff } from '../VisualDiff';

/** The most pairs a compare's first page pictures (browse.visual_items). */
const visual_items = 60;

// Releases & history: the timeline, and compare between any two
// versions. A and B live in the URL, so a comparison is a link.
export function ReleasesTab({
  name,
  overview,
  a,
  b,
  onPick,
  dir,
  onDir,
  openPair,
  onOpenPair,
}: {
  name: string;
  overview: Overview;
  a: string | undefined;
  b: string | undefined;
  onPick: (patch: { a?: string; b?: string }) => void;
  /** The folder the change list is narrowed to, from the URL. */
  dir?: string;
  onDir?: (dir: string | undefined) => void;
  /** The changed item opened large, from the URL. */
  openPair?: string;
  onOpenPair?: (path: string | undefined) => void;
}) {
  const commits = overview.commits; // newest first
  // On a branch, main's versions are on offer too (B7): a branch is
  // reviewed against where it would merge.
  const onBranch = overview.branch !== 'main';
  const main = useQuery({
    queryKey: ['overview', name, null, null, 'main'],
    queryFn: () => getOverview(name, undefined, undefined, 'main'),
    enabled: onBranch,
  });
  const mainCommits = onBranch ? (main.data?.commits ?? []).filter((c) => !commits.some((x) => x.id === c.id)) : [];
  const groups = onBranch
    ? [
        { label: overview.branch, commits },
        { label: 'main', commits: mainCommits },
      ]
    : [{ label: null, commits }];
  const every = [...commits, ...mainCommits];

  // Default comparison: the two newest releases, else newest two commits.
  const pair = comparePair(commits, a, b);
  const aSel = pair.a ?? '';
  const bSel = pair.b ?? '';
  const mainHead = main.data?.commits[0];

  return (
    <div className="releases">
      <section aria-label="Compare two versions" className="panel card compare-picker">
        <div className="compare-row">
          <h2>Compare</h2>
          <VersionSelect
            label="Compare from"
            groups={groups}
            value={aSel}
            onChange={(v) => onPick({ a: v })}
          />
          <span className="compare-with">with</span>
          <VersionSelect
            label="Compare to"
            groups={groups}
            value={bSel}
            onChange={(v) => onPick({ b: v })}
          />
          {onBranch && mainHead && commits[0] && (
            // Both ends in the URL, so the link and Show command say it too.
            <button className="filter-clear" onClick={() => onPick({ a: labelOf(mainHead), b: labelOf(commits[0]) })}>
              Compare with main
            </button>
          )}
        </div>
        {aSel && bSel && aSel !== bSel && (
          <Comparison name={name} overview={overview} commits={every} aLabel={aSel} bLabel={bSel} dir={dir} onDir={onDir} openPair={openPair} onOpenPair={onOpenPair} />
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
                {c.release && purgedIn(overview, c.release) > 0 && (
                  <span
                    className="chip moment-purged"
                    title="Some of this release's items had their bytes erased by an administrator (cid admin purge). The release's history and hashes are kept; those items can no longer be downloaded."
                  >
                    intact except {purgedIn(overview, c.release).toLocaleString()} purged{' '}
                    {purgedIn(overview, c.release) === 1 ? 'item' : 'items'}
                  </span>
                )}
                {c.release && !c.git_pending && gitTagUrl(overview.git_url, c.release) && (
                  <a
                    className="moment-git"
                    href={gitTagUrl(overview.git_url, c.release)!}
                    target="_blank"
                    rel="noreferrer"
                    aria-label={`${c.release} in the git repository`}
                  >
                    in git
                  </a>
                )}
              </div>
              {/* The release's own words, as its maker wrote them. */}
              {c.release && c.notes && <p className="release-notes">{c.notes}</p>}
              <p className="quiet moment-meta">
                <span className="data">{new Date(c.at_ms).toISOString().slice(0, 10)}</span>
                {' — '}
                {c.author} · <span className="data">{c.id.slice(0, 13)}</span> ·{' '}
                <Link
                  to="/d/$"
                  params={{ _splat: name }}
                  search={{
                    ...(overview.branch !== 'main' ? { branch: overview.branch } : {}),
                    ...(c.release ? { release: c.release } : { commit: c.id }),
                  }}
                  aria-label={`View this version: ${c.release ?? c.id.slice(0, 13)}`}
                >
                  view
                </Link>
              </p>
              {c.release && <ReleaseCounts name={name} kind={overview.kind} release={c} />}
            </li>
          ))}
        </ol>
      </section>
    </div>
  );
}

// What a release holds and what it changed, counted when it was made: the
// same sentence its git repository's release notes carry, and a way into
// the comparison itself.
function ReleaseCounts({ name, kind, release: c }: { name: string; kind: Overview['kind']; release: TapeCommit }) {
  if (c.items === null && c.changes_from === null) return null;
  const moved = c.split ?? 0;
  const files =
    (c.added ?? 0) + (c.modified ?? 0) + (c.deleted ?? 0) + moved === 0
      ? 'no files changed'
      : `${n(c.added)} ${c.added === 1 ? 'file' : 'files'} added, ${n(c.modified)} modified, ${n(c.deleted)} deleted` +
        (moved > 0 ? `, ${moved.toLocaleString()} moved to another split` : '');
  const annotations =
    kind === 'annotated'
      ? `; ${n(c.ann_added)} ${c.ann_added === 1 ? 'annotation' : 'annotations'} added, ${n(c.ann_changed)} changed, ${n(c.ann_removed)} removed`
      : '';
  return (
    <p className="quiet moment-meta moment-counts">
      {c.items !== null && (
        <span className="data">
          {c.items.toLocaleString()} {c.items === 1 ? 'item' : 'items'}
        </span>
      )}
      {c.items !== null && ' · '}
      {c.changes_from === null ? (
        'the first release'
      ) : (
        <Link
          to="/d/$"
          params={{ _splat: name }}
          search={{ view: 'releases', a: c.changes_from, b: c.release ?? undefined }}
        >
          since {c.changes_from}: {files}
          {annotations}
        </Link>
      )}
    </p>
  );
}

function n(count: number | null): string {
  return (count ?? 0).toLocaleString();
}

function purgedIn(overview: Overview, release: string): number {
  return overview.purged.find((p) => p.release === release)?.items ?? 0;
}

// A count in a compare's summary: a number is data; a zero steps back.
function Count({ n }: { n: number }) {
  return <span className={n === 0 ? 'count-n count-n--zero' : 'count-n'}>{n.toLocaleString()}</span>;
}

function VersionSelect({
  label,
  groups,
  value,
  onChange,
}: {
  label: string;
  /** The versions on offer, grouped by branch when there is more than one. */
  groups: { label: string | null; commits: TapeCommit[] }[];
  value: string;
  onChange: (v: string) => void;
}) {
  const options = (commits: TapeCommit[]) =>
    commits.map((c) => (
      <option key={c.id} value={labelOf(c)}>
        {c.release ?? `${c.id.slice(0, 13)} — ${c.message.slice(0, 32)}`}
      </option>
    ));
  return (
    <label className="compare-select">
      <select aria-label={label} value={value} onChange={(e) => onChange(e.target.value)}>
        {groups.map((g) =>
          g.label === null ? (
            options(g.commits)
          ) : g.commits.length > 0 ? (
            <optgroup key={g.label} label={g.label}>
              {options(g.commits)}
            </optgroup>
          ) : null,
        )}
      </select>
    </label>
  );
}

// How many changes the list can hold: under the open folder, or in all.
function changesUnder(page: { under?: { added: number; modified: number; deleted: number; split: number } }, s: { added: number; modified: number; deleted: number; split?: number }): number {
  const u = page.under;
  return u ? u.added + u.modified + u.deleted + u.split : s.added + s.modified + s.deleted + (s.split ?? 0);
}

// The folders with changes in them, one level at a time: each with its
// changes by kind, in words and signs, never colour alone; a click opens
// it, and the path above leads back up.
function ChangedFolders({
  name,
  dir,
  folders,
  onDir,
}: {
  name: string;
  dir: string | undefined;
  folders: { name: string; added: number; modified: number; deleted: number; split: number }[];
  onDir: (dir: string | undefined) => void;
}) {
  const crumbs = dir ? dir.split('/') : [];
  return (
    <section className="changed-folders" aria-label="Changed folders">
      <nav className="crumbs" aria-label="Folder path">
        <button className="crumb" onClick={() => onDir(undefined)}>
          {name.split('/').pop()}
        </button>
        {crumbs.map((part, i) => (
          <span key={i}>
            <span aria-hidden="true" className="quiet">
              /
            </span>
            <button className="crumb" onClick={() => onDir(crumbs.slice(0, i + 1).join('/'))}>
              {part}
            </button>
          </span>
        ))}
      </nav>
      {folders.length > 0 && (
        <ul className="changed-folder-list">
          {folders.map((f) => {
            const parts = [
              f.added > 0 && `${f.added.toLocaleString()} added`,
              f.modified > 0 && `${f.modified.toLocaleString()} modified`,
              f.deleted > 0 && `${f.deleted.toLocaleString()} deleted`,
              f.split > 0 && `${f.split.toLocaleString()} moved to another split`,
            ].filter(Boolean) as string[];
            return (
              <li key={f.name}>
                <button className="changed-folder" onClick={() => onDir(dir ? `${dir}/${f.name}` : f.name)} aria-label={`${f.name}/: ${parts.join(', ')}`}>
                  <span className="data changed-folder-name">{f.name}/</span>
                  <span className="data changed-folder-counts" aria-hidden="true">
                    {f.added > 0 && <span className="change-verb--added">+{f.added.toLocaleString()}</span>}
                    {f.modified + f.split > 0 && <span className="change-verb--modified">~{(f.modified + f.split).toLocaleString()}</span>}
                    {f.deleted > 0 && <span className="change-verb--deleted">−{f.deleted.toLocaleString()}</span>}
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

function Comparison({
  name,
  overview,
  commits,
  aLabel,
  bLabel,
  dir,
  onDir,
  openPair,
  onOpenPair,
}: {
  name: string;
  overview: Overview;
  /** Every version on offer: the branch's, and main's when on a branch. */
  commits: TapeCommit[];
  openPair?: string;
  onOpenPair?: (path: string | undefined) => void;
  aLabel: string;
  bLabel: string;
  dir?: string;
  onDir?: (dir: string | undefined) => void;
}) {
  const aCommit = resolve(commits, aLabel);
  const bCommit = resolve(commits, bLabel);
  // Compared on the server (DuckDB over both versions' indexes): the
  // summary and the visual diff come with the first page; further item
  // changes a page at a time. Nothing here holds either version.
  // The change list a folder at a time, as the Files tab walks the tree.
  const prefix = dir ? `${dir}/` : '';
  const pages = useInfiniteQuery({
    queryKey: ['compare', name, aCommit, bCommit, prefix],
    queryFn: ({ pageParam }) => getCompare(name, aCommit!, bCommit!, pageParam, prefix),
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
  // The pair opened large, at full size: a reviewer judges a box's edge on
  // the real pixels. Never for a restricted dataset, where clear bytes come
  // only with a logged reveal (invariant 20); its blurred preview stands in.
  const opened = visual.find((v) => v.path === openPair);
  const openHashes = opened ? [opened.before?.hash, opened.after?.hash].filter((h): h is string => !!h) : [];
  const originals = useQuery({
    queryKey: ['downloads', name, ...openHashes],
    queryFn: () => getDownloads(name, openHashes),
    enabled: openHashes.length > 0 && !overview.restricted,
    staleTime: 5 * 60 * 1000,
  });
  const large = new Map((originals.data?.downloads ?? []).map((d) => [d.hash, d.url]));

  if (pages.isPending) return <RowsSkeleton rows={4} cols={3} />;
  if (pages.isError || !first)
    return (
      <p className="quiet" role="alert">
        Could not compare these versions; pick again or reload.
      </p>
    );

  const s = first.summary;
  // A split moved is a change: the item trains as something else now.
  const anyItems = s.added + s.modified + s.deleted + (s.split ?? 0) > 0;
  const anyAnns = s.ann_added + s.ann_changed + s.ann_removed > 0;

  return (
    <div className="comparison">
      <dl className="compare-stats">
        <div>
          <dt>Files</dt>
          <dd>
            <Count n={s.added} /> added, <Count n={s.modified} /> modified, <Count n={s.deleted} /> deleted
            {(s.split ?? 0) > 0 && (
              <>
                , <Count n={s.split ?? 0} /> moved to another split
              </>
            )}
          </dd>
        </div>
        {overview.kind === 'annotated' && (
          <div>
            <dt>Annotations</dt>
            <dd>
              <Count n={s.ann_added} /> added, <Count n={s.ann_changed} /> changed, <Count n={s.ann_removed} /> removed
            </dd>
          </div>
        )}
      </dl>

      {overview.kind === 'annotated' && first.by_class.length > 0 && (
        <table className="count-table class-changes">
          <caption>Annotation changes by class</caption>
          <thead>
            <tr>
              <th scope="col">class</th>
              <th scope="col" className="count">
                added
              </th>
              <th scope="col" className="count">
                changed
              </th>
              <th scope="col" className="count">
                removed
              </th>
            </tr>
          </thead>
          <tbody>
            {first.by_class.map((c) => (
              <tr key={c.class}>
                <td>{c.class === '' ? <span className="quiet">no class</span> : c.class}</td>
                <td className="data count">
                  <Count n={c.added} />
                </td>
                <td className="data count">
                  <Count n={c.changed} />
                </td>
                <td className="data count">
                  <Count n={c.removed} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {aCommit && bCommit && (anyItems || anyAnns) && (
        <Balance name={name} branch={overview.branch} kind={overview.kind} a={aCommit} b={bCommit} aLabel={aLabel} bLabel={bLabel} />
      )}

      {!anyItems && !anyAnns && <p className="quiet">These two versions hold exactly the same data.</p>}

      {onDir && (dir || (first.folders ?? []).length > 0) && (
        <ChangedFolders name={name} dir={dir} folders={first.folders ?? []} onDir={onDir} />
      )}

      {changes.length > 0 && (
        <ul className="change-list">
          {changes.map((c) => (
            <li key={c.path} className="change">
              <span className={`change-verb change-verb--${c.change === 'split' ? 'modified' : c.change}`}>{c.change}</span>
              <span className="data change-path">{c.path}</span>
              {c.change === 'split' ? (
                <span className="data">
                  {c.split_a ?? 'no split'} → {c.split_b ?? 'no split'}
                </span>
              ) : (
                c.size_b !== null && <span className="quiet data">{humanBytes(c.size_b)}</span>
              )}
              {c.change === 'modified' && !isTable(c.path) && thumbBy.has(c.hash_a!) && thumbBy.has(c.hash_b!) && (
                <span className="before-after">
                  <Thumb src={thumbBy.get(c.hash_a!)} alt={`${c.path} before`} label={extOf(c.path)} />
                  <span aria-hidden="true">→</span>
                  <Thumb src={thumbBy.get(c.hash_b!)} alt={`${c.path} after`} label={extOf(c.path)} />
                </span>
              )}
              {c.change === 'modified' && isTable(c.path) && (
                <RowChanges name={name} path={c.path} a={c.hash_a!} b={c.hash_b!} commitB={bCommit ?? undefined} />
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
            : `Show more changes (${changes.length.toLocaleString()} of ${changesUnder(first, s).toLocaleString()} shown)`}
        </button>
      )}

      {visual.length > 0 && (
        <VisualDiff
          pairs={visual}
          aLabel={aLabel}
          bLabel={bLabel}
          thumbs={thumbBy}
          open={openPair}
          onOpen={(p) => onOpenPair?.(p)}
          capped={visual.length >= visual_items}
          large={large}
        />
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
// Class balance and split sizes, before and after (U5): each version's
// statistics, kept on its commit, side by side. Shown only where a count
// moved; a balance that held needs no chart.
function Balance({
  name,
  branch,
  kind,
  a,
  b,
  aLabel,
  bLabel,
}: {
  name: string;
  branch: string;
  kind: Overview['kind'];
  a: string;
  b: string;
  aLabel: string;
  bLabel: string;
}) {
  const side = (commit: string) => ({
    queryKey: ['overview', name, null, commit, branch],
    queryFn: () => getOverview(name, undefined, commit, branch),
  });
  const before = useQuery(side(a));
  const after = useQuery(side(b));
  if (!before.data || !after.data) return null;
  const pair = (x: { name: string; count: number }[], y: { name: string; count: number }[], dot: boolean): PairRow[] => {
    const rows = new Map<string, PairRow>();
    for (const r of x) rows.set(r.name, { name: r.name, a: r.count, b: 0, dot: dot ? classColor(r.name) : undefined });
    for (const r of y) {
      const row = rows.get(r.name) ?? { name: r.name, a: 0, b: 0, dot: dot ? classColor(r.name) : undefined };
      rows.set(r.name, { ...row, b: r.count });
    }
    return [...rows.values()];
  };
  const moved = (rows: PairRow[]) => rows.some((r) => r.a !== r.b);
  const classes = kind === 'annotated' ? pair(before.data.classes, after.data.classes, true) : [];
  const splits = pair(before.data.splits, after.data.splits, false);
  return (
    <>
      {moved(classes) && (
        <DumbbellTable caption="Annotations by class" noun="annotations" aLabel={aLabel} bLabel={bLabel} rows={classes} />
      )}
      {moved(splits) && <DumbbellTable caption="Items by split" noun="items" aLabel={aLabel} bLabel={bLabel} rows={splits} />}
    </>
  );
}

// A table that changed in this few rows shows them without a click.
const few_rows = 10;

// A table has no picture: its rows below say what changed.
const tableExt = /\.(csv|parquet|jsonl|ndjson)$/i;
function isTable(path: string): boolean {
  return tableExt.test(path);
}

// A modified table file, by rows (CLAUDE.md, Formats): what was added and
// removed, with the rows themselves one click away. Computed once on the
// server; when it cannot be, the line says why, and the file line above
// already says the file changed.
function RowChanges({ name, path, a, b, commitB }: { name: string; path: string; a: string; b: string; commitB?: string }) {
  const answer = useQuery({
    queryKey: ['rowdiff', name, a, b, commitB ?? null],
    queryFn: () => getRowDiff(name, path, a, b, commitB),
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
  const changed = d.changed ?? 0;
  const key = d.key && d.key.length > 0 ? d.key : null;
  if (added === 0 && removed === 0 && changed === 0)
    return (
      <p className="row-changes quiet">The same {d.rows_b.toLocaleString()} rows, in another order or format.</p>
    );
  return (
    <div className="row-changes">
      <p className="data">
        <span className="change-verb--added">
          {added.toLocaleString()} {added === 1 ? 'row' : 'rows'} added
        </span>
        ,{' '}
        <span className="change-verb--deleted">{removed.toLocaleString()} removed</span>
        {key && (
          <>
            , <span className="change-verb--modified">{changed.toLocaleString()} changed</span>
          </>
        )}{' '}
        <span className="quiet">
          ({d.rows_a.toLocaleString()} → {d.rows_b.toLocaleString()} rows;{' '}
          {key ? `paired by ${key.join(', ')}` : 'an edited row counts as one removed and one added'})
        </span>
      </p>
      {d.key_note ? (
        <p className="quiet">{d.key_note}.</p>
      ) : (
        !key &&
        added > 0 &&
        removed > 0 && (
          <p className="quiet">
            To see rows changed rather than removed and added, name the table's key in{' '}
            <code className="data">.cidkeys</code>, e.g. <code className="data">{path} id</code>.
          </p>
        )
      )}
      {r.withheld ? (
        <p className="quiet">The rows themselves are withheld: this dataset is restricted.</p>
      ) : (
        <details open={added + removed + changed <= few_rows}>
          <summary>Show the changed rows</summary>
          {key && (d.changed_sample ?? []).length > 0 && (
            <div className="table-scroll">
              <table className="browse-table">
                <caption className="quiet">
                  Changed:{' '}
                  {(d.changed_sample ?? []).length < changed
                    ? `first ${(d.changed_sample ?? []).length} of ${changed.toLocaleString()}`
                    : changed.toLocaleString()}
                </caption>
                <thead>
                  <tr>
                    <th>{key.join(', ')}</th>
                    <th>column</th>
                    <th>before</th>
                    <th>after</th>
                  </tr>
                </thead>
                <tbody>
                  {(d.changed_sample ?? []).flatMap((row, i) =>
                    row.cells.map((cell, j) => (
                      <tr key={`${i}-${cell.column}`}>
                        <td className="data">{j === 0 ? Object.values(row.key).map(String).join(', ') : ''}</td>
                        <td className="data">{cell.column}</td>
                        <td className="data change-verb--deleted">{cell.before ?? 'null'}</td>
                        <td className="data change-verb--added">{cell.after ?? 'null'}</td>
                      </tr>
                    )),
                  )}
                </tbody>
              </table>
            </div>
          )}
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
