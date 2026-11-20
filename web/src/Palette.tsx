import { useEffect, useId, useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useNavigate, useRouterState } from '@tanstack/react-router';
import { getBrowse, getOverview, listDatasets } from './api';

// The command palette (docs/dashboard.md, design language): ⌘K or Ctrl-K
// anywhere, then type to jump to a dataset, a release or tab of the one on
// screen, an item of it by path, or a page. Arrows move, Enter goes,
// Escape closes. Every result is a link the page could show anyway.

type Target = { to: string; params?: Record<string, string>; search?: Record<string, string> };
type Result = { key: string; label: string; kind: string; target: Target };

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
          aria-label="Jump to a dataset, release, tab, item or page"
          placeholder="Jump to… (a dataset, release, tab, item or page)"
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
        <ul id={listId} role="listbox" aria-label="Places" className="palette-list">
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
