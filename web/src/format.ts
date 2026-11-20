// A git URL as its web page, host and path: git@host:path.git,
// ssh://git@host:22/path.git and https://user@host/path.git all become
// https://host/path. Null for anything else (a local path, file://).
// Credentials never survive into a link.
function gitWeb(gitUrl: string): { host: string; url: string } | null {
  const scp = gitUrl.match(/^[^@/\s]+@([^:/\s]+):(?!\/)(.+?)(\.git)?\/?$/);
  if (scp) return { host: scp[1].toLowerCase(), url: `https://${scp[1]}/${scp[2]}` };
  const full = gitUrl.match(/^(?:ssh|https?|git):\/\/(?:[^@/]*@)?([^:/\s]+)(?::\d+)?\/(.+?)(\.git)?\/?$/);
  if (full) return { host: full[1].toLowerCase(), url: `https://${full[1]}/${full[2]}` };
  return null;
}

export function gitWebUrl(gitUrl: string): string {
  // A convenience, not a promise: the repository's page where one can be told.
  return gitWeb(gitUrl)?.url ?? gitUrl;
}

/** A release's tag on the repository's web page, where the host's URL form is
 * known (GitLab, GitHub); null elsewhere, rather than a guess that 404s. */
export function gitTagUrl(gitUrl: string, tag: string): string | null {
  const web = gitWeb(gitUrl);
  if (!web) return null;
  const name = encodeURIComponent(tag);
  if (web.host === 'gitlab.com' || web.host.startsWith('gitlab.')) return `${web.url}/-/tags/${name}`;
  if (web.host === 'github.com') return `${web.url}/tree/${name}`;
  return null;
}

export function humanBytes(n: number): string {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = n;
  let u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u += 1;
  }
  return u === 0 ? `${n} B` : `${v.toFixed(1)} ${units[u]}`;
}
