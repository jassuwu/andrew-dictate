/** a line in an agent's thread: what was sent to it, or what it answers. */
export function agentLine(kind: "sent" | "reply", text: string) {
  const p = document.createElement("p");
  p.className = `agent-line agent-line-${kind}`;
  p.textContent = text;
  return p;
}
