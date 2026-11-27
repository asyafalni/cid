import { extOf } from './browseFilter';
import { Icon, type IconName } from './icons';

/** The icon for a file of this type (an extension as `extOf` gives it). */
function typeIcon(ext: string): IconName {
  const e = ext.toLowerCase();
  if (/^\.(png|jpe?g|webp|gif|bmp|tiff?|svg)$/.test(e)) return 'image';
  if (/^\.(csv|tsv|parquet|jsonl|xlsx?)$/.test(e)) return 'table';
  if (/^\.(txt|md|json|ya?ml|xml|log|ini|toml|html?|srt|vtt)$/.test(e)) return 'text';
  if (/^\.(wav|mp3|flac|ogg|m4a|opus|aac)$/.test(e)) return 'sound';
  if (/^\.(mp4|mov|mkv|webm|avi)$/.test(e)) return 'video';
  if (/^\.(pdf|docx?|pptx?)$/.test(e)) return 'document';
  if (/^\.(bin|safetensors|pt|pth|onnx|gguf|ckpt|h5|npy|npz|pkl)$/.test(e)) return 'weights';
  return 'file';
}

/** A file with no preview, as itself: what kind of file it is, drawn, and
 * its type in words. Never a blank square (docs/dashboard.md, principles). */
export function TypeTile({ path }: { path: string }) {
  const ext = extOf(path);
  return (
    <span className="tile-type data">
      <Icon name={typeIcon(ext)} />
      {ext}
    </span>
  );
}

/** The same drawing alone, for a card's mosaic of types. */
export function TypeIcon({ ext, className }: { ext: string; className?: string }) {
  return <Icon name={typeIcon(ext)} size="1.75rem" className={className} />;
}
