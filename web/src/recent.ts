// "Recently viewed" (docs/dashboard.md §4.1): a per-viewer convenience,
// so it lives in this browser only. Storage can be blocked or absent
// (private windows, strict settings), so every access is guarded and the
// row simply does not appear when it cannot be read.

const key = 'cid-recent';
const keep = 6;

export function recentDatasets(): string[] {
  try {
    const raw = localStorage.getItem(key);
    const list: unknown = raw ? JSON.parse(raw) : [];
    return Array.isArray(list) ? list.filter((x): x is string => typeof x === 'string') : [];
  } catch {
    return [];
  }
}

export function noteVisit(name: string) {
  try {
    const next = [name, ...recentDatasets().filter((n) => n !== name)].slice(0, keep);
    localStorage.setItem(key, JSON.stringify(next));
  } catch {
    // no storage: nothing to remember, nothing to break
  }
}
