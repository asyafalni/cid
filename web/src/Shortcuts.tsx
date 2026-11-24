import { useEffect, useState } from 'react';
import { everyTab, typingIn, views, type View } from './keys';

// The panel `?` opens, and the keys every tab of a dataset answers.

export function ShortcutsPanel({
  keys,
  note,
  onClose,
}: {
  /** The tab's own keys, when it has any, listed before every tab's. */
  keys?: [string, string][];
  note?: string;
  onClose: () => void;
}) {
  const groups: [string, [string, string][]][] = keys ? [['This tab', keys], ['Every tab', everyTab]] : [['Every tab', everyTab]];
  return (
    <section className="panel shortcuts" aria-label="Keyboard shortcuts">
      <h2>Keyboard shortcuts</h2>
      {groups.map(([label, list]) => (
        <div key={label}>
          {groups.length > 1 && <h3>{label}</h3>}
          <dl>
            {list.map(([k, does]) => (
              <div key={k}>
                <dt className="data">{k}</dt>
                <dd>{does}</dd>
              </div>
            ))}
          </dl>
        </div>
      ))}
      {note && <p className="quiet">{note}</p>}
      <button className="filter-clear" onClick={onClose}>
        Close
      </button>
    </section>
  );
}

/** Every tab's keys. Browse lists them itself, beside its own, so there
 * `?` and Escape are its. */
export function DatasetKeys({
  view,
  onView,
  onCompare,
}: {
  view: View;
  onView: (v: View) => void;
  onCompare: () => void;
}) {
  const [help, setHelp] = useState(false);
  const ownHelp = view !== 'browse';
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (typingIn(e)) return;
      const n = Number(e.key);
      if (Number.isInteger(n) && n >= 1 && n <= views.length) {
        e.preventDefault();
        setHelp(false);
        return onView(views[n - 1]);
      }
      if (e.key === 'c') {
        e.preventDefault();
        setHelp(false);
        return onCompare();
      }
      if (!ownHelp) return;
      if (e.key === '?') setHelp((h) => !h);
      else if (e.key === 'Escape') setHelp(false);
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onView, onCompare, ownHelp]);
  return help && ownHelp ? <ShortcutsPanel onClose={() => setHelp(false)} /> : null;
}
