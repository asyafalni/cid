import type { ReactNode } from 'react';
import type { StateAnnotation } from './api';
import { classColor, parseSpan } from './shapes';

// A text item with its span annotations marked where they fall. Offsets
// count Unicode code points from the file's start, so "naïve" is five
// whatever its bytes. Overlapping spans split the text at every edge;
// a piece under several is marked by the first and titled with all.
// Spans past what was read (the first 64 KB) are counted, not guessed.

export function SpannedText({
  text,
  annotations,
  hidden,
}: {
  text: string;
  annotations: StateAnnotation[];
  hidden: ReadonlySet<string>;
}) {
  const chars = Array.from(text);
  const spans: { start: number; end: number; cls: string | null }[] = [];
  let unread = 0;
  let beyond = 0;
  for (const a of annotations) {
    if (a.kind !== 'span') continue;
    const s = parseSpan(a);
    if (!s) {
      unread++;
      continue;
    }
    if (a.class !== null && hidden.has(a.class)) continue;
    if (s.start >= chars.length) {
      beyond++;
      continue;
    }
    spans.push({ start: s.start, end: Math.min(s.end, chars.length), cls: a.class });
  }

  const edges = [...new Set([0, chars.length, ...spans.flatMap((s) => [s.start, s.end])])].sort((x, y) => x - y);
  const pieces: ReactNode[] = [];
  for (let i = 0; i + 1 < edges.length; i++) {
    const [from, to] = [edges[i], edges[i + 1]];
    const piece = chars.slice(from, to).join('');
    const over = spans.filter((s) => s.start <= from && s.end >= to);
    if (over.length === 0) {
      pieces.push(piece);
      continue;
    }
    const names = [...new Set(over.map((s) => s.cls ?? 'no class'))].join(', ');
    pieces.push(
      <mark key={from} className="span-mark" style={{ ['--mark' as string]: classColor(over[0].cls) }} title={names}>
        {piece}
      </mark>,
    );
  }

  return (
    <>
      <pre className="data">{pieces}</pre>
      {beyond > 0 && (
        <p className="quiet">
          {beyond === 1 ? 'One span lies' : `${beyond} spans lie`} past the part shown; download the file to see{' '}
          {beyond === 1 ? 'it' : 'them'}.
        </p>
      )}
      {unread > 0 && (
        <p className="quiet">
          {unread === 1 ? 'One span' : `${unread} spans`} could not be read (a start and an end, whole code points, the end
          after the start); the rest are marked.
        </p>
      )}
    </>
  );
}
