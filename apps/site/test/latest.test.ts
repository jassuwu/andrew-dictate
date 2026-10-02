import { describe, expect, test } from "bun:test";
import {
  answer,
  cachedTag,
  checkInCounter,
  createHandler,
  storeFromEnv,
  tagFromGitHub,
  type Command,
  type Store,
} from "../api/latest";

const url = new URL("https://dictate.jass.gg/api/latest?version=0.9.4");

/** github and upstash as the function sees them, recording what it asked. */
function fakeInternet() {
  const githubLookups: string[] = [];
  const fetchStub = async (input: string | URL | Request) => {
    const target = String(input);
    if (target.startsWith("https://github.com/")) {
      githubLookups.push(target);
      return new Response(null, {
        status: 302,
        headers: {
          location: "https://github.com/jassuwu/andrew-dictate/releases/tag/v0.9.5",
        },
      });
    }
    throw new Error(`unexpected request to ${target}`);
  };
  return { fetch: fetchStub as typeof fetch, githubLookups };
}

function checkRequest(version: string) {
  return new Request(`https://dictate.jass.gg/api/latest?version=${version}`);
}

describe("answer", () => {
  test("says the newest version, without the tag's v", async () => {
    const response = await answer(url, { latestTag: async () => "v0.9.5" });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ latest: "0.9.5" });
    expect(response.headers.get("content-type")).toContain("application/json");
  });

  // an edge cache would answer most checks before the function ran, and a
  // check the function never sees is a check nobody counted.
  test("is never cached, so every check reaches the function", async () => {
    const response = await answer(url, { latestTag: async () => "v0.9.5" });

    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  test("a tag that is not a version is no answer", async () => {
    for (const tag of ["latest", "v0.9.beta", ""]) {
      const response = await answer(url, { latestTag: async () => tag });
      expect(response.status).toBe(502);
    }
  });

  test("github being down is no answer, and not cached either", async () => {
    const unreachable = await answer(url, {
      latestTag: async () => {
        throw new Error("offline");
      },
    });
    const nothing = await answer(url, { latestTag: async () => null });

    for (const response of [unreachable, nothing]) {
      expect(response.status).toBe(502);
      expect(response.headers.get("cache-control")).toBe("no-store");
    }
  });
});

/** a store that remembers every command batch it was given. */
function fakeStore(failure?: Error) {
  const writes: Command[][] = [];
  const store: Store = async (commands) => {
    if (failure) throw failure;
    writes.push(commands);
    return [];
  };
  return { store, writes };
}

const newest = async () => "v0.9.5";
const noon = Date.UTC(2026, 9, 2, 12, 0);

