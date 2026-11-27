import type { ReactNode } from 'react';

// cid's own icons (docs/dashboard.md §3.5, roadmap U16): one small set in
// the airship's hand, and where a thing has one, an object from its
// engineer's workshop: a gauge for health, goggles for looking, a pennant
// for a release, the logbook, a blueprint, a crate, a gear. Marks that
// must be read at once (tick, cross, copy, download) stay the plain ones. A 20 px grid, 1.5 px strokes in the text's colour,
// square caps and mitred corners, as a draughtsman's pen leaves them; a
// filled dot or square where a rivet or a handle would be. Inline SVG, no
// icon font and no dependency. An icon is decoration beside its words
// (aria-hidden); where it stands alone, the control carries the name.

const shapes = {
  // What a thing is.
  files: (
    <>
      <path d="M6.5 2.5h6l3 3v9h-9z" />
      <path d="M12.5 2.5v3h3" />
      <path d="M4 6v11.5h8" />
    </>
  ),
  annotated: (
    <>
      <path d="M2.5 3.5h15v13h-15z" />
      <path d="M6.5 7.5h7v5.5h-7z" />
      <path className="icon-fill" d="M5.5 6.5h2v2h-2zM12.5 6.5h2v2h-2zM5.5 12h2v2h-2zM12.5 12h2v2h-2z" />
    </>
  ),
  model: (
    // A gear: the engine a training run built.
    <>
      <circle cx="10" cy="10" r="4.6" />
      <circle className="icon-fill" cx="10" cy="10" r="1.3" />
      <path d="M10 2.5v2.9M10 14.6v2.9M2.5 10h2.9M14.6 10h2.9M4.7 4.7l2 2M13.3 13.3l2 2M4.7 15.3l2-2M13.3 6.7l2-2" />
    </>
  ),
  // Where you are: the tabs.
  overview: (
    // A blueprint: the drawing of the whole machine.
    <>
      <path d="M3.5 3.5h13v13h-13z" />
      <circle cx="8.5" cy="8.7" r="2.4" />
      <path d="M11 8.7h3M6 13.5h8" />
    </>
  ),
  browse: (
    // The engineer's goggles: for looking closely.
    <>
      <circle cx="5.9" cy="10.5" r="3.6" />
      <circle cx="14.1" cy="10.5" r="3.6" />
      <path d="M9.5 9.8h1M2.3 9.6L1 9.2M17.7 9.6l1.3-.4" />
    </>
  ),
  releases: (
    // A pennant on its mast: flown when a release is made.
    <>
      <path d="M5 2.5v15" />
      <path d="M5 4h11l-3 3 3 3H5" />
    </>
  ),
  health: (
    // A pressure gauge.
    <>
      <circle cx="10" cy="10" r="7.25" />
      <path d="M10 2.750v1.750M2.75 10H4.500M17.25 10H15.500M4.9 4.900l1.2 1.200M15.1 4.900l-1.2 1.2" />
      <path d="M10 10l3.2-3.7" />
      <circle className="icon-fill" cx="10" cy="10" r="1.3" />
    </>
  ),
  // A cargo crate: the hold, where the files are.
  crate: (
    <>
      <path d="M2.5 7.500h15v9h-15z" />
      <path d="M4 7.500v-3h12v3" />
      <path d="M7.5 7.500v9M12.5 7.500v9" />
    </>
  ),
  folder: <path d="M2.5 4.5h5l2 2.5h8v9h-15z" />,
  activity: (
    // The logbook.
    <>
      <path d="M4 3h12v14H4z" />
      <path d="M7 3v14" />
      <path d="M9.5 7h4M9.5 10h4M9.5 13h2.5" />
    </>
  ),
  // How it is.
  pass: <path d="M4 10.5l4 4 8-9" />,
  warn: (
    <>
      <path d="M10 3l7.5 13.5h-15z" />
      <path d="M10 8.5v3.5" />
      <path className="icon-fill" d="M9.2 13.4h1.6V15H9.2z" />
    </>
  ),
  fail: <path d="M5 5l10 10M15 5L5 15" />,
  info: (
    <>
      <circle cx="10" cy="10" r="7" />
      <path d="M10 9.5v4" />
      <path className="icon-fill" d="M9.2 6h1.6v1.6H9.2z" />
    </>
  ),
  restricted: (
    <>
      <path d="M5 9.5h10v7H5z" />
      <path d="M7.5 9.5v-3a2.5 2.5 0 0 1 5 0v3" />
    </>
  ),
  added: <path d="M10 4.5v11M4.5 10h11" />,
  removed: <path d="M4.5 10h11" />,
  changed: (
    <>
      <path d="M4 7h10.500l-2.5-2.5" />
      <path d="M16 13H5.5L8 15.5" />
    </>
  ),
  // What you can do.
  copy: (
    <>
      <path d="M7.5 7.5h9v9h-9z" />
      <path d="M12.5 7.5v-4h-9v9h4" />
    </>
  ),
  download: (
    <>
      <path d="M10 3v9.5" />
      <path d="M6 9l4 4 4-4" />
      <path d="M3.5 16.5h13" />
    </>
  ),
  star: <path d="M10 2.8l2.2 4.6 5 .7-3.6 3.5.9 5L10 14.200l-4.5 2.4.9-5L2.8 8.100l5-.7z" />,
  search: (
    <>
      <circle cx="8.5" cy="8.5" r="5" />
      <path d="M12.5 12.500l4.5 4.5" />
    </>
  ),
  filter: <path d="M3 4.5h14l-5.5 6.500v5.500l-3-1.500v-4z" />,
  sort: (
    <>
      <path d="M5 4v12" />
      <path d="M2.5 13.500L5 16l2.5-2.5" />
      <path d="M10.5 5.500h7M10.5 10h5M10.5 14.500h3" />
    </>
  ),
  terminal: (
    <>
      <path d="M2.5 4h15v12h-15z" />
      <path d="M5.5 8L8 10l-2.5 2" />
      <path d="M10 12.500h4" />
    </>
  ),
  git: (
    <>
      <path d="M6 6.750v6.5" />
      <path d="M14 8.750c0 3.5-8 1.5-8 4.5" />
      <circle cx="6" cy="5" r="1.75" />
      <circle cx="6" cy="15" r="1.75" />
      <circle cx="14" cy="7" r="1.75" />
    </>
  ),
  eye: (
    <>
      <circle cx="5.9" cy="10.5" r="3.6" />
      <circle cx="14.1" cy="10.5" r="3.6" />
      <path d="M9.5 9.8h1M2.3 9.6L1 9.2M17.7 9.6l1.3-.4" />
      <circle className="icon-fill" cx="5.9" cy="10.5" r="1.1" />
      <circle className="icon-fill" cx="14.1" cy="10.5" r="1.1" />
    </>
  ),
  clock: (
    <>
      <circle cx="10" cy="10" r="7" />
      <path d="M10 6v4.5l3 1.5" />
    </>
  ),
  // What a file is, on its tile.
  image: (
    <>
      <path d="M3 4h14v12H3z" />
      <path d="M3 13.500l4-4 3.5 3.5 2.5-2 4 3.5" />
      <circle className="icon-fill" cx="13" cy="7.5" r="1.2" />
    </>
  ),
  table: (
    <>
      <path d="M3 4h14v12H3z" />
      <path d="M3 8h14M3 12h14M8 4v12" />
    </>
  ),
  text: <path d="M4 5h12M4 8.500h12M4 12h12M4 15.500h7" />,
  sound: <path d="M3.5 8.500v3M6.75 6v8M10 3.500v13M13.25 7v6M16.5 5v10" />,
  video: (
    <>
      <path d="M3 4.500h14v11H3z" />
      <path className="icon-fill" d="M8.5 7.250v5.500l4.5-2.750z" />
    </>
  ),
  document: (
    <>
      <path d="M5.5 2.500h6L15 6v11.500H5.500z" />
      <path d="M11.5 2.500V6H15" />
      <path d="M7.5 10h5M7.5 13h5" />
    </>
  ),
  weights: (
    <>
      <path d="M10 2.500L16.5 6v8L10 17.5 3.5 14V6z" />
      <path d="M3.5 6L10 9.5 16.5 6" />
      <path d="M10 9.500v8" />
    </>
  ),
  file: (
    <>
      <path d="M5.5 2.500h6L15 6v11.500H5.500z" />
      <path d="M11.5 2.500V6H15" />
    </>
  ),
} satisfies Record<string, ReactNode>;

export type IconName = keyof typeof shapes;

/** One of cid's icons, drawn in the current text colour at the text's size
 * (1.25 em unless `size` says otherwise). Always decoration: say what it
 * means in words beside it, or name the control that holds it. */
export function Icon({ name, size, className }: { name: IconName; size?: number | string; className?: string }) {
  return (
    <svg
      className={className ? `icon ${className}` : 'icon'}
      viewBox="0 0 20 20"
      width={size ?? '1.25em'}
      height={size ?? '1.25em'}
      aria-hidden="true"
      focusable="false"
    >
      {shapes[name]}
    </svg>
  );
}
