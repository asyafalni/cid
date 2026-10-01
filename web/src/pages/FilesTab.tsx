import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { getDownloads, getState, type StateItem } from '../api';
import { humanBytes } from '../format';

// Files: the folder tree exactly as committed, sizes and types, a
// download per file. The open folder path lives in the URL.
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
  const state = useQuery({
    queryKey: ['state', name, commit],
    queryFn: () => getState(name, commit!),
    enabled: commit !== null,
  });

  if (commit === null) return <p className="quiet">Nothing here until the first push.</p>;
  if (state.isPending) return <p className="quiet">Reading the manifest…</p>;
  if (state.isError)
    return (
      <div className="panel notice" role="alert">
        <p>Could not read this version. Run the link again, or pick another release.</p>
      </div>
    );

  const prefix = openDir ? `${openDir}/` : '';
  const here = state.data.items.filter((i) => i.path.startsWith(prefix));
  const dirs = new Map<string, { count: number; bytes: number }>();
  const files: StateItem[] = [];
  for (const item of here) {
    const rest = item.path.slice(prefix.length);
    const slash = rest.indexOf('/');
    if (slash === -1) {
      files.push(item);
    } else {
      const dir = rest.slice(0, slash);
      const agg = dirs.get(dir) ?? { count: 0, bytes: 0 };
      agg.count += 1;
      agg.bytes += item.size;
      dirs.set(dir, agg);
    }
  }

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
          {[...dirs.entries()].sort().map(([dir, agg]) => (
            <tr key={dir} onClick={() => onOpenDir(prefix + dir)}>
              <td>
                <span className="data">{dir}/</span>{' '}
                <span className="quiet">
                  {agg.count} {agg.count === 1 ? 'file' : 'files'}
                </span>
              </td>
              <td className="data">{humanBytes(agg.bytes)}</td>
              <td></td>
            </tr>
          ))}
          {files
            .sort((x, y) => (x.path < y.path ? -1 : 1))
            .map((item) => (
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
      {dirs.size === 0 && files.length === 0 && (
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
