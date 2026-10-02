// COCO run-length masks (docs/data-model.md, geometry per kind): exactly
// pycocotools' encoding, so a mask written by any detection tool reads
// here unchanged. Runs are column-major and start with background.

/** Decode `counts` — COCO's compressed string, or its plain array. */
export function runsOf(counts: unknown): number[] | null {
  if (Array.isArray(counts)) {
    return counts.every((n) => typeof n === 'number' && n >= 0) ? (counts as number[]) : null;
  }
  if (typeof counts !== 'string') return null;
  // pycocotools rleFrString, line for line.
  const out: number[] = [];
  let p = 0;
  while (p < counts.length) {
    let x = 0;
    let k = 0;
    let more = true;
    while (more) {
      if (p >= counts.length) return null;
      const c = counts.charCodeAt(p) - 48;
      x |= (c & 0x1f) << (5 * k);
      more = (c & 0x20) !== 0;
      p += 1;
      k += 1;
      if (!more && (c & 0x10) !== 0) x |= -1 << (5 * k);
    }
    if (out.length > 2) x += out[out.length - 2];
    if (x < 0) return null;
    out.push(x);
  }
  return out;
}

/** The mask's set pixels, as row-major alpha (1 = mask), or null when the
 *  runs do not add up to the size — a bad mask loses only itself. */
export function decodeMask(h: number, w: number, runs: number[]): Uint8Array | null {
  const total = runs.reduce((a, b) => a + b, 0);
  if (total !== h * w) return null;
  const out = new Uint8Array(h * w);
  let i = 0;
  let value = 0;
  for (const run of runs) {
    if (value === 1) {
      for (let j = i; j < i + run; j++) {
        // column-major index j → (x = ⌊j/h⌋, y = j mod h) → row-major
        const x = Math.floor(j / h);
        const y = j - x * h;
        out[y * w + x] = 1;
      }
    }
    i += run;
    value ^= 1;
  }
  return out;
}
