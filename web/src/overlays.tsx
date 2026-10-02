import type { StateAnnotation } from './api';
import { classColor, parseShape, type Shape } from './shapes';

// Annotation overlays (docs/dashboard.md §4.3): shapes drawn on the
// media, scaled from the item's recorded pixel space. Parsing is
// tolerant on purpose — an annotation whose geometry does not parse
// loses only itself, never the view (principle: one bad file, one bad
// record, never a broken page).

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
