import { useState } from 'react';
import { useInfiniteQuery, useQueries } from '@tanstack/react-query';
import { Link } from '@tanstack/react-router';
import { getDir, getDownloads, getLastChange, type LastChange } from '../api';
import { extOf } from '../browseFilter';
import { humanBytes } from '../format';

// Files: the folder tree exactly as committed, sizes and types, a
// download per file. The open folder path lives in the URL. One folder at
// a time, from the server (DuckDB over the version's index): subfolders
// with their counts, then the folder's own files a page at a time.
export function FilesTab({
  name,
  commit,
  release,
  openDir,
  onOpenDir,
}: {
  name: string;
  commit: string | null;
  /** The release in the URL, kept on links into Browse. */
  release: string | undefined;
  openDir: string | undefined;
  onOpenDir: (dir: string | undefined) => void;
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

  if (commit === null) return <p className="quiet">Nothing here until the first push.</p>;
  if (listing.isPending) return <p className="quiet">Reading the manifest…</p>;
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
            <th>Type</th>
            <th>Last change</th>
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
                <span className="data">{f.name}/</span>{' '}
                <span className="quiet">
                  {f.items.toLocaleString()} {f.items === 1 ? 'file' : 'files'}
                </span>
              </td>
              <td className="quiet">folder</td>
              <td></td>
              <td className="data num">{humanBytes(f.bytes)}</td>
              <td></td>
            </tr>
          ))}
          {files.map((item) => (
            <tr key={item.path}>
              <td className="data">
                {/* The file as itself: its preview, facts and history, in Browse's drawer. */}
                <Link to="/d/$" params={{ _splat: name }} search={{ view: 'browse', release, item: item.path }}>
                  {item.path.slice(prefix.length)}
                </Link>
              </td>
              <td className="data">{extOf(item.path)}</td>
              <td className="quiet files-changed">
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
