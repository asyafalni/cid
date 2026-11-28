import { useEffect, useId, useRef, useState, type FormEvent } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useNavigate } from '@tanstack/react-router';
import { kindLabel, listDatasets, type DatasetSummary } from './api';
import { humanBytes } from './format';
import { Icon } from './icons';
import { typingIn } from './keys';
import { recentDatasets } from './recent';
import { pieces, search, wordsOf, type Hit, type Mark } from './search';

/** A text with the stretches a search matched marked (`<mark>`). */
export function Marked({ text, marks }: { text: string; marks: Mark[] }) {
  if (marks.length === 0) return <>{text}</>;
  return (
    <>
      {pieces(text, marks).map((p, i) => (p.marked ? <mark key={i}>{p.text}</mark> : <span key={i}>{p.text}</span>))}
    </>
  );
}

const most = 8;

// The top bar's search (roadmap U17): it answers as you type, on every
// page, from the listing the browser holds. Datasets first, then models,
// best match first, each saying why it matched; arrows and Enter go to
// one, Enter alone opens the home page with the words as its search.
// Empty, it offers the way back: starred, then recently viewed. `/`
// reaches it from anywhere.
export function SearchBox() {
  const navigate = useNavigate();
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const input = useRef<HTMLInputElement>(null);
  const box = useRef<HTMLFormElement>(null);
  const listId = useId();
  // The listing, asked for when the box is first used on a page that had
  // not loaded it; the home page and the palette share the same answer.
  const [wanted, setWanted] = useState(false);
  const datasets = useQuery({ queryKey: ['datasets'], queryFn: listDatasets, enabled: wanted });
  const all = datasets.data?.datasets ?? [];

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key !== '/' || typingIn(e) || e.ctrlKey || e.metaKey || e.altKey) return;
      e.preventDefault();
      input.current?.focus();
    }
    function onDown(e: MouseEvent) {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
    }
    window.addEventListener('keydown', onKey);
    window.addEventListener('mousedown', onDown);
    return () => {
      window.removeEventListener('keydown', onKey);
      window.removeEventListener('mousedown', onDown);
    };
  }, []);

  const words = wordsOf(q);
  // With words: the best matches, datasets before models. Without: the
  // way back to what this person uses.
  let groups: { title: string; hits: Hit[] }[];
  let total = 0;
  if (words.length > 0) {
    const hits = search(all, q);
    total = hits.length;
    const shown = hits.slice(0, most);
    groups = [
      { title: 'Datasets', hits: shown.filter((h) => h.dataset.kind !== 'model') },
      { title: 'Models', hits: shown.filter((h) => h.dataset.kind === 'model') },
    ];
  } else {
    const byName = new Map(all.map((d) => [d.name, d]));
    const plain = (d: DatasetSummary): Hit => ({ dataset: d, score: 0, marks: [], why: [] });
    const starred = all.filter((d) => d.starred).slice(0, most);
    const recent = recentDatasets()
      .map((n) => byName.get(n))
      .filter((d): d is DatasetSummary => d !== undefined && !d.starred)
      .slice(0, most - starred.length);
    groups = [
      { title: 'Starred', hits: starred.map(plain) },
      { title: 'Recently viewed', hits: recent.map(plain) },
    ];
  }
  groups = groups.filter((g) => g.hits.length > 0);
  const flat = groups.flatMap((g) => g.hits);
  const at = Math.min(active, flat.length - 1);

  const go = (h: Hit) => {
    setOpen(false);
    setQ('');
    input.current?.blur();
    void navigate({ to: '/d/$', params: { _splat: h.dataset.name } });
  };
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (at >= 0 && flat[at]) return go(flat[at]);
    setOpen(false);
    void navigate({ to: '/', search: q.trim() === '' ? {} : { q: q.trim() } });
  };

  const showing = open && (flat.length > 0 || words.length > 0);
  let row = -1;
  return (
    <form className="topbar-search" role="search" onSubmit={submit} ref={box}>
      <input
        ref={input}
        type="search"
        role="combobox"
        aria-label="Search datasets"
        aria-expanded={showing}
        aria-controls={listId}
        aria-autocomplete="list"
        aria-activedescendant={showing && at >= 0 ? `${listId}-${at}` : undefined}
        placeholder="Search datasets and models"
        autoComplete="off"
        value={q}
        onFocus={() => {
          setWanted(true);
          setOpen(true);
        }}
        onChange={(e) => {
          setQ(e.target.value);
          setActive(-1);
          setOpen(true);
        }}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown') {
            e.preventDefault();
            setOpen(true);
            setActive((a) => Math.min(a + 1, flat.length - 1));
          } else if (e.key === 'ArrowUp') {
            e.preventDefault();
            setActive((a) => Math.max(a - 1, -1));
          } else if (e.key === 'Escape') {
            if (open) e.preventDefault();
            setOpen(false);
          }
        }}
      />
      <kbd className="topbar-search-key" aria-hidden="true">
        /
      </kbd>
      {showing && (
        <div className="search-results panel" id={listId} role="listbox" aria-label="Search results">
          {groups.map((g) => (
            <div key={g.title} role="group" aria-label={g.title}>
              <p className="search-group">{g.title}</p>
              {g.hits.map((h) => {
                row += 1;
                const i = row;
                const d = h.dataset;
                return (
                  <div
                    key={d.name}
                    id={`${listId}-${i}`}
                    role="option"
                    aria-selected={i === at}
                    className={i === at ? 'search-hit on' : 'search-hit'}
                    onMouseEnter={() => setActive(i)}
                    // Before the box loses focus and the list goes.
                    onMouseDown={(e) => {
                      e.preventDefault();
                      go(h);
                    }}
                  >
                    <Icon name={d.kind} />
                    <span className="search-hit-main">
                      <span className="data search-hit-name">
                        <Marked text={d.name} marks={h.marks} />
                      </span>
                      <span className="quiet search-hit-facts">
                        {h.why.length > 0 && <span className="search-why">{h.why.join(' · ')} · </span>}
                        {kindLabel(d.kind)} · {d.items.toLocaleString()} {d.items === 1 ? 'item' : 'items'} · {humanBytes(d.bytes)}
                        {d.latest_release ? ` · ${d.latest_release}` : ''}
                      </span>
                    </span>
                  </div>
                );
              })}
            </div>
          ))}
          {words.length > 0 && (
            <p className="search-foot quiet" aria-live="polite">
              {datasets.isPending
                ? 'Looking…'
                : total === 0
                  ? 'Nothing matches. Search looks at names, classes, file types, owners and releases.'
                  : total > flat.length
                    ? `Enter for all ${total.toLocaleString()} results`
                    : `${total} ${total === 1 ? 'result' : 'results'} · Enter opens them on the home page`}
            </p>
          )}
        </div>
      )}
    </form>
  );
}
