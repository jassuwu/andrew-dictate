import { describe, expect, test } from "bun:test";
import { answer, tagFromGitHub } from "../api/latest";

const url = new URL("https://dictate.jass.gg/api/latest?version=0.9.4");

describe("answer", () => {
  test("says the newest version, without the tag's v", async () => {
    const response = await answer(url, { latestTag: async () => "v0.9.5" });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ latest: "0.9.5" });
    expect(response.headers.get("content-type")).toContain("application/json");
  });

  // dozens of installs, one github lookup an hour per cached url.
  test("is cached at the edge for an hour, then served stale while it refreshes", async () => {
    const response = await answer(url, { latestTag: async () => "v0.9.5" });

    expect(response.headers.get("cache-control")).toBe(
      "public, max-age=0, s-maxage=3600, stale-while-revalidate=86400",
    );
  });

  test("a tag that is not a version is no answer", async () => {
    for (const tag of ["latest", "v0.9.beta", ""]) {
      const response = await answer(url, { latestTag: async () => tag });
      expect(response.status).toBe(502);
    }
  });

  test("github being down is no answer, cached only briefly", async () => {
    const unreachable = await answer(url, {
      latestTag: async () => {
        throw new Error("offline");
      },
    });
    const nothing = await answer(url, { latestTag: async () => null });

    for (const response of [unreachable, nothing]) {
      expect(response.status).toBe(502);
      expect(response.headers.get("cache-control")).toBe(
        "public, max-age=0, s-maxage=60",
      );
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
