import { useEffect, useRef, useState, type ReactNode } from 'react';

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

// A video's poster that plays its short clip (made by the preview worker:
// its first seconds, silent) while its tile is pointed at or focused, and
// stops when it is not. The clip is not fetched before then, and never
// plays for someone who asked for reduced motion.
export function ClipThumb({ src, clip, alt, label }: { src: string | undefined; clip: string; alt: string; label: string }) {
  const box = useRef<HTMLSpanElement>(null);
  const [playing, setPlaying] = useState(false);
  useEffect(() => {
    const tile = box.current?.closest('button, a');
    if (!tile) return;
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return;
    const on = () => setPlaying(true);
    const off = () => setPlaying(false);
    tile.addEventListener('mouseenter', on);
    tile.addEventListener('mouseleave', off);
    tile.addEventListener('focusin', on);
    tile.addEventListener('focusout', off);
    return () => {
      tile.removeEventListener('mouseenter', on);
      tile.removeEventListener('mouseleave', off);
      tile.removeEventListener('focusin', on);
      tile.removeEventListener('focusout', off);
    };
  }, []);
  return (
    <span ref={box} className="clip-thumb">
      <Thumb src={src} alt={alt} label={label} lazy />
      {playing && (
        <video className="clip-thumb-video" src={clip} poster={src} muted loop autoPlay playsInline aria-hidden="true" />
      )}
    </span>
  );
}
