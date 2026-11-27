import { useEffect, useState } from 'react';
import { useInfiniteQuery, useQueries, useQuery } from '@tanstack/react-query';
import { Link } from '@tanstack/react-router';
import { getBrowse, getDir, getDownloads, getLastChange, type LastChange, type Pin } from '../api';
import { extOf } from '../browseFilter';
import { RowsSkeleton } from '../Skeleton';
import { humanBytes } from '../format';
import { typingIn } from '../keys';
import { thumbsFor } from '../thumbs';
import { ItemDrawer, MissingItem } from './BrowseTab';
import { Icon } from '../icons';

const noneHidden: ReadonlySet<string> = new Set();

// Files: the folder tree exactly as committed, sizes and types, a
// download per file. The open folder path lives in the URL. One folder at
// a time, from the server (DuckDB over the version's index): subfolders
// with their counts, then the folder's own files a page at a time. A
// file's name opens it beside the listing, in the same drawer Browse uses
// (its preview, facts and history), the open file in the URL too.
export function FilesTab({
  name,
  commit,
  pin,
  annotated,
  restricted,
  openDir,
  onOpenDir,
  openItem,
  onOpenItem,
}: {
  name: string;
  commit: string | null;
  /** What the page is pinned to, kept on links into Browse. */
  pin: Pin;
  annotated: boolean;
  restricted: boolean;
  openDir: string | undefined;
  onOpenDir: (dir: string | undefined) => void;
  openItem: string | undefined;
  onOpenItem: (path: string | undefined) => void;
}) {
  const prefix = openDir ? `${openDir}/` : '';
  const listing = useInfiniteQuery({
    queryKey: ['dir', name, commit, prefix],
    queryFn: ({ pageParam }) => getDir(name, commit!, prefix, pageParam),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last) => last.next ?? undefined,
    enabled: commit !== null,
  });

  // When each file last changed, and by whom: asked per page once the
  // page is there, so the listing never waits on history. A page whose
  // answer has not come (or cannot) shows its files all the same.
  const changedPages = useQueries({
    queries: (listing.data?.pages ?? []).map((p, i) => ({
      queryKey: ['last-change', name, commit, prefix, i],
      queryFn: () => getLastChange(name, commit!, p.files.map((f) => f.path)),
      enabled: commit !== null && p.files.length > 0,
      staleTime: Infinity,
    })),
  });
  const changed = new Map<string, LastChange>();
  for (const q of changedPages) for (const c of q.data?.changes ?? []) changed.set(c.path, c);

  // The open file, with its annotations and thumbnail, as Browse asks for
  // an item opened from a link: one lean query, no counts or facets.
  const opened = useQuery({
    queryKey: ['browse-open', name, commit, openItem],
    queryFn: async () => {
      const page = await getBrowse(name, commit!, { item: openItem, limit: 1, facets: false });
      return page.open ? { item: page.open, thumbs: await thumbsFor(name, [page.open]) } : null;
    },
    enabled: commit !== null && openItem !== undefined,
  });
  // Escape closes it, as in Browse (never while typing).
  useEffect(() => {
    if (openItem === undefined) return;
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape' && !typingIn(e)) onOpenItem(undefined);
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [openItem, onOpenItem]);

  if (commit === null) return <p className="quiet">Nothing here until the first push.</p>;
  if (listing.isPending) return <RowsSkeleton rows={8} cols={4} />;
  if (listing.isError)
    return (
      <div className="panel notice" role="alert">
        <p>Could not read this version. Run the link again, or pick another release.</p>
      </div>
    );

  const first = listing.data.pages[0];
  const folders = first.folders;
  const files = listing.data.pages.flatMap((p) => p.files);
  const crumbs = openDir ? openDir.split('/') : [];

  return (
    <div className="files">
      <nav className="crumbs" aria-label="Folder path">
        <button className="crumb" onClick={() => onOpenDir(undefined)}>
          {name.split('/').pop()}
        </button>
        {crumbs.map((part, i) => (
          <span key={i}>
            <span aria-hidden="true" className="quiet">
              /
            </span>
            <button
              className="crumb"
              onClick={() => onOpenDir(crumbs.slice(0, i + 1).join('/'))}
            >
              {part}
            </button>
          </span>
        ))}
      </nav>

      <table className="browse-table files-table">
        <thead>
          <tr>
            <th>Name</th>
            <th className="col-wide">Type</th>
            <th className="col-wide">Last change</th>
            <th className="num">Size</th>
            <th>
              <span className="visually-hidden">Download</span>
            </th>
          </tr>
        </thead>
        <tbody>
          {folders.map((f) => (
            <tr key={f.name} onClick={() => onOpenDir(prefix + f.name)}>
              <td>
                <Icon name="folder" /> <span className="data">{f.name}/</span>{' '}
                <span className="quiet">
                  {f.items.toLocaleString()} {f.items === 1 ? 'file' : 'files'}
                </span>
              </td>
              <td className="quiet col-wide">folder</td>
              <td className="col-wide"></td>
              <td className="data num">{humanBytes(f.bytes)}</td>
              <td></td>
            </tr>
          ))}
          {files.map((item) => (
            <tr key={item.path} className={openItem === item.path ? 'row--open' : undefined}>
              <td className="data">
                {/* The file as itself, beside the listing: a link, so it can be shared. */}
                <Link
                  to="/d/$"
                  params={{ _splat: name }}
                  search={{ view: 'files', ...pin, dir: openDir, item: item.path }}
                  aria-current={openItem === item.path ? 'true' : undefined}
                >
                  {item.path.slice(prefix.length)}
                </Link>
              </td>
              <td className="data col-wide">{extOf(item.path)}</td>
              <td className="quiet files-changed col-wide">
                {changed.has(item.path) && (
                  <>
                    <span className="data">{new Date(changed.get(item.path)!.at_ms).toISOString().slice(0, 10)}</span>
                    {' · '}
                    {changed.get(item.path)!.author}
                  </>
                )}
              </td>
              <td className="data num">{humanBytes(item.size)}</td>
              <td className="files-action">
                <DownloadLink name={name} hash={item.hash} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {first.folders_total > folders.length && (
        <p className="quiet">
          {(first.folders_total - folders.length).toLocaleString()} more folders are not listed; open a deeper folder,
          or use Browse to search by path.
        </p>
      )}
      {listing.hasNextPage && (
        <button
          className="filter-clear more-items"
          disabled={listing.isFetchingNextPage}
          onClick={() => void listing.fetchNextPage()}
        >
          {listing.isFetchingNextPage
            ? 'Loading more…'
            : `Show more files (${files.length.toLocaleString()} of ${first.files_total.toLocaleString()} shown)`}
        </button>
      )}
      {folders.length === 0 && files.length === 0 && (
        <p className="quiet">This folder is empty at this version.</p>
      )}
      {openItem !== undefined && opened.data === null && (
        <MissingItem name={name} path={openItem} onClose={() => onOpenItem(undefined)} />
      )}
      {openItem !== undefined && opened.data && (
        <ItemDrawer
          name={name}
          item={opened.data.item}
          annotated={annotated}
          restricted={restricted}
          annotations={opened.data.item.annotations}
          thumb={opened.data.thumbs.find((t) => t.hash === opened.data!.item.hash)?.url}
          hidden={noneHidden}
          opacity={0.9}
          onClose={() => onOpenItem(undefined)}
        >
          {/* Onward to step through items, filter, or show and hide classes. */}
          <Link className="action drawer-download" to="/d/$" params={{ _splat: name }} search={{ view: 'browse', ...pin, item: openItem }}>
            Open in Browse
          </Link>
        </ItemDrawer>
      )}
    </div>
  );
}

function DownloadLink({ name, hash }: { name: string; hash: string }) {
  const [url, setUrl] = useState<string | null>(null);
  if (url) {
    return (
      <a href={url} download onClick={(e) => e.stopPropagation()}>
        save
      </a>
    );
  }
  return (
    <button
      className="file-download"
      onClick={(e) => {
        e.stopPropagation();
        void getDownloads(name, [hash]).then((d) => {
          const got = d.downloads[0]?.url;
          if (got) setUrl(got);
        });
      }}
    >
      download
    </button>
  );
}
