import type { StateAnnotation } from './api';
import { runsOf } from './rle';

// Annotation shapes and class colors, shared by the overlay and the
// chips, apart from the component so fast refresh keeps working.

export type Shape =
  | { kind: 'box'; x: number; y: number; w: number; h: number }
  | { kind: 'mask'; h: number; w: number; runs: number[] }
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
  if (a.kind === 'mask') {
    const size = o.size;
    if (!Array.isArray(size) || typeof size[0] !== 'number' || typeof size[1] !== 'number') return null;
    const runs = runsOf(o.counts);
    if (!runs) return null;
    return { kind: 'mask', h: size[0], w: size[1], runs };
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

/** The class colour as the canvas needs it (the CSS variable, resolved). */
export function classColorValue(name: string | null): string {
  const v = classColor(name).slice('var('.length, -1);
  return getComputedStyle(document.documentElement).getPropertyValue(v).trim() || '#5bd8e0';
}

// Time and text annotations (docs/data-model.md, "Geometry, per kind"):
// a `segment` or `transcript` is a time range in seconds, a transcript
// with its words; a `span` is a range of Unicode code points into the
// file's text, end exclusive.

export type TimeRange = { start: number; end: number; text: string | null };

export function parseTime(a: StateAnnotation): TimeRange | null {
  if (a.kind !== 'segment' && a.kind !== 'transcript') return null;
  const g = a.geometry;
  if (g === null || typeof g !== 'object') return null;
  const { start, end, text } = g as Record<string, unknown>;
  if (typeof start !== 'number' || typeof end !== 'number' || !(start >= 0) || !(end >= start)) return null;
  if (a.kind === 'transcript' && typeof text !== 'string') return null;
  return { start, end, text: typeof text === 'string' ? text : null };
}

export function parseSpan(a: StateAnnotation): { start: number; end: number } | null {
  if (a.kind !== 'span') return null;
  const g = a.geometry;
  if (g === null || typeof g !== 'object') return null;
  const { start, end } = g as Record<string, unknown>;
  if (!Number.isInteger(start) || !Number.isInteger(end) || (start as number) < 0 || (end as number) <= (start as number)) return null;
  return { start: start as number, end: end as number };
}

/** Seconds as people read a player's clock: 0:04.2, 1:02:03.0. */
export function clock(seconds: number): string {
  const tenths = Math.round(seconds * 10);
  const h = Math.floor(tenths / 36000);
  const m = Math.floor((tenths % 36000) / 600);
  const s = ((tenths % 600) / 10).toFixed(1).padStart(4, '0');
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`;
}
