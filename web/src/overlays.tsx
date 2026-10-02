import type { StateAnnotation } from './api';
import { useMemo } from 'react';
import { classColor, classColorValue, parseShape, type Shape } from './shapes';
import { decodeMask } from './rle';

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
        if (shape.kind === 'mask') {
          return (
            <MaskImage key={a.id} shape={shape} cls={a.class} width={width} height={height} label={label} />
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

// A mask, painted once into a canvas in its class colour and placed in the
// overlay's own coordinate space, so it scales with the image exactly as
// a box does. A mask whose runs do not fit its size draws nothing.
function MaskImage({
  shape,
  cls,
  width,
  height,
  label,
}: {
  shape: Extract<Shape, { kind: 'mask' }>;
  cls: string | null;
  width: number;
  height: number;
  label: string;
}) {
  const href = useMemo(() => {
    const bits = decodeMask(shape.h, shape.w, shape.runs);
    if (!bits) return null;
    const canvas = document.createElement('canvas');
    canvas.width = shape.w;
    canvas.height = shape.h;
    const ctx = canvas.getContext('2d');
    if (!ctx) return null;
    const img = ctx.createImageData(shape.w, shape.h);
    const hex = classColorValue(cls).replace('#', '');
    const [r, g, b] = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16));
    for (let i = 0; i < bits.length; i++) {
      if (!bits[i]) continue;
      img.data[i * 4] = r;
      img.data[i * 4 + 1] = g;
      img.data[i * 4 + 2] = b;
      img.data[i * 4 + 3] = 140;
    }
    ctx.putImageData(img, 0, 0);
    return canvas.toDataURL('image/png');
  }, [shape, cls]);
  if (!href) return null;
  return (
    <image className="overlay-mask" href={href} x={0} y={0} width={width} height={height} preserveAspectRatio="none">
      <title>{label}</title>
    </image>
  );
}