describe("counting a check", () => {
  test("one check adds one to one (day, version) field, and writes nothing else", async () => {
    const { store, writes } = fakeStore();

    await answer(url, { latestTag: newest, count: checkInCounter(store, () => noon) });

    expect(writes).toEqual([
      [
        ["HINCRBY", "checkins:2026-10-02", "0.9.4", 1],
        ["EXPIRE", "checkins:2026-10-02", 400 * 24 * 60 * 60],
      ],
    ]);
  });

  test("the day is the UTC date, whatever the server's clock says", async () => {
    const { store, writes } = fakeStore();
    const justBeforeMidnight = Date.UTC(2026, 9, 2, 23, 59, 59);
    const justAfter = Date.UTC(2026, 9, 3, 0, 0, 1);

    await answer(url, { latestTag: newest, count: checkInCounter(store, () => justBeforeMidnight) });
    await answer(url, { latestTag: newest, count: checkInCounter(store, () => justAfter) });

    expect(writes.map(([increment]) => increment[1])).toEqual([
      "checkins:2026-10-02",
      "checkins:2026-10-03",
    ]);
  });

  // the request carries more than the app sends; only `version` is ever read.
  test("nothing but the version is stored, whatever else the request carries", async () => {
    const { store, writes } = fakeStore();
    const crowded = new URL(
      "https://dictate.jass.gg/api/latest?version=0.9.4&id=4F2A-9C&device=macbook&email=a@b.co",
    );

    await answer(crowded, { latestTag: newest, count: checkInCounter(store, () => noon) });

    expect(writes).toHaveLength(1);
    const stored = JSON.stringify(writes);
    for (const stray of ["4F2A", "macbook", "a@b.co", "id", "device", "email"]) {
      expect(stored).not.toContain(stray);
    }
  });

  // anything but a version is one fixed field. the text never reaches the
  // store, so a stranger can't fill the hash with fields of their choosing
  // out of junk, only out of well-formed version numbers.
  test("a version that is not digits and dots is counted as invalid, never stored as sent", async () => {
    const junk = [
      "",
      "latest",
      "0.9.4-beta",
      "0.9.4 ",
      "1..2",
      "1.",
      ".1",
      "0.9.4,0.9.5",
      "<script>alert(1)</script>",
      "0.9.4\n0.9.5",
      "1".repeat(21),
    ];
    for (const sent of junk) {
      const { store, writes } = fakeStore();
      const asked = new URL("https://dictate.jass.gg/api/latest");
      asked.searchParams.set("version", sent);

      await answer(asked, { latestTag: newest, count: checkInCounter(store, () => noon) });

      expect(writes).toEqual([
        [
          ["HINCRBY", "checkins:2026-10-02", "invalid", 1],
          ["EXPIRE", "checkins:2026-10-02", 400 * 24 * 60 * 60],
        ],
      ]);
    }
  });

  test("no version at all is invalid too, and a version of twenty characters is not", async () => {
    const missing = fakeStore();
    await answer(new URL("https://dictate.jass.gg/api/latest"), {
      latestTag: newest,
      count: checkInCounter(missing.store, () => noon),
    });
    expect(missing.writes[0][0]).toEqual(["HINCRBY", "checkins:2026-10-02", "invalid", 1]);

    const longest = fakeStore();
    const exactly = "1".repeat(20);
    await answer(new URL(`https://dictate.jass.gg/api/latest?version=${exactly}`), {
      latestTag: newest,
      count: checkInCounter(longest.store, () => noon),
    });
    expect(longest.writes[0][0]).toEqual(["HINCRBY", "checkins:2026-10-02", exactly, 1]);
  });

  test("the check is counted when github has nothing to say", async () => {
    const { store, writes } = fakeStore();

    const response = await answer(url, {
      latestTag: async () => {
        throw new Error("offline");
      },
      count: checkInCounter(store, () => noon),
    });

    expect(response.status).toBe(502);
    expect(writes).toHaveLength(1);
  });

  // the count is a side note. it never costs anyone their answer.
  test("a store that fails still lets the answer through", async () => {
    const { store, writes } = fakeStore(new Error("upstash is down"));

    const response = await answer(url, { latestTag: newest, count: checkInCounter(store, () => noon) });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ latest: "0.9.5" });
    expect(writes).toHaveLength(0);
  });

  test("no counter configured is no counting, and the same answer", async () => {
    const response = await answer(url, { latestTag: newest });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ latest: "0.9.5" });
  });
});

