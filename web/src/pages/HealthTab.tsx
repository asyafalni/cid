import { useQuery } from '@tanstack/react-query';
import { Link } from '@tanstack/react-router';
import { getHealth, type HealthCheck, type Overview, type Pin } from '../api';
import { BarTable } from '../Bars';
import { classColor } from '../shapes';
import { RowsSkeleton } from '../Skeleton';

// Dataset › Health (docs/dashboard.md, 4.5): the checks cid makes of the
// version on screen, computed once on the server and kept, never on page
// load. Each check is its mark as an icon and a word (never colour alone),
// what it found in words, and the paths it found, each a link into Browse
// at the same version; then the distributions, as tables with bars.

const marks: Record<HealthCheck['status'], { icon: string; word: string }> = {
  pass: { icon: '✓', word: 'pass' },
  warn: { icon: '!', word: 'warning' },
  fail: { icon: '✕', word: 'fail' },
  info: { icon: 'i', word: 'note' },
};

export function HealthTab({ name, overview, commit, pin }: { name: string; overview: Overview; commit: string | null; pin: Pin }) {
  const health = useQuery({
    queryKey: ['health', name, commit],
    queryFn: () => getHealth(name, commit!),
    enabled: commit !== null,
  });
  if (!commit) return <p className="quiet">Nothing committed yet, so nothing to check.</p>;
  if (health.isPending) return <RowsSkeleton rows={6} cols={2} />;
  if (health.isError || !health.data)
    return (
      <p className="quiet" role="alert">
        The checks could not be read just now; reload to try again.
      </p>
    );
  const h = health.data;
  // What needs a look first; the passes after it, a line each.
  const order: Record<HealthCheck['status'], number> = { fail: 0, warn: 1, info: 2, pass: 3 };
  const checks = [...h.checks].sort((x, y) => order[x.status] - order[y.status]);
  const fails = h.checks.filter((c) => c.status === 'fail').length;
  const warns = h.checks.filter((c) => c.status === 'warn').length;
  const annotated = overview.kind === 'annotated';
  const totals = new Map<string, number>();
  for (const c of h.class_split) totals.set(c.class, (totals.get(c.class) ?? 0) + c.n);
  const splits = [...new Set(h.class_split.map((c) => c.split))].sort();

  return (
    <div className="health">
      <p className="health-summary data" role="status">
        {fails === 0 && warns === 0
          ? `All ${h.checks.length} checks pass.`
          : [fails > 0 ? `${fails} failed` : null, warns > 0 ? `${warns} ${warns === 1 ? 'warning' : 'warnings'}` : null]
              .filter(Boolean)
              .join(', ') + ` of ${h.checks.length} checks.`}
      </p>
      <ul className="health-checks" aria-label="Checks">
        {checks.map((c) => (
          <li key={c.id} className={`health-check health-check--${c.status}`}>
            <span className="health-mark" aria-label={marks[c.status].word}>
              <span aria-hidden="true">{marks[c.status].icon}</span> {marks[c.status].word}
            </span>
            <div>
              <h3>{c.title}</h3>
              <p>{c.says}</p>
              {c.sample.length > 0 && (
                <ul className="health-sample">
                  {c.sample.map((path) => (
                    <li key={path}>
                      <Link className="data" to="/d/$" params={{ _splat: name }} search={{ ...pin, view: 'browse', item: path }}>
                        {path}
                      </Link>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          </li>
        ))}
      </ul>

      {annotated && h.annotations > 0 && (
        <div className="health-charts">
          <section className="panel card">
            <BarTable
              caption="Annotations by class"
              noun="annotations"
              rows={[...totals].map(([cls, n]) => ({ name: cls, value: n, dot: classColor(cls) }))}
            />
            {splits.length > 1 && (
              <div className="table-scroll">
                <table className="count-table">
                  <caption>By class and split</caption>
                  <thead>
                    <tr>
                      <th scope="col">class</th>
                      {splits.map((s) => (
                        <th key={s} scope="col" className="count">
                          {s === '' ? 'no split' : s}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {[...totals.keys()].map((cls) => (
                      <tr key={cls}>
                        <td>{cls === '' ? <span className="quiet">no class</span> : cls}</td>
                        {splits.map((s) => (
                          <td key={s} className="data count">
                            {(h.class_split.find((c) => c.class === cls && c.split === s)?.n ?? 0).toLocaleString()}
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
          <section className="panel card">
            <BarTable caption="Items by how many objects they hold" noun="items" rows={h.objects_per_item.map((b) => ({ name: b.b, value: b.n }))} keepOrder />
            {h.box_sizes.length > 0 && (
              <BarTable caption="Boxes by their share of the image" noun="boxes" rows={h.box_sizes.map((b) => ({ name: b.b, value: b.n }))} keepOrder />
            )}
            {h.aspect.length > 0 && (
              <BarTable caption="Images by shape" noun="images" rows={h.aspect.map((b) => ({ name: b.b, value: b.n }))} keepOrder />
            )}
          </section>
          {h.heat.some((n) => n > 0) && <HeatMap heat={h.heat} />}
        </div>
      )}
    </div>
  );
}

// Where boxes sit in their images: their centres on a 10×10 grid, one hue
// from light to dark (a sequential scale, docs/dashboard.md 3.3), each
// count printed in its cell, so the table is its own text view.
function HeatMap({ heat }: { heat: number[] }) {
  const max = Math.max(1, ...heat);
  const rows = Array.from({ length: 10 }, (_, r) => heat.slice(r * 10, r * 10 + 10));
  return (
    <section className="panel card">
      <table className="heat-map" aria-label="Box centres across the image, top left to bottom right">
        <caption>Where boxes sit (centres, the image in a 10×10 grid)</caption>
        <tbody>
          {rows.map((row, r) => (
            <tr key={r}>
              {row.map((n, c) => (
                <td
                  key={c}
                  title={`${n.toLocaleString()} box centres in row ${r + 1}, column ${c + 1}`}
                  style={{ background: `color-mix(in srgb, var(--data) ${Math.round((n / max) * 100)}%, var(--panel))` }}
                  className={n / max > 0.55 ? 'heat-dark' : undefined}
                >
                  {n > 0 ? n.toLocaleString() : ''}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
