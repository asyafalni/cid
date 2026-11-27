import { useState } from 'react';
import { Link } from '@tanstack/react-router';
import type { DatasetSummary } from './api';
import { facetKeys, facetTitle, facetValues, valueLabel, worthShowing, type FacetKey, type HomeSearch } from './homeFilter';
import { Icon, type IconName } from './icons';

// The home page's sidebar (docs/dashboard.md §4.1): the way back to the
// datasets a person uses, then each filter as a list with its counts.

const few = 8;

const facetIcon: Record<FacetKey, IconName> = {
  group: 'folder',
  kind: 'files',
  type: 'file',
  released: 'releases',
  restricted: 'restricted',
  health: 'health',
};

export function HomeSidebar({
  datasets,
  search,
  starred,
  recent,
  onPick,
}: {
  datasets: DatasetSummary[];
  search: HomeSearch;
  starred: string[];
  recent: string[];
  onPick: (patch: Partial<HomeSearch>) => void;
}) {
  // A long group shows its commonest values; the rest on request.
  const [all, setAll] = useState<Partial<Record<FacetKey, boolean>>>({});
  return (
    <>
      {starred.length > 0 && <Shortcuts title="Starred" names={starred} />}
      {recent.length > 0 && <Shortcuts title="Recently viewed" names={recent} />}
      {facetKeys.map((key) => {
        const values = facetValues(key, datasets, search);
        if (!worthShowing(key, values, search, datasets)) return null;
        const on = search[key];
        const long = key !== 'group' && values.length > few;
        const shown = long && !all[key] ? values.filter((v, i) => i < few || v.value === on) : values;
        return (
          <section key={key} className="side-group" aria-label={facetTitle[key]}>
            <h2 className="side-title">
              <Icon name={facetIcon[key]} /> {facetTitle[key]}
            </h2>
            <ul className="side-list">
              {shown.map((v) => {
                const active = on === v.value;
                return (
                  <li key={v.value}>
                    <button
                      className={active ? 'side-value side-value--on' : 'side-value'}
                      style={v.depth > 0 ? { paddingLeft: `calc(var(--space-2) + ${v.depth} * var(--space-3))` } : undefined}
                      aria-pressed={active}
                      // Nothing behind it under the other filters: said, and
                      // not offered (the one in use can always be let go).
                      disabled={v.count === 0 && !active}
                      title={key === 'group' ? v.value : undefined}
                      onClick={() => onPick({ [key]: active ? undefined : v.value })}
                    >
                      <span className={key === 'group' || key === 'type' ? 'side-name data' : 'side-name'}>
                        {key === 'group' ? `${v.value.split('/').pop()}/` : valueLabel(key, v.value)}
                      </span>
                      <span className="side-count data">{v.count.toLocaleString()}</span>
                    </button>
                  </li>
                );
              })}
            </ul>
            {long && (
              <button className="side-more" aria-expanded={Boolean(all[key])} onClick={() => setAll((a) => ({ ...a, [key]: !a[key] }))}>
                {all[key] ? 'Show fewer' : `Show all ${values.length}`}
              </button>
            )}
          </section>
        );
      })}
    </>
  );
}

function Shortcuts({ title, names }: { title: string; names: string[] }) {
  return (
    <nav className="side-group" aria-label={title}>
      <h2 className="side-title">
        <Icon name={title === 'Starred' ? 'star' : 'clock'} /> {title}
      </h2>
      <ul className="side-list">
        {names.map((n) => (
          <li key={n}>
            <Link to="/d/$" params={{ _splat: n }} className="side-link data" title={n}>
              {n.split('/').pop()}{' '}
              <span className="side-where">{n.split('/').slice(0, -1).join('/')}</span>
            </Link>
          </li>
        ))}
      </ul>
    </nav>
  );
}
