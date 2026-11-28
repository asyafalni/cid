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

/** What a search's filter words ask for (`kind:model class:person`). */
export type Asked = {
  kind?: 'files' | 'annotated' | 'model';
  type?: string;
  group?: string;
  health?: 'fail' | 'warn' | 'pass';
  restricted?: boolean;
  released?: boolean;
  classes: string[];
  owners: string[];
};

/** The filter words, and what each one's values are, for the box to offer. */
export const filterWords = {
  kind: 'files, annotated or model',
  type: 'a file type, as .wav',
  class: 'a class the annotations name',
  owner: 'an owner, by name',
  group: 'a folder of the dataset paths',
  health: 'fail, warn or pass',
  is: 'restricted or open',
  has: 'release',
  no: 'release',
} as const;

export type Parsed = { words: string[]; asked: Asked };

/** A search taken apart: its plain words, lower case, and its filter
 * words. A `key:value` whose key it does not know stays a plain word; a
 * filter word half typed (`kind:`, `kind:mo`) asks for nothing yet. */
export function parse(q: string | undefined): Parsed {
  const words: string[] = [];
  const asked: Asked = { classes: [], owners: [] };
  for (const token of (q ?? '').toLowerCase().split(/\s+/).filter(Boolean)) {
    const colon = token.indexOf(':');
    const key = colon > 0 ? token.slice(0, colon) : '';
    const value = colon > 0 ? token.slice(colon + 1) : '';
    if (value === '') {
      // A filter word still being typed (`kind:`) asks for nothing yet.
      if (!(colon > 0 && key in filterWords)) words.push(token);
    } else if (key === 'kind' && (value === 'files' || value === 'annotated' || value === 'model')) {
      asked.kind = value;
    } else if (key === 'type') {
      asked.type = value.startsWith('.') || value === 'file' ? value : `.${value}`;
    } else if (key === 'class') {
      asked.classes.push(value);
    } else if (key === 'owner') {
      asked.owners.push(value);
    } else if (key === 'group') {
      asked.group = value.replace(/\/+$/, '');
    } else if (key === 'health' && (value === 'fail' || value === 'warn' || value === 'pass')) {
      asked.health = value;
    } else if (key === 'is' && (value === 'restricted' || value === 'open')) {
      asked.restricted = value === 'restricted';
    } else if ((key === 'has' || key === 'no') && (value === 'release' || value === 'releases')) {
      asked.released = key === 'has';
    } else if (key === 'kind' || key === 'health' || key === 'is' || key === 'has' || key === 'no') {
      // One of a few fixed values, not yet one of them: still being typed.
    } else {
      words.push(token);
    }
  }
  return { words, asked };
}

/** The plain words of a search, lower case, nothing empty. */
export function wordsOf(q: string | undefined): string[] {
  return parse(q).words;
}

/** Whether a dataset is what the filter words ask for. */
export function allows(d: DatasetSummary, a: Asked): boolean {
  if (a.kind && d.kind !== a.kind) return false;
  if (a.type && !d.types.some((t) => t.ext.toLowerCase() === a.type)) return false;
  if (a.group && !d.name.toLowerCase().startsWith(`${a.group}/`)) return false;
  if (a.health) {
    const h = d.health;
    if (!h) return false;
    if ((h.fail > 0 ? 'fail' : h.warn > 0 ? 'warn' : 'pass') !== a.health) return false;
  }
  if (a.restricted !== undefined && d.restricted !== a.restricted) return false;
  if (a.released !== undefined && Boolean(d.latest_release) !== a.released) return false;
  for (const c of a.classes) if (!d.classes.some((x) => x.toLowerCase().includes(c))) return false;
  for (const o of a.owners) if (!d.owners.some((x) => x.toLowerCase().includes(o))) return false;
  return true;
}

