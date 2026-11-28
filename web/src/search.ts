import type { DatasetSummary } from './api';

// Search, the front door (docs/dashboard.md §4.1, roadmap U17): one engine
// behind the top-bar box, the home page and the palette, so a thing found
// in one is found in all, in the same order. It works on the listing the
// browser already holds: no request per keystroke.
//
// Words in any order, every one of them found somewhere. A name's start
// beats its middle, the last part of a path beats a folder above it, a
// name beats a class beats an owner; one mistyped letter still finds a
// name. Each hit says why: the stretch of the name that matched, or the
// class, owner or file type that did.

/** A stretch of a text, `[from, to)`. */
export type Mark = [number, number];

export type Hit = {
  dataset: DatasetSummary;
  score: number;
  /** The stretches of the name the words matched, in order, not overlapping. */
  marks: Mark[];
  /** What else matched, when a word was not in the name: "class person". */
  why: string[];
};

/** The words of a search, lower case, nothing empty. */
export function wordsOf(q: string | undefined): string[] {
  return (q ?? '').toLowerCase().split(/\s+/).filter(Boolean);
}

const breaks = /[/\-_. ]/;

/** One edit apart or the same: a letter wrong, missing, extra, or two swapped. */
function near(a: string, b: string): boolean {
  if (a === b) return true;
  if (Math.abs(a.length - b.length) > 1) return false;
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i++;
  if (a.length === b.length) {
    // One letter wrong, or this one and the next swapped.
    if (a.slice(i + 1) === b.slice(i + 1)) return true;
    return a[i] === b[i + 1] && a[i + 1] === b[i] && a.slice(i + 2) === b.slice(i + 2);
  }
  const [long, short] = a.length > b.length ? [a, b] : [b, a];
  return long.slice(i + 1) === short.slice(i);
}

type Found = { score: number; mark?: Mark; why?: string };

/** The best place one word is found in a dataset, or null. */
function find(d: DatasetSummary, word: string): Found | null {
  const name = d.name.toLowerCase();
  const leafAt = name.lastIndexOf('/') + 1;
  let best: Found | null = null;
  const offer = (f: Found) => {
    if (best === null || f.score > best.score) best = f;
  };

  // The name: every place the word sits, the best of them kept.
  for (let at = name.indexOf(word); at !== -1; at = name.indexOf(word, at + 1)) {
    const inLeaf = at >= leafAt;
    const starts = at === 0 || breaks.test(name[at - 1]);
    const whole = starts && (at + word.length === name.length || breaks.test(name[at + word.length]));
    const score = inLeaf
      ? at === leafAt
        ? whole && at + word.length === name.length
          ? 100 // the dataset's own name, whole
          : 90 // it starts with the word
        : starts
          ? 80 // a part of it starts with the word
          : 70
      : starts
        ? 60 // a folder above it starts with the word
        : 50;
    offer({ score, mark: [at, at + word.length] });
  }
  for (const c of d.classes) {
    const v = c.toLowerCase();
    const at = v.indexOf(word);
    if (at !== -1) offer({ score: v === word ? 45 : at === 0 ? 40 : 35, why: `class ${c}` });
  }
  for (const o of d.owners) {
    const v = o.toLowerCase();
    const at = v.indexOf(word);
    if (at !== -1) offer({ score: at === 0 || v[at - 1] === ' ' ? 30 : 25, why: `owner ${o}` });
  }
  for (const t of d.types) {
    const v = t.ext.toLowerCase();
    if (v === word || v === `.${word}`) offer({ score: 30, why: `${t.count.toLocaleString()} ${t.ext} ${t.count === 1 ? 'file' : 'files'}` });
    else if (v.includes(word)) offer({ score: 20, why: `${t.ext} files` });
  }
  if (d.kind === word || (word === 'dataset' && d.kind !== 'model')) offer({ score: 15, why: d.kind });
  if (d.latest_release && d.latest_release.toLowerCase().includes(word)) offer({ score: 15, why: `release ${d.latest_release}` });

  // One mistyped letter, in a name only, and only for a word long enough
  // that a near miss means something.
  if (best === null && word.length >= 4) {
    let at = 0;
    for (const part of name.split(breaks)) {
      const head = part.slice(0, word.length);
      if (near(part, word) || (part.length > word.length && near(head, word))) {
        const len = near(part, word) ? part.length : word.length;
        offer({ score: at >= leafAt ? 40 : 30, mark: [at, at + len] });
      }
      at += part.length + 1;
    }
  }
  return best;
}

/** Overlapping or touching stretches made one, in order. */
function merged(marks: Mark[]): Mark[] {
  const out: Mark[] = [];
  for (const m of [...marks].sort((a, b) => a[0] - b[0])) {
    const last = out[out.length - 1];
    if (last && m[0] <= last[1]) last[1] = Math.max(last[1], m[1]);
    else out.push([m[0], m[1]]);
  }
  return out;
}

/** A dataset against the words: null unless every word is found in it. */
export function hit(d: DatasetSummary, words: string[]): Hit | null {
  let score = 0;
  const marks: Mark[] = [];
  const why: string[] = [];
  for (const w of words) {
    const f = find(d, w);
    if (f === null) return null;
    score += f.score;
    if (f.mark) marks.push(f.mark);
    if (f.why && !why.includes(f.why)) why.push(f.why);
  }
  return { dataset: d, score, marks: merged(marks), why };
}

/** The datasets the words find, best first. No words: all of them, as given.
 * Equal scores go to the one read more, then by name, so the order is the
 * same everywhere and never the server's. */
export function search(datasets: DatasetSummary[], q: string | undefined): Hit[] {
  const words = wordsOf(q);
  if (words.length === 0) return datasets.map((d) => ({ dataset: d, score: 0, marks: [], why: [] }));
  const hits: Hit[] = [];
  for (const d of datasets) {
    const h = hit(d, words);
    if (h) hits.push(h);
  }
  return hits.sort((a, b) => b.score - a.score || b.dataset.reads_30d - a.dataset.reads_30d || a.dataset.name.localeCompare(b.dataset.name));
}

/** A text cut at its marks: the pieces, each said to be marked or not. */
export function pieces(text: string, marks: Mark[]): { text: string; marked: boolean }[] {
  const out: { text: string; marked: boolean }[] = [];
  let at = 0;
  for (const [from, to] of marks) {
    if (from > at) out.push({ text: text.slice(at, from), marked: false });
    out.push({ text: text.slice(from, to), marked: true });
    at = to;
  }
  if (at < text.length) out.push({ text: text.slice(at), marked: false });
  return out;
}
