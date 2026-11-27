// An engineer's goggles that spell the name, for the sign-in page (the
// airship is cid's logo and favicon; this is its second drawing). The left lens is
// the c, the bridge with its rivet the i, the right lens and its stem the
// d; the lenses hold the sky at dusk. Our own drawing (CLAUDE.md, the name
// and brand rule). The rims are one brass and the lenses keep the
// dusk in both themes, as a lens keeps what it looks at.
export function Goggles({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 96 48" fill="none" aria-hidden="true" focusable="false">
      <defs>
        <linearGradient id="goggles-sky" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#1b2a5a" />
          <stop offset=".55" stopColor="#6b4e8c" />
          <stop offset="1" stopColor="#e08a5b" />
        </linearGradient>
      </defs>
      <path d="M1.5 28h5M89 28h5.5" stroke="var(--text-muted)" strokeWidth="3" strokeLinecap="round" />
      <circle cx="21" cy="28" r="10.5" fill="url(#goggles-sky)" />
      <circle cx="69" cy="28" r="10.5" fill="url(#goggles-sky)" />
      <path d="M14.5 25a7.5 7.5 0 0 1 6.5-4.5M62.5 25a7.5 7.5 0 0 1 6.5-4.5" stroke="#fff" strokeOpacity=".75" strokeWidth="1.6" strokeLinecap="round" />
      <g stroke="#cf9a30" strokeWidth="4.6" strokeLinecap="round">
        <path d="M31.4 20.5A13 13 0 1 0 31.4 35.5" />
        <path d="M45 19v22" />
        <circle cx="69" cy="28" r="13" />
        <path d="M82 5v36" />
      </g>
      <circle cx="45" cy="8.5" r="3.2" fill="var(--aether)" />
    </svg>
  );
}