/** A dataset against a whole search, filter words and all. */
export function match(d: DatasetSummary, q: string | undefined): Hit | null {
  const { words, asked } = parse(q);
  if (!allows(d, asked)) return null;
  const h = hit(d, words);
  if (h === null) return null;
  // A class or an owner asked for by name is a reason too.
  for (const c of asked.classes) for (const x of d.classes) if (x.toLowerCase().includes(c) && !h.why.includes(`class ${x}`)) h.why.push(`class ${x}`);
  for (const o of asked.owners) for (const x of d.owners) if (x.toLowerCase().includes(o) && !h.why.includes(`owner ${x}`)) h.why.push(`owner ${x}`);
  return h;
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
  if ((q ?? '').trim() === '') return datasets.map((d) => ({ dataset: d, score: 0, marks: [], why: [] }));
  const hits: Hit[] = [];
  for (const d of datasets) {
    const h = match(d, q);
    if (h) hits.push(h);
  }
  // Filter words alone rank nothing: the order given is kept.
  if (wordsOf(q).length === 0) return hits;
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

export type Offer = { text: string; says: string; count?: number };

/** What the box offers while a filter word is being typed: the words
 * themselves for a start of one (`ki`), and for `kind:` its values, each
 * with how many datasets it would leave under the rest of the search. */
export function offers(datasets: DatasetSummary[], q: string): Offer[] {
  const tokens = q.split(/\s+/);
  const last = (tokens[tokens.length - 1] ?? '').toLowerCase();
  if (last === '') return [];
  const rest = tokens.slice(0, -1).join(' ');
  const colon = last.indexOf(':');
  if (colon === -1) {
    if (last.length < 2) return [];
    return Object.entries(filterWords)
      .filter(([key]) => key.startsWith(last) && key !== last)
      .map(([key, says]) => ({ text: `${key}:`, says }));
  }
  const key = last.slice(0, colon);
  const typed = last.slice(colon + 1);
  if (!(key in filterWords)) return [];
  const within = datasets.filter((d) => match(d, rest) !== null);
  const counts = new Map<string, number>();
  const add = (v: string) => counts.set(v, (counts.get(v) ?? 0) + 1);
  for (const d of within) {
    if (key === 'kind') add(d.kind);
    else if (key === 'type') for (const t of d.types) add(t.ext.toLowerCase());
    else if (key === 'class') for (const c of d.classes) add(c.toLowerCase());
    else if (key === 'owner') for (const o of d.owners) add(o.toLowerCase().split(' ')[0]);
    else if (key === 'group') {
      const parts = d.name.toLowerCase().split('/').slice(0, -1);
      parts.forEach((_, i) => add(parts.slice(0, i + 1).join('/')));
    } else if (key === 'health') {
      if (d.health) add(d.health.fail > 0 ? 'fail' : d.health.warn > 0 ? 'warn' : 'pass');
    } else if (key === 'is') add(d.restricted ? 'restricted' : 'open');
    else if (key === 'has' && d.latest_release) add('release');
    else if (key === 'no' && !d.latest_release) add('release');
  }
  return [...counts]
    .filter(([v]) => v.includes(typed) && v !== typed)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, 6)
    .map(([v, count]) => ({ text: `${key}:${v}`, says: '', count }));
}

/** A search with the filter words the home page has its own controls for
 * taken out of it: what is left to search by (plain words, `class:` and
 * `owner:`), and the filters to set instead, so they show as the
 * sidebar's chips and can be taken off there. */
export function lift(q: string | undefined): {
  q: string | undefined;
  filters: { kind?: Asked['kind']; type?: string; group?: string; health?: Asked['health']; restricted?: 'yes' | 'no'; released?: 'yes' | 'no' };
} {
  const kept: string[] = [];
  const filters: ReturnType<typeof lift>['filters'] = {};
  for (const token of (q ?? '').split(/\s+/).filter(Boolean)) {
    const { words, asked } = parse(token);
    if (words.length > 0 || asked.classes.length > 0 || asked.owners.length > 0) kept.push(token);
    else if (asked.kind) filters.kind = asked.kind;
    else if (asked.type) filters.type = asked.type;
    else if (asked.group) filters.group = asked.group;
    else if (asked.health) filters.health = asked.health;
    else if (asked.restricted !== undefined) filters.restricted = asked.restricted ? 'yes' : 'no';
    else if (asked.released !== undefined) filters.released = asked.released ? 'yes' : 'no';
  }
  return { q: kept.length > 0 ? kept.join(' ') : undefined, filters };
}
