import { describe, expect, test } from "bun:test";
import {
  lastDays,
  parseEnvFile,
  parseHash,
  renderTable,
  type Counts,
} from "../scripts/checkins";

describe("lastDays", () => {
  test("is the n utc days up to and including today, oldest first", () => {
    const now = Date.UTC(2026, 9, 2, 1, 0);

    expect(lastDays(now, 3)).toEqual(["2026-09-30", "2026-10-01", "2026-10-02"]);
  });

  test("walks back over a month end and a leap day", () => {
    const now = Date.UTC(2028, 2, 2, 12, 0);

    expect(lastDays(now, 4)).toEqual(["2028-02-28", "2028-02-29", "2028-03-01", "2028-03-02"]);
  });

  test("thirty days is thirty distinct dates", () => {
    const days = lastDays(Date.UTC(2026, 9, 2), 30);

    expect(days).toHaveLength(30);
    expect(new Set(days).size).toBe(30);
    expect(days[0]).toBe("2026-09-03");
  });
});

describe("parseHash", () => {
  // upstash's rest api answers HGETALL as a flat list of field, value, field, value.
  test("reads a flat list of fields and values as counts", () => {
    expect(parseHash(["0.9.4", "12", "0.9.3", "2", "invalid", "1"])).toEqual({
      "0.9.4": 12,
      "0.9.3": 2,
      invalid: 1,
    });
  });

  test("reads an object too, and a day with no hash as no counts", () => {
    expect(parseHash({ "0.9.4": "3" })).toEqual({ "0.9.4": 3 });
    expect(parseHash([])).toEqual({});
    expect(parseHash(null)).toEqual({});
  });
});

describe("renderTable", () => {
  const counts: Counts = {
    "2026-10-01": { "0.9.10": 2, "0.9.4": 5, "0.9.9": 1 },
    "2026-10-02": { "0.9.4": 3, invalid: 1 },
  };

  test("is dates down, versions across in version order, invalid last, a total each way", () => {
    const table = renderTable(["2026-10-01", "2026-10-02", "2026-10-03"], counts);

    expect(table).toBe(
      [
        "date        0.9.4  0.9.9  0.9.10  invalid  total",
        "2026-10-01      5      1       2        -      8",
        "2026-10-02      3      -       -        1      4",
        "2026-10-03      -      -       -        -      -",
        "total           8      1       2        1     12",
      ].join("\n"),
    );
  });

  test("a window with no check-ins says so", () => {
    expect(renderTable(["2026-10-01"], {})).toBe("no check-ins in this window.");
  });
});

describe("parseEnvFile", () => {
  test("reads KEY=value lines, with or without quotes, ignoring comments and blanks", () => {
    const file = [
      "# pulled by vercel env pull",
      "",
      'KV_REST_API_URL="https://eu1-x.upstash.io"',
      "KV_REST_API_TOKEN=plain-token",
      "export OTHER='single quoted'",
      "not a pair",
    ].join("\n");

    expect(parseEnvFile(file)).toEqual({
      KV_REST_API_URL: "https://eu1-x.upstash.io",
      KV_REST_API_TOKEN: "plain-token",
      OTHER: "single quoted",
    });
  });
});
