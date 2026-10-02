import { useState } from 'react';
import { useInfiniteQuery } from '@tanstack/react-query';
import { getDir, getDownloads } from '../api';
import { humanBytes } from '../format';

// Files: the folder tree exactly as committed, sizes and types, a
// download per file. The open folder path lives in the URL. One folder at
// a time, from the server (DuckDB over the version's index): subfolders
// with their counts, then the folder's own files a page at a time.
export function FilesTab({
  name,
  commit,
  openDir,
  onOpenDir,
}: {
  name: string;
  commit: string | null;
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

      <table className="browse-table">
        <thead>
          <tr>
            <th>name</th>
            <th>size</th>
            <th></th>
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
              <td className="data">{humanBytes(f.bytes)}</td>
              <td></td>
            </tr>
          ))}
          {files.map((item) => (
            <tr key={item.path}>
              <td className="data">{item.path.slice(prefix.length)}</td>
              <td className="data">{humanBytes(item.size)}</td>
              <td>
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
      className="crumb"
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
