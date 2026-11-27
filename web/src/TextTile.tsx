import { useQuery } from '@tanstack/react-query';
import { getText } from './api';
import { extOf } from './browseFilter';
import { TypeTile } from './TypeTile';

/** How much a tile reads: a few lines' worth, never the drawer's 64 KB. */
const glance_bytes = 2048;

/** A text file's tile: its first lines, as a page of it, with its type in
 * the corner. Until they come, or when they cannot (a restricted dataset,
 * not text after all), the plain type tile. */
export function TextTile({ name, hash, path, restricted }: { name: string; hash: string; path: string; restricted: boolean }) {
  const head = useQuery({
    queryKey: ['text', name, hash, glance_bytes],
    queryFn: () => getText(name, hash, glance_bytes),
    enabled: !restricted,
    staleTime: Infinity,
  });
  const text = head.data && !head.data.withheld && !head.data.binary ? head.data.text : null;
  if (text === null || text.trim() === '') return <TypeTile path={path} />;
  return (
    <span className="tile-text">
      <span className="tile-text-lines data">{text.split('\n').slice(0, 12).join('\n')}</span>
      <span className="tile-text-type data">{extOf(path)}</span>
    </span>
  );
}
