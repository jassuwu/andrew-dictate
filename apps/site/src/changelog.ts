// the release notes file, read into releases. the release workflow reads the
// same file and refuses a tag whose notes are not on top, so the newest
// release is always first.

export type Release = { version: string; paragraphs: string[] };

export function releases(notes: string): Release[] {
  const found: Release[] = [];
  for (const block of notes.split(/^## /m).slice(1)) {
    const [heading, ...body] = block.split("\n");
    found.push({
      version: heading.trim(),
      paragraphs: body
        .join("\n")
        .split(/\n\s*\n/)
        .map((paragraph) => paragraph.replace(/\s+/g, " ").trim())
        .filter(Boolean),
    });
  }
  if (found.length === 0) {
    throw new Error("the release notes have no `## version` heading in them");
  }
  return found;
}

/** a paragraph as prose and `code`, which is all the markdown the notes use. */
export function inline(paragraph: string): { code: boolean; text: string }[] {
  return paragraph
    .split("`")
    .map((text, index) => ({ code: index % 2 === 1, text }))
    .filter((piece) => piece.text !== "");
}
