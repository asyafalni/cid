// The dashboard talks only to the cid server (docs/dashboard.md): same
// JSON as `cid --json`. Dev sign-in is a pasted token; the GitLab OAuth
// slice replaces this screen, not this client.

export type DatasetSummary = {
  name: string;
  kind: 'files' | 'annotated';
  default_format: string;
  latest_release: string | null;
  last_push: string | null; // ISO date or null
};

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

export function getState(
  name: string,
  commit: string,
): Promise<{ commit: string; items: StateItem[]; annotations?: StateAnnotation[] }> {
  return request(`/v0/datasets/${name}/-/state/${commit}`);
}

export function getThumbs(
  name: string,
  hashes: string[],
): Promise<{ thumbs: { hash: string; url: string }[] }> {
  return post(`/v0/datasets/${name}/-/thumbs`, { hashes });
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
