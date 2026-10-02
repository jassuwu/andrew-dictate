// GET /api/latest?version=0.9.4 → {"latest":"0.9.5"}
//
// the app's daily update check asks this, and nothing else does. the app
// sends the version it is running as `version` and no other identifier.
// this file is a vercel function because it sits in `api/` at the vercel
// project root (apps/site); astro never sees it, so the pages stay static.
//
// every check is also counted: one HINCRBY on the hash `checkins:<utc date>`,
// field = the version (or "invalid"). that is all that is stored. no ip, no
// user agent, no id, no other query parameter is read, let alone kept. the
// counts live in upstash redis; scripts/checkins.ts reads them back, and
// apps/site/COUNTING.md says how to switch counting on.
//
// the file imports nothing relative, on purpose: vercel deploys it by itself
// and there is nothing for its build to resolve. scripts/checkins.ts imports
// from it, so the key names the writer uses are the ones the reader reads.

const RELEASES_LATEST =
  "https://github.com/jassuwu/andrew-dictate/releases/latest";

// no response is cached anywhere. an edge cache would answer most checks
// before this function ran, and a check the function never sees is a check
// nobody counted. what is cached is github's answer, in `cachedTag` below.
const NOT_CACHED = "no-store";

export type Sources = {
  /** the newest release's tag, e.g. "v0.9.5"; null or a throw when unknown. */
  latestTag: () => Promise<string | null>;
  /**
   * adds one to today's count for `field`: a version, or "invalid". absent
   * when counting is off. it may throw, and the answer goes out regardless.
   */
  count?: (field: string) => Promise<void>;
  /** where a count that failed is mentioned: the error's message, nothing of the request. */
  report?: (message: string) => void;
};

/**
 * the whole endpoint, with github and the counter passed in so it can be
 * tested offline. the only part of the request it reads is `version`.
 */
export async function answer(url: URL, sources: Sources): Promise<Response> {
  const [tag] = await Promise.all([
    settled(sources.latestTag, null),
    settled(
      async () => sources.count?.(versionField(url.searchParams.get("version"))),
      undefined,
      (error) => sources.report?.(`check-in not counted: ${error instanceof Error ? error.message : error}`),
    ),
  ]);

  const version = tag?.replace(/^v/i, "");
  if (!version || !VERSION.test(version)) {
    return json({ error: "no release found" }, 502);
  }
  return json({ latest: version }, 200);
}

/** a failed side of the request is no reason to fail the other. */
async function settled<T>(
  work: () => Promise<T>,
  fallback: T,
  onError?: (error: unknown) => void,
): Promise<T> {
  try {
    return await work();
  } catch (error) {
    try {
      onError?.(error);
    } catch {
      // reporting is no more allowed to fail the answer than counting is.
    }
    return fallback;
  }
}

const VERSION = /^\d+(\.\d+)*$/;
const MAX_VERSION_LENGTH = 20;

/** where a check that sent no version, or a strange one, is counted. */
export const INVALID = "invalid";

/**
 * the field a check is counted under: the version it sent when that is
 * digits and dots and short, otherwise "invalid". the text it sent is never
 * stored, so no one can put words of their choosing into the hash. invalid
 * is counted rather than dropped because the total is then every request,
 * and a bug that makes the app send nonsense shows up as a number.
 */
export function versionField(sent: string | null): string {
  if (sent === null || sent.length > MAX_VERSION_LENGTH || !VERSION.test(sent)) {
    return INVALID;
  }
  return sent;
}

/** one redis command: its name, then its arguments. */
export type Command = Array<string | number>;

/**
 * runs the commands together, in order, and resolves with each one's result.
 * throws when the store is unreachable or any command fails.
 */
export type Store = (commands: Command[]) => Promise<unknown[]>;

// a day's hash expires about 400 days after its last check. the key for a
// day stops changing when the day ends, so that is 400 days of history.
export const RETENTION_SECONDS = 400 * 24 * 60 * 60;

export function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

/** a hash per day, `checkins:2026-10-02`, with a field per version. */
export function checkinKey(day: string): string {
  return `checkins:${day}`;
}

/**
 * the counter: each call is one HINCRBY on today's hash, and an EXPIRE on
 * the same key. those two commands are everything this function stores. the
 * day comes from the clock, never from the request.
 */
export function checkInCounter(
  store: Store,
  now: () => number,
): (field: string) => Promise<void> {
  return async (field) => {
    const key = checkinKey(utcDay(now()));
    await store([
      ["HINCRBY", key, field, 1],
      ["EXPIRE", key, RETENTION_SECONDS],
    ]);
  };
}

export type Env = Record<string, string | undefined>;

/**
 * upstash redis over its rest api, with plain fetch. the url and token come
 * from the variables vercel's upstash integration injects (KV_REST_API_*), or
 * upstash's own names; a url and a token from different families are not
 * mixed. null when neither pair is there, which means "do not count".
 */
export function storeFromEnv(env: Env, fetchImpl: typeof fetch): Store | null {
  const pairs = [
    [env.KV_REST_API_URL, env.KV_REST_API_TOKEN],
    [env.UPSTASH_REDIS_REST_URL, env.UPSTASH_REDIS_REST_TOKEN],
  ];
  const pair = pairs.find(([url, token]) => url && token);
  if (!pair) return null;
  const [base, token] = pair as [string, string];

  return async (commands) => {
    const response = await fetchImpl(`${base.replace(/\/+$/, "")}/pipeline`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(commands),
      signal: AbortSignal.timeout(2000),
    });
    if (!response.ok) throw new Error(`store answered ${response.status}`);

    const replies: unknown = await response.json();
    if (!Array.isArray(replies)) throw new Error("store answered with no list");
    for (const reply of replies) {
      if (reply?.error) throw new Error(`store refused a command: ${reply.error}`);
    }
    return replies.map((reply) => reply?.result);
  };
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

export type Deps = {
  env: Env;
  fetch: typeof fetch;
  now: () => number;
};

/**
 * the endpoint wired to its outside world: github through `deps.fetch`, with
 * its tag remembered by the handler for as long as the handler lives (the
 * function instance builds one at load, so the memory lasts the instance),
 * and the counter on the store the environment names, if it names one.
 *
 * the environment is read on every request, so adding the store's variables
 * and redeploying is all it takes to start counting. only a GET is a check.
 */
export function createHandler(deps: Deps): (request: Request) => Promise<Response> {
  const latestTag = cachedTag(() => tagFromGitHub(deps.fetch), deps.now);
  return (request) => {
    const store = request.method === "GET" ? storeFromEnv(deps.env, deps.fetch) : null;
    return answer(new URL(request.url), {
      latestTag,
      count: store ? checkInCounter(store, deps.now) : undefined,
      report: (message) => console.error(message),
    });
  };
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
