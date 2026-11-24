// Keyboard shortcuts (docs/dashboard.md, principle 10): what every tab of
// a dataset answers, and the panel `?` opens. A key typed into a field,
// or with a modifier held (⌘K is the palette's), is never a shortcut.

export function typingIn(e: KeyboardEvent): boolean {
  if (e.metaKey || e.ctrlKey || e.altKey) return true;
  const t = e.target as HTMLElement | null;
  return !!t && (['INPUT', 'TEXTAREA', 'SELECT', 'AUDIO', 'VIDEO'].includes(t.tagName) || t.isContentEditable);
}

export const views = ['overview', 'browse', 'releases', 'health', 'files', 'activity'] as const;
export type View = (typeof views)[number];

export const everyTab: [string, string][] = [
  ['1 … 6', 'Overview, Browse, Releases, Health, Files, Activity'],
  ['c', 'compare this release with the one before'],
  ['?', 'this list'],
];
