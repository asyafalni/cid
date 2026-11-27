import { useEffect, useRef, useState } from 'react';
import type { CompareSide, StateAnnotation } from './api';
import { pairSummary, plural, shapeChanges, type ShapeChange, type VisualPair } from './pairChanges';
import { AnnotationOverlay } from './overlays';
import { Thumb } from './Thumb';
import { extOf } from './browseFilter';
import { classColor } from './shapes';
import { Icon } from './icons';

// Compare's pictures: every item whose annotations or bytes changed, the
// version before beside the version after, as a grid of pairs that each
// say in words what changed, so a review pass of hundreds of items reads
// as a list to scan, not a scroll of full-width pictures. A pair opens
// large (`pair=` in the URL, so it is a link), and the arrow keys step
// through the rest.

/** How many pairs show before "Show all": four rows of three. */
const first_shown = 12;

export function VisualDiff({
  pairs,
  aLabel,
  bLabel,
  thumbs,
  open,
  onOpen,
  capped,
  large,
}: {
  pairs: VisualPair[];
  aLabel: string;
  bLabel: string;
  thumbs: Map<string, string>;
  /** The open pair's path, from the URL. */
  open: string | undefined;
  onOpen: (path: string | undefined) => void;
  /** The server sent its most: more items changed than are pictured. */
  capped: boolean;
  /** The open pair's pictures at full size, by hash, when the dataset lets
   * them be fetched without a logged reveal; else its thumbnails stand in. */
  large?: Map<string, string>;
}) {
  const [all, setAll] = useState(false);
  const shown = all ? pairs : pairs.slice(0, first_shown);
  const openIndex = open === undefined ? -1 : pairs.findIndex((p) => p.path === open);
  return (
    <section className="visual-diff" aria-label="Changed items, before and after">
      <div className="visual-diff-head">
        <h3>
          {plural(pairs.length, 'changed item')}
          {capped && <span className="quiet"> (the first {pairs.length}; the list below names every change)</span>}
        </h3>
        <p className="quiet visual-diff-key">
          <span className="key-before">dashed</span> {aLabel} · <span className="key-after">solid</span> {bLabel} · open
          one to see it large
        </p>
      </div>
      <ul className="visual-diff-list">
        {shown.map((p) => {
          const changes = shapeChanges(p);
          return (
            <li key={p.path}>
              <button
                type="button"
                className={open === p.path ? 'pair-card pair-card--open' : 'pair-card'}
                onClick={() => onOpen(p.path)}
                aria-label={`${p.path}: ${pairSummary(p, changes).join(', ') || 'no visible change'}. Open it large.`}
              >
                <span className="before-after-pair">
                  <DiffSide label={aLabel} item={p.before ?? undefined} annotations={p.shapes_before} variant="before" thumb={p.before ? thumbs.get(p.before.hash) : undefined} compact />
                  <DiffSide label={bLabel} item={p.after ?? undefined} annotations={p.shapes_after} variant="after" thumb={p.after ? thumbs.get(p.after.hash) : undefined} compact />
                </span>
                <span className="data pair-card-path">{p.path}</span>
                <span className="pair-card-summary">{pairSummary(p, changes).join(' · ') || 'no visible change'}</span>
              </button>
            </li>
          );
        })}
      </ul>
      {pairs.length > first_shown && !all && (
        <button type="button" className="filter-clear more-items" onClick={() => setAll(true)}>
          Show all {pairs.length} changed items
        </button>
      )}
      {openIndex >= 0 && (
        <PairDialog
          pairs={pairs}
          index={openIndex}
          aLabel={aLabel}
          bLabel={bLabel}
          thumbs={large && large.size > 0 ? new Map([...thumbs, ...large]) : thumbs}
          onStep={(i) => onOpen(pairs[i].path)}
          onClose={() => onOpen(undefined)}
        />
      )}
    </section>
  );
}

