import { useQuery } from '@tanstack/react-query';
import { getState, getThumbs, type Overview, type TapeCommit } from '../api';
import { diffAnnotations, diffItems } from '../diff';
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

  // Before/after thumbs for changed images, where previews exist.
  const pairHashes = changes
    .filter((c) => c.kind === 'modified')
    .flatMap((c) => [c.hash_a!, c.hash_b!])
    .slice(0, 100);
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
            </li>
          ))}
        </ul>
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

function labelOf(c: TapeCommit): string {
  return c.release ?? c.id;
}

function resolve(commits: TapeCommit[], label: string): string | null {
  const byRelease = commits.find((c) => c.release === label);
  if (byRelease) return byRelease.id;
  const byId = commits.find((c) => c.id === label);
  return byId ? byId.id : null;
}
