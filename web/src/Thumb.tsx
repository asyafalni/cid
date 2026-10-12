import { useState, type ReactNode } from 'react';

// A preview image that fails on its own (docs/dashboard.md, principle 1):
// when the picture cannot be had (gone from storage, purged, a lost
// connection), the item still shows as itself, its type and a plain "no
// preview", never the browser's broken-image icon. Whatever is drawn over
// the picture (annotation overlays) is dropped with it.
export function Thumb({
  src,
  alt,
  label,
  className,
  lazy = false,
  children,
}: {
  src: string | undefined;
  alt: string;
  /** What the item is when its picture is missing: its file type. */
  label: string;
  className?: string;
  lazy?: boolean;
  children?: ReactNode;
}) {
  const [failed, setFailed] = useState<string | null>(null);
  if (src !== undefined && failed === src) {
    return (
      <span className={className ? `thumb-missing ${className}` : 'thumb-missing'} role="img" aria-label={`${alt}: no preview`}>
        <span className="thumb-missing-type data">{label}</span>
        <span className="thumb-missing-note">no preview</span>
      </span>
    );
  }
  return (
    <>
      <img className={className} src={src} alt={alt} loading={lazy ? 'lazy' : undefined} onError={() => setFailed(src ?? null)} />
      {children}
    </>
  );
}
