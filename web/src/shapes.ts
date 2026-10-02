import type { StateAnnotation } from './api';

// Annotation shapes and class colors, shared by the overlay and the
// chips, apart from the component so fast refresh keeps working.

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
