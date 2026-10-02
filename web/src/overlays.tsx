import type { StateAnnotation } from './api';

// Annotation overlays (docs/dashboard.md §4.3): shapes drawn on the
// media, scaled from the item's recorded pixel space. Parsing is
// tolerant on purpose — an annotation whose geometry does not parse
// loses only itself, never the view (principle: one bad file, one bad
// record, never a broken page).

export type Shape =
  | { kind: 'box'; x: number; y: number; w: number; h: number }
  | { kind: 'polygon'; points: [number, number][] }
  | { kind: 'points'; points: [number, number][] };

export function parseShape(a: StateAnnotation): Shape | null {
  const g = a.geometry;
  if (g === null || typeof g !== 'object') return null;
  const o = g as Record<string, unknown>;
  if (a.kind === 'box') {
    const { x, y, w, h } = o;
    if ([x, y, w, h].every((v) => typeof v === 'number')) {
      return { kind: 'box', x: x as number, y: y as number, w: w as number, h: h as number };
    }
    return null;
  }
  if (a.kind === 'polygon' || a.kind === 'points' || a.kind === 'keypoints') {
    const pts = o.points;
    if (!Array.isArray(pts)) return null;
    const points: [number, number][] = [];
    for (const p of pts) {
      if (Array.isArray(p) && typeof p[0] === 'number' && typeof p[1] === 'number') {
        points.push([p[0], p[1]]);
      } else {
        return null;
      }
    }
    if (points.length === 0) return null;
    return { kind: a.kind === 'polygon' ? 'polygon' : 'points', points };
  }
  return null;
}

// A class always lands on the same of the eight overlay colors, on
// either theme — the dot on the chip and the stroke on the shape agree
// because both come from here. Color is never the only carrier: the
// chip says the name, the shape's tooltip says class and author.
export function classColor(name: string | null): string {
  const text = name ?? '';
  let hash = 0;
  for (let i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) | 0;
  return `var(--ann-${(Math.abs(hash) % 8) + 1})`;
}

export function AnnotationOverlay({
  width,
  height,
  annotations,
  hidden,
  opacity,
  variant,
}: {
  width: number;
  height: number;
  annotations: StateAnnotation[];
  hidden: ReadonlySet<string>;
  opacity: number;
  /** In a compare: version A's shapes are drawn dashed, B's solid, so
   *  the difference reads without relying on color. */
  variant?: 'before' | 'after';
}) {
  const drawn = annotations
    .filter((a) => !hidden.has(a.class ?? ''))
    .map((a) => ({ a, shape: parseShape(a) }))
    .filter((x): x is { a: StateAnnotation; shape: Shape } => x.shape !== null);
  if (drawn.length === 0) return null;

  return (
    <svg
      className={variant ? `overlay overlay--${variant}` : 'overlay'}
      viewBox={`0 0 ${width} ${height}`}
      preserveAspectRatio="none"
      style={{ opacity }}
      aria-hidden="true"
    >
      {drawn.map(({ a, shape }) => {
        const color = classColor(a.class);
        const label = `${a.class ?? 'unlabelled'} — ${a.author}`;
        if (shape.kind === 'box') {
          return (
            <rect
              key={a.id}
              x={shape.x}
              y={shape.y}
              width={shape.w}
              height={shape.h}
              stroke={color}
              vectorEffect="non-scaling-stroke"
            >
              <title>{label}</title>
            </rect>
          );
        }
        if (shape.kind === 'polygon') {
          return (
            <polygon
              key={a.id}
              points={shape.points.map(([x, y]) => `${x},${y}`).join(' ')}
              stroke={color}
              vectorEffect="non-scaling-stroke"
            >
              <title>{label}</title>
            </polygon>
          );
        }
        return (
          <g key={a.id} fill={color}>
            {shape.points.map(([x, y], i) => (
              <circle key={i} cx={x} cy={y} r={Math.max(2, width / 100)}>
                <title>{label}</title>
              </circle>
            ))}
          </g>
        );
      })}
    </svg>
  );
}