function PairDialog({
  pairs,
  index,
  aLabel,
  bLabel,
  thumbs,
  onStep,
  onClose,
}: {
  pairs: VisualPair[];
  index: number;
  aLabel: string;
  bLabel: string;
  thumbs: Map<string, string>;
  onStep: (index: number) => void;
  onClose: () => void;
}) {
  const pair = pairs[index];
  const changes = shapeChanges(pair);
  const dialog = useRef<HTMLDivElement>(null);
  // Focus comes here on opening and goes back where it was on closing.
  useEffect(() => {
    const was = document.activeElement as HTMLElement | null;
    dialog.current?.focus();
    return () => was?.focus();
  }, []);
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose();
      else if (e.key === 'ArrowRight' && index + 1 < pairs.length) onStep(index + 1);
      else if (e.key === 'ArrowLeft' && index > 0) onStep(index - 1);
      else return;
      e.preventDefault();
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [index, pairs.length, onStep, onClose]);

  return (
    <div className="pair-dialog-backdrop" onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className="pair-dialog panel" role="dialog" aria-modal="true" aria-label={`${pair.path}, before and after`} tabIndex={-1} ref={dialog}>
        <div className="pair-dialog-head">
          <h3 className="data">{pair.path}</h3>
          <span className="quiet data">
            {index + 1} of {pairs.length}
          </span>
          <span className="pair-dialog-nav">
            <button type="button" className="filter-clear" disabled={index === 0} onClick={() => onStep(index - 1)} aria-label="The changed item before this one">
              ← previous
            </button>
            <button type="button" className="filter-clear" disabled={index + 1 === pairs.length} onClick={() => onStep(index + 1)} aria-label="The next changed item">
              next →
            </button>
            <button type="button" className="drawer-close" onClick={onClose} aria-label="Close">
              <Icon name="fail" />
            </button>
          </span>
        </div>
        <div className="before-after-pair">
          <DiffSide label={aLabel} item={pair.before ?? undefined} annotations={pair.shapes_before} variant="before" thumb={pair.before ? thumbs.get(pair.before.hash) : undefined} />
          <DiffSide label={bLabel} item={pair.after ?? undefined} annotations={pair.shapes_after} variant="after" thumb={pair.after ? thumbs.get(pair.after.hash) : undefined} />
        </div>
        <p className="pair-card-summary">{pairSummary(pair, changes).join(' · ') || 'No annotation changed; the file did.'}</p>
        {changes.length > 0 && (
          <table className="pair-changes">
            <caption className="visually-hidden">Each annotation that changed</caption>
            <thead>
              <tr>
                <th>class</th>
                <th>what changed</th>
                <th>by</th>
              </tr>
            </thead>
            <tbody>
              {changes.map((c) => (
                <tr key={c.id}>
                  <td>
                    <span className="class-dot" style={{ background: classColor(c.classAfter ?? c.classBefore) }} />
                    {c.what === 'changed' && c.classBefore !== c.classAfter ? (
                      <>
                        <del>{c.classBefore ?? 'no class'}</del> → {c.classAfter ?? 'no class'}
                      </>
                    ) : (
                      (c.classAfter ?? c.classBefore ?? 'no class')
                    )}{' '}
                    <span className="quiet">{c.kind}</span>
                  </td>
                  <td>{whatChanged(c)}</td>
                  <td className="quiet">{c.authorAfter ?? ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <p className="quiet pair-dialog-keys">← and → step through the changed items; Esc closes.</p>
      </div>
    </div>
  );
}

function whatChanged(c: ShapeChange): string {
  if (c.what === 'added') return 'added';
  if (c.what === 'removed') return 'removed';
  const parts: string[] = [];
  if (c.classBefore !== c.classAfter) parts.push('class');
  if (c.moved) {
    const dir = [c.moved.dx && `${Math.abs(c.moved.dx)} px ${c.moved.dx > 0 ? 'right' : 'left'}`, c.moved.dy && `${Math.abs(c.moved.dy)} px ${c.moved.dy > 0 ? 'down' : 'up'}`]
      .filter(Boolean)
      .join(', ');
    parts.push(`moved ${dir}`);
  }
  if (c.reshaped) parts.push('reshaped');
  if (c.attrsChanged) parts.push('attributes');
  return parts.join(', ');
}

export function DiffSide({
  label,
  item,
  annotations,
  variant,
  thumb,
  compact = false,
}: {
  label: string;
  item: CompareSide | undefined;
  annotations: StateAnnotation[];
  variant: 'before' | 'after';
  thumb: string | undefined;
  /** In a grid card: no caption, the card says it. */
  compact?: boolean;
}) {
  return (
    <figure className="diff-side">
      {!item ? (
        <div className="diff-side-none blueprint">
          <span className="quiet">Not in {label}</span>
        </div>
      ) : thumb && item.width && item.height ? (
        <span className="overlay-fit" style={{ aspectRatio: `${item.width} / ${item.height}` }}>
          <Thumb src={thumb} alt={`${item.path} at ${label}`} label={extOf(item.path)}>
            <AnnotationOverlay
              width={item.width}
              height={item.height}
              annotations={annotations}
              hidden={new Set()}
              opacity={1}
              variant={variant}
            />
          </Thumb>
        </span>
      ) : (
        <div className="diff-side-none blueprint">
          <span className="quiet">No preview yet</span>
        </div>
      )}
      {!compact && (
        <figcaption className="data">
          {label} · {annotations.length} shape{annotations.length === 1 ? '' : 's'}
        </figcaption>
      )}
    </figure>
  );
}
