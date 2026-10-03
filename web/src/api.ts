// The dashboard talks only to the cid server (docs/dashboard.md lists the
// routes it calls). People sign in with GitLab; the server token can be
// pasted too (development, the e2e suite).

export type DatasetSummary = {
  name: string;
  kind: 'files' | 'annotated';
  restricted: boolean;
  default_format: string;
  latest_release: string | null;
  last_push: string | null; // ISO date or null
  /** At the head of main, from the commit's cached stats. */
  items: number;
  bytes: number;
  types: { ext: string; count: number }[];
  classes: string[];
  /** Finished previews only; empty for a restricted dataset. */
  mosaic: { hash: string; url: string }[];
  /** Starred by the signed-in person (always false for the server token). */
  starred: boolean;
  /** Display names of the dataset's owners (Maintainers). */
  owners: string[];
};

export async function setStar(name: string, on: boolean): Promise<void> {
  const res = await fetch(`/v0/datasets/${name}/-/star`, { method: on ? 'PUT' : 'DELETE' });
  if (!res.ok) throw new ApiError(res.status, `the server answered ${res.status}`, null);
}

const tokenKey = 'cid-token';

export function getToken(): string | null {
  return sessionStorage.getItem(tokenKey);
}

export function setToken(token: string) {
  sessionStorage.setItem(tokenKey, token);
}

export function clearToken() {
  sessionStorage.removeItem(tokenKey);
}

export class ApiError extends Error {
  status: number;
  next: string | null;
  constructor(status: number, message: string, next: string | null) {
    super(message);
    this.status = status;
    this.next = next;
  }
}

