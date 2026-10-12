// The theme switch (docs/dashboard.md §3.2): follow the system, or pin
// Night flight or Daybreak. The choice is this browser's alone, kept in
// localStorage; index.html applies it before the first paint, so a pinned
// theme never flashes the other one.
export type Theme = 'system' | 'night' | 'daybreak';

const key = 'cid.theme';

export function storedTheme(): Theme {
  try {
    const v = localStorage.getItem(key);
    return v === 'night' || v === 'daybreak' ? v : 'system';
  } catch {
    return 'system';
  }
}

export function applyTheme(theme: Theme) {
  const root = document.documentElement;
  if (theme === 'system') root.removeAttribute('data-theme');
  else root.setAttribute('data-theme', theme);
  try {
    if (theme === 'system') localStorage.removeItem(key);
    else localStorage.setItem(key, theme);
  } catch {
    // Storage refused (a private window): the switch still holds for this page.
  }
}
