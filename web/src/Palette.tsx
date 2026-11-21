import { useEffect, useId, useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useNavigate, useRouterState } from '@tanstack/react-router';
import { getBrowse, getOverview, listDatasets } from './api';
import { commandFor, viewStateOf } from './command';

// The command palette (docs/dashboard.md, design language): ⌘K or Ctrl-K
// anywhere, then type to jump to a dataset, a release or tab of the one on
// screen, an item of it by path, or a page. Arrows move, Enter goes,
// Escape closes. Every result is a link the page could show anyway.

type Target = { to: string; params?: Record<string, string>; search?: Record<string, string> };
// A place to go, or an action to run (pin, compare, copy).
type Result = { key: string; label: string; kind: string; target?: Target; run?: () => Promise<string | void> };

const tabs = ['overview', 'browse', 'releases', 'files', 'activity'] as const;

export function Palette() {
  const [open, setOpen] = useState(false);
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setOpen((o) => !o);
      }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  return open ? <PaletteDialog onClose={() => setOpen(false)} /> : null;
}

function PaletteDialog({ onClose }: { onClose: () => void }) {
  const navigate = useNavigate();
  const location = useRouterState({ select: (s) => s.location });
  const [q, setQ] = useState('');
  const [active, setActive] = useState(0);
  // What an action did, said for a moment before the palette closes.
  const [done, setDone] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const listId = useId();
  useEffect(() => input.current?.focus(), []);

  // The dataset on screen, and the version it shows: releases, tabs and
  // items come from it.
  const name = location.pathname.startsWith('/d/') ? decodeURIComponent(location.pathname.slice(3)) : null;
  const here = location.search as Record<string, string | undefined>;
  const datasets = useQuery({ queryKey: ['datasets'], queryFn: listDatasets });
  const overview = useQuery({
    queryKey: ['overview', name, here.release ?? null, here.commit ?? null, here.branch ?? null],
    queryFn: () => getOverview(name!, here.release, here.commit, here.branch),
    enabled: name !== null,
  });
  const needle = q.trim().toLowerCase();
  const commit = overview.data?.pinned_commit ?? null;
  const items = useQuery({
    queryKey: ['palette-items', name, commit, needle],
    queryFn: () => getBrowse(name!, commit!, { q: needle, limit: 6, facets: false }),
    enabled: name !== null && commit !== null && needle.length >= 2,
  });

  const pin: Record<string, string> = {};
  for (const k of ['branch', 'release', 'commit'] as const) if (here[k]) pin[k] = here[k]!;
  const matches = (text: string) => needle === '' || text.toLowerCase().includes(needle);
  const results: Result[] = [];
  if (name && overview.data) {
    for (const c of overview.data.commits)
      if (c.release && matches(c.release))
        results.push({ key: `r:${c.release}`, label: c.release, kind: 'release', target: { to: '/d/$', params: { _splat: name }, search: { release: c.release } } });
    for (const t of tabs)
      if (matches(t)) results.push({ key: `t:${t}`, label: t, kind: 'tab', target: { to: '/d/$', params: { _splat: name }, search: { ...pin, view: t } } });
    for (const it of items.data?.items ?? [])
      results.push({ key: `i:${it.path}`, label: it.path, kind: 'item', target: { to: '/d/$', params: { _splat: name }, search: { ...pin, view: 'browse', item: it.path } } });
    // Actions on the page on screen: the version it shows, and what it says.
    const o = overview.data;
    const state = viewStateOf(o, here);
    const shown = commandFor(o, state, window.location.hostname);
    if (shown && matches('copy the command for this view'))
      results.push({ key: 'a:command', label: 'Copy the command for this view', kind: 'action', run: () => copy(shown.command, 'Command copied') });
    if (matches('copy a link to this view'))
      results.push({ key: 'a:link', label: 'Copy a link to this view', kind: 'action', run: () => copy(window.location.href, 'Link copied') });
    // Pin: an unpinned page follows the newest version; pinned, it stays.
    if (!here.release && !here.commit && o.pinned_commit) {
      const label = state.pinned ? `Pin the page to ${state.pinned}` : `Pin the page to commit ${o.pinned_commit.slice(0, 8)}`;
      if (matches(label) || matches('pin'))
        results.push({
          key: 'a:pin',
          label,
          kind: 'action',
          target: { to: '/d/$', params: { _splat: name }, search: { ...stringSearch(here), ...(state.pinned ? { release: state.pinned } : { commit: o.pinned_commit }) } },
        });
    }
    // Compare the release on screen with the one before it.
    const releases = o.commits.filter((c) => c.release);
    const at = releases.findIndex((c) => c.release === state.pinned);
    if (at >= 0 && at + 1 < releases.length) {
      const label = `Compare ${releases[at + 1].release} with ${releases[at].release}`;
      if (matches(label) || matches('compare'))
        results.push({
          key: 'a:compare',
          label,
          kind: 'action',
          target: { to: '/d/$', params: { _splat: name }, search: { ...pin, view: 'releases', a: releases[at + 1].release!, b: releases[at].release! } },
        });
    }
  }
  for (const d of datasets.data?.datasets ?? [])
    if (matches(d.name)) results.push({ key: `d:${d.name}`, label: d.name, kind: d.kind === 'model' ? 'model' : 'dataset', target: { to: '/d/$', params: { _splat: d.name } } });
  for (const [label, to] of [
    ['all datasets', '/'],
    ['SSH keys', '/keys'],
    ['tokens', '/tokens'],
  ] as const)
    if (matches(label)) results.push({ key: `p:${to}`, label, kind: 'page', target: { to } });
  const shown = results.slice(0, 12);
  const at = Math.min(active, Math.max(0, shown.length - 1));

  const go = (r: Result | undefined) => {
    if (!r) return;
    if (r.run) {
      void r.run().then((said) => {
        if (!said) return onClose();
        setDone(said);
        setTimeout(onClose, 900);
      });
      return;
    }
    onClose();
    void navigate(r.target as Parameters<typeof navigate>[0]);
  };

  return (
    <div className="palette-backdrop" onMouseDown={onClose}>
      <div
        className="palette panel"
        role="dialog"
        aria-modal="true"
        aria-label="Jump to"
        onMouseDown={(e) => e.stopPropagation()}
      >
        <input
          ref={input}
          role="combobox"
          aria-expanded={shown.length > 0}
          aria-controls={listId}
          aria-activedescendant={shown.length > 0 ? `${listId}-${at}` : undefined}
          aria-autocomplete="list"
          aria-label="Jump to a dataset, release, tab, item or page, or run an action"
          placeholder="Jump to… (a dataset, release, tab, item or page), or pin, compare, copy"
          value={q}
          onChange={(e) => {
            setQ(e.target.value);
            setActive(0);
          }}
          onKeyDown={(e) => {
            if (e.key === 'ArrowDown') {
              e.preventDefault();
              setActive((a) => Math.min(a + 1, shown.length - 1));
            } else if (e.key === 'ArrowUp') {
              e.preventDefault();
              setActive((a) => Math.max(a - 1, 0));
            } else if (e.key === 'Enter') {
              e.preventDefault();
              go(shown[at]);
            } else if (e.key === 'Escape') {
              e.preventDefault();
              onClose();
            }
          }}
        />
        <p className="quiet palette-done" role="status">
          {done}
        </p>
        <ul id={listId} role="listbox" aria-label="Places and actions" className="palette-list">
          {shown.map((r, i) => (
            <li
              key={r.key}
              id={`${listId}-${i}`}
              role="option"
              aria-selected={i === at}
              className={i === at ? 'palette-item on' : 'palette-item'}
              onMouseEnter={() => setActive(i)}
              onClick={() => go(r)}
            >
              <span className="data">{r.label}</span>
              <span className="quiet palette-kind">{r.kind}</span>
            </li>
          ))}
          {shown.length === 0 && <li className="quiet palette-none">Nothing matches.</li>}
        </ul>
      </div>
    </div>
  );
}

/** Copies text; says what it did, or that the browser would not. */
async function copy(text: string, said: string): Promise<string> {
  try {
    await navigator.clipboard.writeText(text);
    return said;
  } catch {
    return 'The browser did not allow copying here';
  }
}

/** The URL's search as strings, for a link that keeps it. */
function stringSearch(search: Record<string, string | undefined>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(search)) if (v !== undefined) out[k] = String(v);
  return out;
}
