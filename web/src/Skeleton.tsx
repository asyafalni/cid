import { Airship } from './Airship';

// Placeholders in a page's own shape (docs/roadmap.md, U3: no blank waits):
// what is coming takes its room before it arrives, so nothing jumps when
// it does. Quiet blocks, never words standing in for the page.

export function Bar({ width = '100%', height = '0.9rem' }: { width?: string; height?: string }) {
  return <span className="skeleton" style={{ width, height }} aria-hidden="true" />;
}

/** The home page while the list is on its way: the hero, and cards. */
export function HomeSkeleton() {
  return (
    <div className="home" aria-busy="true">
      <header className="home-hero sky-band">
        <div className="sky-clouds" aria-hidden="true" />
        <Airship className="home-airship" />
        <div className="home-hero-inner">
          <h1>Datasets</h1>
          <p className="home-count">
            <Bar width="12rem" />
          </p>
          <input type="search" className="home-search" placeholder="Search datasets" aria-label="Search datasets" disabled />
          <p className="home-hint">Names, classes, file types and owners.</p>
        </div>
      </header>
      <ul className="ds-cards" aria-label="Datasets, loading">
        {Array.from({ length: 6 }, (_, i) => (
          <li key={i} className="ds-card panel ds-card--skeleton">
            <span className="mosaic skeleton-block" />
            <span className="ds-card-body">
              <Bar width="70%" />
              <Bar width="40%" />
              <Bar width="55%" />
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

/** A dataset page while its overview is on its way: its own header, named. */
export function DatasetSkeleton({ name }: { name: string }) {
  const cut = name.lastIndexOf('/');
  return (
    <article className="dataset" aria-busy="true">
      <header className="dataset-head sky-band">
        <div className="sky-clouds" aria-hidden="true" />
        <div className="dataset-head-inner">
          <div className="dataset-title">
            <h1 className="dataset-name">
              {cut >= 0 && <span className="dataset-owner data">{name.slice(0, cut + 1)}</span>}
              <span className="dataset-leaf">{name.slice(cut + 1)}</span>
            </h1>
            <p className="dataset-meta">
              <Bar width="22rem" />
            </p>
          </div>
          <nav className="tape" aria-label="Releases and commits, loading">
            <Bar width="10rem" height="1.9rem" />
            <p className="tape-legend quiet">
              <Bar width="18rem" />
            </p>
          </nav>
        </div>
      </header>
      <nav className="tabs" aria-hidden="true">
        {['Overview', 'Browse', 'Releases', 'Files', 'Activity'].map((t) => (
          <span key={t} className="tab">
            {t}
          </span>
        ))}
      </nav>
      <GridSkeleton count={8} />
    </article>
  );
}

/** Tiles of Browse's gallery, or A look inside, still to come. */
export function GridSkeleton({ count }: { count: number }) {
  return (
    <ul className="gallery gallery--skeleton" aria-hidden="true">
      {Array.from({ length: count }, (_, i) => (
        <li key={i}>
          <span className="tile tile--skeleton">
            <span className="skeleton-block tile-skeleton-media" />
            <Bar width="60%" />
          </span>
        </li>
      ))}
    </ul>
  );
}

/** Rows of a table still to come, under its real header. */
export function RowsSkeleton({ rows, cols }: { rows: number; cols: number }) {
  return (
    <table className="browse-table" aria-busy="true">
      <tbody>
        {Array.from({ length: rows }, (_, r) => (
          <tr key={r}>
            {Array.from({ length: cols }, (_, c) => (
              <td key={c}>
                <Bar width={c === 0 ? '70%' : '50%'} />
              </td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  );
}