describe("storeFromEnv", () => {
  type Sent = { url: string; init: RequestInit };

  function upstash(reply: () => Response = () => Response.json([{ result: 1 }, { result: 1 }])) {
    const sent: Sent[] = [];
    const fetchStub = async (input: string | URL | Request, init?: RequestInit) => {
      sent.push({ url: String(input), init: init ?? {} });
      return reply();
    };
    return { fetch: fetchStub as typeof fetch, sent };
  }

  const commands: Command[] = [
    ["HINCRBY", "checkins:2026-10-02", "0.9.4", 1],
    ["EXPIRE", "checkins:2026-10-02", 34560000],
  ];

  test("with the vercel integration's variables, posts the commands as one pipeline", async () => {
    const { fetch, sent } = upstash();
    const store = storeFromEnv(
      { KV_REST_API_URL: "https://eu1-x.upstash.io", KV_REST_API_TOKEN: "write-token" },
      fetch,
    );

    await store!(commands);

    expect(sent).toHaveLength(1);
    expect(sent[0].url).toBe("https://eu1-x.upstash.io/pipeline");
    expect(sent[0].init.method).toBe("POST");
    expect(new Headers(sent[0].init.headers).get("authorization")).toBe("Bearer write-token");
    expect(JSON.parse(String(sent[0].init.body))).toEqual(commands);
    expect(sent[0].init.signal).toBeInstanceOf(AbortSignal);
  });

  test("upstash's own variable names work too, and a trailing slash does not matter", async () => {
    const { fetch, sent } = upstash();
    const store = storeFromEnv(
      { UPSTASH_REDIS_REST_URL: "https://eu1-x.upstash.io/", UPSTASH_REDIS_REST_TOKEN: "t" },
      fetch,
    );

    await store!(commands);

    expect(sent[0].url).toBe("https://eu1-x.upstash.io/pipeline");
  });

  test("a url and a token from different families are not mixed", () => {
    const env = { KV_REST_API_URL: "https://a.upstash.io", UPSTASH_REDIS_REST_TOKEN: "t" };
    expect(storeFromEnv(env, upstash().fetch)).toBeNull();
  });

  test("without the variables there is no store, which is no counting", () => {
    for (const env of [
      {},
      { KV_REST_API_URL: "https://a.upstash.io" },
      { KV_REST_API_TOKEN: "t" },
      { KV_REST_API_URL: "", KV_REST_API_TOKEN: "" },
    ]) {
      expect(storeFromEnv(env, upstash().fetch)).toBeNull();
    }
  });

  test("a refusal is a failure, whether the http status or a command says so", async () => {
    const env = { KV_REST_API_URL: "https://a.upstash.io", KV_REST_API_TOKEN: "t" };
    const replies = [
      () => Response.json({ error: "Unauthorized" }, { status: 401 }),
      () => Response.json([{ error: "ERR wrong number of arguments" }, { result: 1 }]),
      () => new Response("<html>", { status: 200 }),
    ];
    for (const reply of replies) {
      const store = storeFromEnv(env, upstash(reply).fetch);
      await expect(store!(commands)).rejects.toThrow();
    }
  });
});

describe("tagFromGitHub", () => {
  test("reads the tag off the releases/latest redirect", async () => {
    let asked: { url: string; redirect?: RequestRedirect } | undefined;
    const fetchStub = async (input: string | URL | Request, init?: RequestInit) => {
      asked = { url: String(input), redirect: init?.redirect };
      return new Response(null, {
        status: 302,
        headers: {
          location: "https://github.com/jassuwu/andrew-dictate/releases/tag/v0.9.5",
        },
      });
    };

    expect(await tagFromGitHub(fetchStub as typeof fetch)).toBe("v0.9.5");
    expect(asked).toEqual({
      url: "https://github.com/jassuwu/andrew-dictate/releases/latest",
      redirect: "manual",
    });
  });

  // a repo with no releases answers 404; a changed page answers 200.
  test("anything but a redirect to a tag is null", async () => {
    const answers = [
      new Response("not found", { status: 404 }),
      new Response("<html>", { status: 200 }),
      new Response(null, {
        status: 302,
        headers: { location: "https://github.com/jassuwu/andrew-dictate/releases" },
      }),
    ];
    for (const response of answers) {
      const fetchStub = async () => response;
      expect(await tagFromGitHub(fetchStub as unknown as typeof fetch)).toBeNull();
    }
  });
});

