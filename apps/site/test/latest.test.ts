import { describe, expect, test } from "bun:test";
import { answer, cachedTag, createHandler, tagFromGitHub } from "../api/latest";

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
