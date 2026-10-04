// the copy in src/copy.ts uses two of markdown's marks and nothing else:
// `backticks` and [links](url). the readme holds it as written; the page
// sets it from these pieces.

export type Piece =
  | { kind: "text" | "key" | "code"; text: string }
  | { kind: "link"; text: string; href: string };

/** the keys the copy names. one of these in backticks is a keycap. */
const keys = new Set(["fn", "esc"]);

const site = "https://dictate.jass.gg";

export function pieces(line: string): Piece[] {
  const out: Piece[] = [];
  const mark = /`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)/g;
  let at = 0;
  for (const m of line.matchAll(mark)) {
    if (m.index > at) out.push({ kind: "text", text: line.slice(at, m.index) });
    if (m[1] !== undefined) {
      out.push({ kind: keys.has(m[1]) ? "key" : "code", text: m[1] });
    } else {
      const href = m[3].startsWith(site) ? m[3].slice(site.length) || "/" : m[3];
      out.push({ kind: "link", text: m[2], href });
    }
    at = m.index + m[0].length;
  }
  if (at < line.length) out.push({ kind: "text", text: line.slice(at) });
  return out;
}

/** the words a reader reads, marks gone. */
export function plain(line: string): string {
  return pieces(line).map((piece) => piece.text).join("");
}
