import { getThumbs, type StateItem } from './api';

/** Thumbnails for a page's visual items. Previews are optional: when they
 * cannot be had, the items show as type tiles, never as an error. */
export async function thumbsFor(name: string, items: StateItem[]): Promise<{ hash: string; url: string }[]> {
  const hashes = items.filter((i) => looksVisual(i.path)).map((i) => i.hash);
  if (hashes.length === 0) return [];
  try {
    return (await getThumbs(name, hashes)).thumbs;
  } catch {
    return [];
  }
}

// Items that get a thumbnail: pictures, video posters, audio waveforms.
export function looksVisual(path: string): boolean {
  return /\.(png|jpe?g|gif|webp|bmp|mp4|mov|mkv|webm|avi|wav|mp3|flac|ogg|oga|m4a)$/i.test(path);
}
