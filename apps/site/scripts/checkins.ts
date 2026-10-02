// bun run scripts/checkins.ts [days]
//
// the last 30 days of update checks, as a date x version table with a daily
// total. it reads the counters api/latest.ts writes, from the same store, so
// it needs the same variables: KV_REST_API_URL and KV_REST_API_TOKEN (or
// UPSTASH_REDIS_REST_URL and UPSTASH_REDIS_REST_TOKEN). they come from the
// environment, or from a .env or .env.local next to package.json. those files
// are gitignored. `vercel env pull` writes .env.local, which is the easy way.
//
// when KV_REST_API_READ_ONLY_TOKEN is there it is used instead of the write
// token, because reading is all this does.

import { readFileSync } from "node:fs";
import {
  checkinKey,
  INVALID,
  storeFromEnv,
  utcDay,
  type Command,
  type Env,
} from "../api/latest";

/** counts[day][field]: how many checks that day, per version. */
export type Counts = Record<string, Record<string, number>>;

const DAY_MS = 24 * 60 * 60 * 1000;

/** the n utc dates up to and including today, oldest first. */
export function lastDays(now: number, n: number): string[] {
  const today = Date.parse(utcDay(now));
  return Array.from({ length: n }, (_, i) => utcDay(today - (n - 1 - i) * DAY_MS));
}

/** a redis hash as upstash sends it, a flat list of field, value, field, value. */
export function parseHash(reply: unknown): Record<string, number> {
  const entries: [string, unknown][] = Array.isArray(reply)
    ? Array.from({ length: Math.floor(reply.length / 2) }, (_, i) => [
        String(reply[2 * i]),
        reply[2 * i + 1],
      ])
    : reply && typeof reply === "object"
      ? Object.entries(reply)
      : [];
  return Object.fromEntries(entries.map(([field, value]) => [field, Number(value)]));
}

export function renderTable(days: string[], counts: Counts): string {
  const seen = new Set(days.flatMap((day) => Object.keys(counts[day] ?? {})));
  if (seen.size === 0) return "no check-ins in this window.";

  const versions = [...seen].filter((field) => field !== INVALID).sort(compareVersions);
  if (seen.has(INVALID)) versions.push(INVALID);

  const cell = (n: number) => (n > 0 ? String(n) : "-");
  const total = (fields: Record<string, number>) =>
    versions.reduce((sum, field) => sum + (fields[field] ?? 0), 0);

  const columnTotals = Object.fromEntries(
    versions.map((field) => [field, days.reduce((sum, day) => sum + (counts[day]?.[field] ?? 0), 0)]),
  );
  const rows: string[][] = [
    ["date", ...versions, "total"],
    ...days.map((day) => {
      const fields = counts[day] ?? {};
      return [day, ...versions.map((field) => cell(fields[field] ?? 0)), cell(total(fields))];
    }),
    ["total", ...versions.map((field) => cell(columnTotals[field])), cell(total(columnTotals))],
  ];

  const widths = rows[0].map((_, column) => Math.max(...rows.map((row) => row[column].length)));
  return rows
    .map((row) =>
      row
        .map((text, column) => (column === 0 ? text.padEnd(widths[0]) : text.padStart(widths[column])))
        .join("  "),
    )
    .join("\n");
}

function compareVersions(a: string, b: string): number {
  const left = a.split(".").map(Number);
  const right = b.split(".").map(Number);
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const difference = (left[i] ?? 0) - (right[i] ?? 0);
    if (difference !== 0) return difference;
  }
  return a.localeCompare(b);
}

/** KEY=value lines, the way `vercel env pull` and most .env files write them. */
export function parseEnvFile(text: string): Env {
  const env: Env = {};
  for (const line of text.split("\n")) {
    const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (!match) continue;
    env[match[1]] = match[2].replace(/^(["'])(.*)\1$/, "$2");
  }
  return env;
}

function loadEnv(): Env {
  const fromFiles: Env = {};
  for (const name of [".env", ".env.local"]) {
    try {
      Object.assign(fromFiles, parseEnvFile(readFileSync(new URL(`../${name}`, import.meta.url), "utf8")));
    } catch {
      // no such file, which is fine.
    }
  }
  return { ...fromFiles, ...process.env };
}

async function main() {
  const days = lastDays(Date.now(), Number(process.argv[2]) || 30);
  const env = loadEnv();
  const readOnly = env.KV_REST_API_READ_ONLY_TOKEN;
  const store = storeFromEnv(readOnly ? { ...env, KV_REST_API_TOKEN: readOnly } : env, fetch);
  if (!store) {
    console.error(
      "no store to read. set KV_REST_API_URL and KV_REST_API_TOKEN in the environment,\n" +
        "or in apps/site/.env.local (`vercel env pull .env.local` writes it). see COUNTING.md.",
    );
    process.exit(1);
  }

  const commands: Command[] = days.map((day) => ["HGETALL", checkinKey(day)]);
  const replies = await store(commands);
  const counts: Counts = Object.fromEntries(days.map((day, i) => [day, parseHash(replies[i])]));
  console.log(renderTable(days, counts));
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(`could not read the counts: ${error instanceof Error ? error.message : error}`);
    process.exit(1);
  });
}
