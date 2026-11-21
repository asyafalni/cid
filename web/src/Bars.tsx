import { useState } from 'react';

// Bars where numbers are compared (docs/roadmap.md, U5): a count table
// whose rows carry a bar, so the table is the chart's own table view. One
// hue (--data), thin bars from one baseline, the number at the tip in text
// ink; a class keeps its overlay colour as a dot beside its name, never on
// the bar, so identity and magnitude never share a colour.

export type BarRow = { name: string; value: number; dot?: string };

const shown = 12;

export function BarTable({ caption, rows, noun }: { caption: string; rows: BarRow[]; noun: string }) {
  const [all, setAll] = useState(false);
  const sorted = [...rows].sort((x, y) => y.value - x.value || x.name.localeCompare(y.name));
  const max = Math.max(1, ...sorted.map((r) => r.value));
  const total = sorted.reduce((sum, r) => sum + r.value, 0);
  const visible = all ? sorted : sorted.slice(0, shown);
  return (
    <table className="count-table bar-table">
      <caption>{caption}</caption>
      <tbody>
        {visible.map((r) => (
          <tr key={r.name} title={`${r.name}: ${r.value.toLocaleString()} ${noun} (${share(r.value, total)} of all)`}>
            <td className="bar-name">
              {r.dot && <span className="class-dot" style={{ background: r.dot }} aria-hidden="true" />}
              {r.name === '' ? <span className="quiet">none</span> : r.name}
            </td>
            <td className="bar-cell" aria-hidden="true">
              <span className="bar" style={{ width: `${(r.value / max) * 100}%` }} />
            </td>
            <td className="data count">{r.value.toLocaleString()}</td>
          </tr>
        ))}
      </tbody>
      {sorted.length > shown && (
        <tfoot>
          <tr>
            <td colSpan={3}>
              <button className="filter-clear" onClick={() => setAll((a) => !a)}>
                {all ? `Show the top ${shown}` : `Show all ${sorted.length}`}
              </button>
            </td>
          </tr>
        </tfoot>
      )}
    </table>
  );
}

export type PairRow = { name: string; a: number; b: number; dot?: string };

/** Before → after per row: a dumbbell, one hue in two shades, the change in words. */
export function DumbbellTable({
  caption,
  aLabel,
  bLabel,
  rows,
  noun,
}: {
  caption: string;
  aLabel: string;
  bLabel: string;
  rows: PairRow[];
  noun: string;
}) {
  const [all, setAll] = useState(false);
  const sorted = [...rows].sort((x, y) => Math.max(y.a, y.b) - Math.max(x.a, x.b) || x.name.localeCompare(y.name));
  const max = Math.max(1, ...sorted.map((r) => Math.max(r.a, r.b)));
  const visible = all ? sorted : sorted.slice(0, shown);
  const at = (v: number) => `${(v / max) * 100}%`;
  return (
    <table className="count-table bar-table dumbbell-table">
      <caption>
        {caption}
        <span className="dumbbell-legend">
          <span className="dumbbell-key dumbbell-key--a" aria-hidden="true" /> {aLabel}
          <span className="dumbbell-key dumbbell-key--b" aria-hidden="true" /> {bLabel}
        </span>
      </caption>
      <tbody>
        {visible.map((r) => (
          <tr
            key={r.name}
            title={`${r.name}: ${r.a.toLocaleString()} ${noun} in ${aLabel}, ${r.b.toLocaleString()} in ${bLabel}`}
          >
            <td className="bar-name">
              {r.dot && <span className="class-dot" style={{ background: r.dot }} aria-hidden="true" />}
              {r.name === '' ? <span className="quiet">none</span> : r.name}
            </td>
            <td className="bar-cell" aria-hidden="true">
              <span className="dumbbell">
                <span
                  className="dumbbell-line"
                  style={{ left: at(Math.min(r.a, r.b)), width: `${(Math.abs(r.b - r.a) / max) * 100}%` }}
                />
                <span className="dumbbell-dot dumbbell-dot--a" style={{ left: at(r.a) }} />
                <span className="dumbbell-dot dumbbell-dot--b" style={{ left: at(r.b) }} />
              </span>
            </td>
            <td className="data count">
              {r.a === r.b ? (
                <span className="quiet">{r.b.toLocaleString()}</span>
              ) : (
                <>
                  {r.a.toLocaleString()} → {r.b.toLocaleString()}{' '}
                  <span className="quiet">
                    ({r.b > r.a ? '+' : '−'}
                    {Math.abs(r.b - r.a).toLocaleString()})
                  </span>
                </>
              )}
            </td>
          </tr>
        ))}
      </tbody>
      {sorted.length > shown && (
        <tfoot>
          <tr>
            <td colSpan={3}>
              <button className="filter-clear" onClick={() => setAll((x) => !x)}>
                {all ? `Show the top ${shown}` : `Show all ${sorted.length}`}
              </button>
            </td>
          </tr>
        </tfoot>
      )}
    </table>
  );
}

function share(v: number, total: number): string {
  if (total === 0) return '0%';
  const p = (v / total) * 100;
  return p < 1 && p > 0 ? '<1%' : `${Math.round(p)}%`;
}
