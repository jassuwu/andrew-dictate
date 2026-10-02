// GET /api/latest?version=0.9.4 → {"latest":"0.9.5"}
//
// the app's daily update check asks this, and nothing else does. the app
// sends the version it is running as `version` and no other identifier.
// this file is a vercel function because it sits in `api/` at the vercel
// project root (apps/site); astro never sees it, so the pages stay static.

const RELEASES_LATEST =
  "https://github.com/jassuwu/andrew-dictate/releases/latest";

// no response is cached anywhere. an edge cache would answer most checks
// before this function ran, and a check the function never sees is a check
// nobody counted. what is cached is github's answer, in `cachedTag` below.
const NOT_CACHED = "no-store";

export type Sources = {
  /** the newest release's tag, e.g. "v0.9.5"; null or a throw when unknown. */
  latestTag: () => Promise<string | null>;
};

/** the whole endpoint, with github passed in so it can be tested offline. */
export async function answer(url: URL, sources: Sources): Promise<Response> {
  let tag: string | null;
  try {
    tag = await sources.latestTag();
  } catch {
    tag = null;
  }

  const version = tag?.replace(/^v/i, "");
  if (!version || !/^\d+(\.\d+)*$/.test(version)) {
    return json({ error: "no release found" }, 502);
  }
  return json({ latest: version }, 200);
}

/**
 * github's /releases/latest page redirects to /releases/tag/<tag>. reading
 * the redirect costs no api quota: unauthenticated api calls get 60 an hour
 * per ip, and a vercel function shares its ip with strangers.
 */
export async function tagFromGitHub(
  fetchImpl: typeof fetch = fetch,
): Promise<string | null> {
  const response = await fetchImpl(RELEASES_LATEST, {
    redirect: "manual",
    signal: AbortSignal.timeout(5000),
  });
  const location = response.headers.get("location") ?? "";
  const match = location.match(/\/releases\/tag\/([^/?#]+)$/);
  return match ? decodeURIComponent(match[1]) : null;
}

const TAG_TTL_MS = 60 * 60 * 1000;
const TAG_RETRY_MS = 60 * 1000;

/**
 * remembers github's answer in this instance's memory: an hour when it is a
 * tag, a minute when it is not. requests that arrive mid-lookup share it.
 * when a lookup fails after a good one, the last good tag keeps being served
 * and github is asked again in a minute, so an outage is not an error here.
 *
 * every function instance has its own memory, so github hears from each
 * warm instance about once an hour. at a few dozen installs that is a handful
 * of instances, so a shared cache in the datastore would save almost nothing
 * and would be a second thing to store.
 */
export function cachedTag(
  lookup: () => Promise<string | null>,
  now: () => number = Date.now,
  ttlMs: number = TAG_TTL_MS,
  retryMs: number = TAG_RETRY_MS,
): () => Promise<string | null> {
  let good: string | null = null;
  let validUntil = 0;
  let pending: Promise<string | null> | null = null;

  async function refresh(): Promise<string | null> {
    let tag: string | null = null;
    try {
      tag = await lookup();
    } catch {
      tag = null;
    }
    if (tag) {
      good = tag;
      validUntil = now() + ttlMs;
    } else {
      validUntil = now() + retryMs;
    }
    return good;
  }

  return () => {
    if (now() < validUntil) return Promise.resolve(good);
    pending ??= refresh().finally(() => {
      pending = null;
    });
    return pending;
  };
}

export type Env = Record<string, string | undefined>;

export type Deps = {
  env: Env;
  fetch: typeof fetch;
  now: () => number;
};

/**
 * the endpoint wired to its outside world: github through `deps.fetch`, with
 * its tag remembered by the handler for as long as the handler lives. the
 * function instance builds one at load, so the memory lasts the instance.
 */
export function createHandler(deps: Deps): (request: Request) => Promise<Response> {
  const latestTag = cachedTag(() => tagFromGitHub(deps.fetch), deps.now);
  return (request) => answer(new URL(request.url), { latestTag });
}

export const GET = createHandler({
  env: process.env,
  fetch,
  now: Date.now,
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": NOT_CACHED,
    },
  });
}
