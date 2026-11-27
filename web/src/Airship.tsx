// cid's own airship, a line drawing (docs/dashboard.md §3.2: illustrations
// are original). It flies over the home's sky and keeps empty states and
// the 404 company. Stroked in the current colour; the envelope band wears
// brass. Decorative: always hidden from assistive technology.
export function Airship({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 240 132" aria-hidden="true" focusable="false">
      <g fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="square" strokeLinejoin="round">
        {/* envelope, its seams and nose */}
        <path d="M30 50c0-17 36-30 80-30s80 13 80 30-36 30-80 30-80-13-80-30z" />
        <path d="M34 41c22-6 47-9 76-9s54 3 76 9M34 59c22 6 47 9 76 9s54-3 76-9" opacity="0.55" />
        <path d="M70 22.5v55M110 20v60M150 22.5v55" opacity="0.35" />
        {/* tail fins */}
        <path d="M182 36l28-16-4 30 4 30-28-16" />
        <path d="M188 50h18" opacity="0.55" />
        {/* rigging and gondola */}
        <path d="M78 77l12 21M142 77l-12 21M110 80v18" opacity="0.7" />
        <path d="M82 98h56l-8 18H90z" />
        <path d="M96 103h6v6h-6zM107 103h6v6h-6zM118 103h6v6h-6z" />
        {/* propeller */}
        <path d="M138 107h12" />
        <path d="M152 97v20" />
      </g>
      <path d="M108 20.1c1.3 0 2.7 0 4 0v59.8c-1.3 0-2.7 0-4 0z" fill="var(--brass)" opacity="0.85" />
    </svg>
  );
}

// The same airship drawn for small sizes: cid's logo in the top bar, the
// shape the favicon draws in pixels. Fewer, heavier lines, so it holds at
// 24 px: the envelope with its brass band, the fins, the gondola.
export function AirshipMark({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 40 28" aria-hidden="true" focusable="false">
      <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <ellipse cx="17" cy="10" rx="14" ry="7.5" />
        <path d="M30 7l7-4-1.5 7 1.5 7-7-4" />
        <path d="M12 17l2 4M22 17l-2 4" />
        <path d="M11 21h12l-2 5h-8z" />
      </g>
      <path d="M15.5 2.6h3v14.8h-3z" fill="var(--brass)" />
    </svg>
  );
}