// github's redirect is the only thing the function looks up, and without an
// edge cache in front it would be one lookup per install.
describe("cachedTag", () => {
  function lookupThat(...tags: Array<string | null | Error>) {
    let calls = 0;
    const lookup = async () => {
      const next = tags[Math.min(calls++, tags.length - 1)];
      if (next instanceof Error) throw next;
      return next;
    };
    return { lookup, calls: () => calls };
  }
  const hour = 60 * 60 * 1000;

  test("many requests inside the hour are one lookup", async () => {
    const github = lookupThat("v0.9.5");
    let clock = 0;
    const latestTag = cachedTag(github.lookup, () => clock);

    for (let i = 0; i < 50; i++) {
      clock += 1000;
      expect(await latestTag()).toBe("v0.9.5");
    }
    expect(github.calls()).toBe(1);
  });

  test("after the hour it looks again, and picks up a new release", async () => {
    const github = lookupThat("v0.9.5", "v0.9.6");
    let clock = 0;
    const latestTag = cachedTag(github.lookup, () => clock);

    expect(await latestTag()).toBe("v0.9.5");
    clock = hour - 1;
    expect(await latestTag()).toBe("v0.9.5");
    clock = hour + 1;
    expect(await latestTag()).toBe("v0.9.6");
    expect(github.calls()).toBe(2);
  });

  test("requests that arrive while it is looking share the one lookup", async () => {
    let calls = 0;
    let release!: (tag: string) => void;
    const lookup = () => {
      calls++;
      return new Promise<string>((resolve) => (release = resolve));
    };
    const latestTag = cachedTag(lookup, () => 0);

    const waiting = [latestTag(), latestTag(), latestTag()];
    release("v0.9.5");

    expect(await Promise.all(waiting)).toEqual(["v0.9.5", "v0.9.5", "v0.9.5"]);
    expect(calls).toBe(1);
  });

  // an outage costs github one retry a minute, not one per install.
  test("a failed lookup is retried after a minute, not on every request", async () => {
    const github = lookupThat(new Error("offline"), "v0.9.5");
    let clock = 0;
    const latestTag = cachedTag(github.lookup, () => clock);

    expect(await latestTag()).toBeNull();
    clock = 30_000;
    expect(await latestTag()).toBeNull();
    expect(github.calls()).toBe(1);

    clock = 61_000;
    expect(await latestTag()).toBe("v0.9.5");
    expect(github.calls()).toBe(2);
  });

  test("an answer that is no tag counts as a failure too", async () => {
    const github = lookupThat(null);
    const latestTag = cachedTag(github.lookup, () => 0);

    expect(await latestTag()).toBeNull();
    expect(await latestTag()).toBeNull();
    expect(github.calls()).toBe(1);
  });

  test("an outage after a good answer keeps the last good tag", async () => {
    const github = lookupThat("v0.9.5", new Error("offline"));
    let clock = 0;
    const latestTag = cachedTag(github.lookup, () => clock);

    await latestTag();
    clock = hour + 1;
    expect(await latestTag()).toBe("v0.9.5");
    clock = hour + 2;
    expect(await latestTag()).toBe("v0.9.5");
    expect(github.calls()).toBe(2);
  });
});

describe("the handler", () => {
  test("a day of checks is one github lookup, every one of them answered", async () => {
    const internet = fakeInternet();
    let clock = Date.UTC(2026, 9, 2, 8);
    const handle = createHandler({ env: {}, fetch: internet.fetch, now: () => clock });

    for (const version of ["0.9.4", "0.9.3", "0.9.4", "0.9.2", "0.9.4"]) {
      clock += 60_000;
      const response = await handle(checkRequest(version));
      expect(await response.json()).toEqual({ latest: "0.9.5" });
    }
    expect(internet.githubLookups).toHaveLength(1);

    clock += 60 * 60 * 1000;
    await handle(checkRequest("0.9.4"));
    expect(internet.githubLookups).toHaveLength(2);
  });
});
