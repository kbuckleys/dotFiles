// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

function home() {
  return Quickshell.env("HOME");
}

function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function escapeHtml(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function highlightedPreview(text, query) {
  const terms = (query || "").trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return escapeHtml(text);
  const lower = text.toLowerCase();
  const ranges = [];
  for (const q of terms) {
    let idx = 0;
    while (true) {
      const p = lower.indexOf(q, idx);
      if (p < 0) break;
      ranges.push([p, p + q.length]);
      idx = p + q.length;
    }
  }
  if (ranges.length === 0) return escapeHtml(text);
  ranges.sort((a,b)=> a[0]-b[0]);
  const merged = [];
  for (const r of ranges) {
    if (merged.length === 0 || r[0] > merged[merged.length-1][1]) merged.push(r);
    else merged[merged.length-1][1] = Math.max(merged[merged.length-1][1], r[1]);
  }
  let out = "";
  let pos = 0;
  for (const r of merged) {
    if (r[0] > pos) out += escapeHtml(text.slice(pos, r[0]));
    out += "<span style=\"color:#c8a4e0;font-weight:700;\">" + escapeHtml(text.slice(r[0], r[1])) + "</span>";
    pos = r[1];
  }
  if (pos < text.length) out += escapeHtml(text.slice(pos));
  return out;
}

function basename(p) {
  const parts = String(p).split("/");
  return parts[parts.length - 1] || p;
}

function searchCommand(root, maxDepth, query) {
  const r = shellQuote(root);
  if (!query || query.trim() === "") {
    return "fd -t f -H --max-results 200 . " + r + " 2>/dev/null | sort | head -n 200";
  }
  const q = shellQuote(query.trim());
  return "fd -t f -H . " + r + " 2>/dev/null | fzf --filter " + q + " 2>/dev/null | head -n 500";
}

function parseResults(text) {
  if (!text) return [];
  const out = [];
  for (const line of text.split("\n")) {
    const p = line.trim();
    if (p === "") continue;
    out.push({ path: p, preview: p, displayText: p });
  }
  return out;
}

function filterEntries(entries, query) {
  const terms = (query || "").trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return entries.slice();
  const out = [];
  for (const e of entries) {
    const hay = (e.path + " " + basename(e.path)).toLowerCase();
    let ok = true;
    for (const q of terms) {
      if (!hay.includes(q)) { ok = false; break; }
    }
    if (ok) out.push(e);
  }
  return out;
}

function openCommand(path) {
  return "xdg-open " + shellQuote(path) + " >/dev/null 2>&1 &";
}

function hintText() {
  const key = (k) => "<b><span style=\"color:#a2a8bc;\">" + k + "</span></b>";
  const lbl = (t) => "<span style=\"color:#6a707f;\">" + t + "</span>";
  const del = key("return") + " " + lbl("open");
  const cp = key("alt c") + " " + lbl("copy path");
  return [del, cp];
}