async function request<T>(path: string): Promise<T> {
  const token = getToken();
  const res = await fetch(path, {
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
  if (!res.ok) {
    let message = `the server answered ${res.status}`;
    let next: string | null = null;
    try {
      const body = (await res.json()) as { error?: string; next?: string };
      if (body.error) message = body.error;
      if (body.next) next = body.next;
    } catch {
      // not JSON: keep the status message
    }
    throw new ApiError(res.status, message, next);
  }
  return (await res.json()) as T;
}

export type TapeCommit = {
  id: string;
  message: string;
  author: string;
  at_ms: number;
  release: string | null;
};

export type Overview = {
  name: string;
  kind: 'files' | 'annotated';
  restricted: boolean;
  git_url: string;
  default_format: string;
  commits: TapeCommit[]; // newest first
  items: number;
  bytes: number;
  classes: { name: string; count: number }[];
  splits: { name: string; count: number }[];
};

export function getOverview(name: string): Promise<Overview> {
  return request(`/v0/datasets/${name}/-/overview`);
}

export function listDatasets(): Promise<{ datasets: DatasetSummary[] }> {
  return request('/v0/datasets');
}

export type StateItem = {
  path: string;
  hash: string;
  size: number;
  split: string | null;
  item_id: string | null;
  width: number | null;
  height: number | null;
};

export type StateAnnotation = {
  id: string;
  item_id: string;
  kind: string | null;
  class: string | null;
  geometry: unknown;
  attrs: unknown;
  author: string;
  policy_ver: string;
};


/** An item as browse answers it: the state item and its annotations at
 * that version. */
export type BrowseItem = StateItem & { annotations: StateAnnotation[] };

export type BrowseFacet = { value: string; count: number };

export type BrowsePage = {
  total: number;
  matched: number;
  items: BrowseItem[];
  /** The cursor for the next page; null on the last. */
  next: string | null;
  open: BrowseItem | null;
  facets: { split: BrowseFacet[]; class: BrowseFacet[]; type: BrowseFacet[] };
  /** Annotations per class across the whole version. */
  classes: BrowseFacet[];
};

export type BrowseQuery = {
  q?: string;
  split?: string;
  cls?: string;
  type?: string;
  after?: string;
  item?: string;
  limit?: number;
};

/** One page of a version, filtered on the server (docs/dashboard.md,
 * Browse API). An empty split or class is a value ("none"), so only an
 * absent filter is left out of the URL. */
export function getBrowse(name: string, commit: string, query: BrowseQuery): Promise<BrowsePage> {
  const params = new URLSearchParams({ commit });
  if (query.q) params.set('q', query.q);
  if (query.split !== undefined) params.set('split', query.split);
  if (query.cls !== undefined) params.set('class', query.cls);
  if (query.type !== undefined) params.set('type', query.type);
  if (query.after !== undefined) params.set('after', query.after);
  if (query.item !== undefined) params.set('item', query.item);
  if (query.limit !== undefined) params.set('limit', String(query.limit));
  // The server decodes %XX only: spaces must not travel as '+'.
  return request(`/v0/datasets/${name}/-/browse?${params.toString().replace(/\+/g, '%20')}`);
}

/** How much a `cid clone --split … --class …` would take. */
export type SubsetSize = { items: number; bytes: number; total: number };

export function getSubsetSize(
  name: string,
  commit: string,
  splits: string[],
  classes: string[],
): Promise<SubsetSize> {
  const params = new URLSearchParams({ commit });
  for (const v of splits) params.append('split', v);
  for (const v of classes) params.append('class', v);
  return request(`/v0/datasets/${name}/-/browse/size?${params.toString().replace(/\+/g, '%20')}`);
}

/** One folder of a version: subfolders counted, files a page at a time. */
export type DirListing = {
  folders: { name: string; items: number; bytes: number }[];
  folders_total: number;
  files: { path: string; size: number; hash: string }[];
  files_total: number;
  next: string | null;
};

export function getDir(name: string, commit: string, prefix: string, after?: string): Promise<DirListing> {
  const params = new URLSearchParams({ commit, prefix });
  if (after !== undefined) params.set('after', after);
  return request(`/v0/datasets/${name}/-/browse/dir?${params.toString().replace(/\+/g, '%20')}`);
}

export type CompareSide = {
  path: string;
  hash: string;
  item_id: string | null;
  width: number | null;
  height: number | null;
};

/** Two versions compared on the server (DuckDB over their indexes): the
 * summary, a page of item changes, and on the first page the visual diff
 * and the first annotation changes. */
export type ComparePage = {
  summary: {
    added: number;
    modified: number;
    deleted: number;
    ann_added: number;
    ann_changed: number;
    ann_removed: number;
  };
  changes: {
    change: 'added' | 'modified' | 'deleted';
    path: string;
    hash_a: string | null;
    hash_b: string | null;
    size_b: number | null;
  }[];
  next: string | null;
  visual: {
    path: string;
    before: CompareSide | null;
    after: CompareSide | null;
    shapes_before: StateAnnotation[];
    shapes_after: StateAnnotation[];
  }[];
  ann_changes: { change: 'added' | 'changed' | 'removed'; kind: string | null; class: string | null; item_path: string | null }[];
};

export function getCompare(name: string, a: string, b: string, after?: string): Promise<ComparePage> {
  const params = new URLSearchParams({ a, b });
  if (after !== undefined) params.set('after', after);
  return request(`/v0/datasets/${name}/-/browse/compare?${params.toString().replace(/\+/g, '%20')}`);
}

export function getThumbs(
  name: string,
  hashes: string[],
): Promise<{ thumbs: { hash: string; url: string }[] }> {
  return post(`/v0/datasets/${name}/-/thumbs`, { hashes });
}

export type ItemHistory = {
  path: string;
  changes: {
    at: string;
    branch: string;
    op: 'add' | 'update' | 'delete';
    hash: string | null;
    author: string;
    commit: string | null;
    message: string | null;
    release: string | null;
  }[];
  annotations: {
    at: string;
    branch: string;
    annotation_id: string;
    op: 'create' | 'update' | 'delete';
    kind: string | null;
    class: string | null;
    geometry: unknown;
    author: string;
    policy_ver: string;
    commit: string | null;
    release: string | null;
  }[];
};

export function getHistory(name: string, path: string): Promise<ItemHistory> {
  return request(`/v0/datasets/${name}/-/history?path=${encodeURIComponent(path)}`);
}

export type TableStats = {
  rows: number;
  columns: {
    name: string;
    type: string;
    min?: string | null;
    max?: string | null;
    distinct?: number;
    null_percent?: number;
  }[];
  sample: Record<string, unknown>[];
};

export type TableAnswer = {
  status: 'done' | 'pending' | 'building' | 'skipped' | 'failed';
  reason?: string | null;
  stats?: TableStats;
  /** Restricted: the shape only, until a logged reveal. */
  withheld?: boolean;
};

export function getTable(name: string, hash: string): Promise<TableAnswer> {
  return request(`/v0/datasets/${name}/-/table?hash=${hash}`);
}

export type RowDiff = {
  rows_a: number;
  rows_b: number;
  columns_a: string[];
  columns_b: string[];
  columns_changed: boolean;
  added?: number;
  removed?: number;
  added_sample?: Record<string, unknown>[];
  removed_sample?: Record<string, unknown>[];
};

export type RowDiffAnswer = {
  status: 'done' | 'unreadable' | 'too_large' | 'not_a_table' | 'needs_server_build';
  reason?: string | null;
  diff?: RowDiff | null;
  /** Restricted: counts and columns only; rows are content. */
  withheld?: boolean;
};

/** Rows added and removed between two contents of a table file; the
 * server computes it once, ever, and keeps it. */
export function getRowDiff(name: string, path: string, a: string, b: string): Promise<RowDiffAnswer> {
  return post(`/v0/datasets/${name}/-/rowdiff`, { a, b, path_a: path, path_b: path });
}

/** The opening of a text item (first 64 KB), for the drawer. */
export type TextHead = {
  text: string | null;
  truncated: boolean;
  /** Not text after all: a NUL or broken UTF-8 in what was read. */
  binary: boolean;
  size: number;
  /** Restricted: shown only after a logged reveal. */
  withheld?: boolean;
};

export function getText(name: string, hash: string): Promise<TextHead> {
  return request(`/v0/datasets/${name}/-/text?hash=${hash}`);
}

export type Revealed = {
  hash: string;
  thumb: string | null;
  download: string;
  table: TableStats | null;
  text: TextHead | null;
  logged: boolean;
};

/** The one way to a clear restricted preview: logged on the server first. */
export function reveal(name: string, hash: string): Promise<Revealed> {
  return post(`/v0/datasets/${name}/-/reveal`, { hash });
}

export type ActivityEvent = {
  at: string;
  account_id: string;
  display_name: string | null;
  action: string;
  ref: string | null;
  detail: string | null;
};

export function getActivity(name: string): Promise<{ events: ActivityEvent[] }> {
  return request(`/v0/datasets/${name}/-/activity`);
}

export function getDownloads(
  name: string,
  hashes: string[],
): Promise<{ downloads: { hash: string; url: string }[] }> {
  return post(`/v0/datasets/${name}/-/downloads`, { hashes });
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const token = getToken();
  const res = await fetch(path, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new ApiError(res.status, `the server answered ${res.status}`, null);
  return (await res.json()) as T;
}

export function ping(): Promise<{ ok: boolean }> {
  return request('/v0/ping');
}

export type Me = {
  via: 'gitlab' | 'token';
  account: string | null;
  display_name: string;
};

/** Who the dashboard is signed in as: a GitLab session (cookie, sent by
 *  the browser on its own) or a pasted server token. 401 when neither. */
export function getMe(): Promise<Me> {
  return request('/v0/me');
}

export function getAuthConfig(): Promise<{ gitlab: boolean }> {
  return request('/v0/auth/config');
}

export type SshKey = {
  fingerprint: string;
  title: string;
  key_type: string;
  /** gitlab: synced from GitLab, removed there; dashboard: added here,
   *  removed here; admin: registered by an administrator. */
  source: 'gitlab' | 'dashboard' | 'admin';
  added_at: string;
};

/** The signed-in person's SSH keys, the identity the CLI signs in with. */
export function listKeys(): Promise<{ keys: SshKey[] }> {
  return request('/v0/me/keys');
}

async function send<T>(path: string, method: string, body?: unknown): Promise<T> {
  const res = await fetch(path, {
    method,
    headers: body === undefined ? {} : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const parsed = (await res.json().catch(() => ({}))) as T & { error?: string; next?: string };
  if (!res.ok) throw new ApiError(res.status, parsed.error ?? `the server answered ${res.status}`, parsed.next ?? null);
  return parsed;
}

export function addKey(title: string, key: string): Promise<{ fingerprint: string; keys: SshKey[] }> {
  return send('/v0/me/keys', 'POST', { title, key });
}

export function removeKey(fingerprint: string): Promise<{ keys: SshKey[] }> {
  return send(`/v0/me/keys?fingerprint=${encodeURIComponent(fingerprint)}`, 'DELETE');
}

export type PersonalToken = {
  id: string;
  name: string;
  /** Its first characters, to recognise it by; the token itself is shown once. */
  prefix: string;
  created_at: string;
  expires_at: string;
  /** By the server's clock. */
  expired: boolean;
  last_used_at: string | null;
};

/** The signed-in person's personal tokens, for scripts and CI. */
export function listTokens(): Promise<{ tokens: PersonalToken[] }> {
  return request('/v0/me/tokens');
}

export function makeToken(name: string, days: number): Promise<{ id: string; token: string; tokens: PersonalToken[] }> {
  return send('/v0/me/tokens', 'POST', { name, days });
}

export function revokeToken(id: string): Promise<{ tokens: PersonalToken[] }> {
  return send(`/v0/me/tokens?id=${encodeURIComponent(id)}`, 'DELETE');
}
