// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

function thumbDir() {
  return Paths.cacheDir() + "/cliphist";
}

function openDir() {
  return Paths.tmpDir() + "/cliphist-open";
}

const THUMB = 256;

function highlightedPreview(text, query) {
  const q = (query || "").trim().toLowerCase();
  if (!q) return Strings.escapeHtml(text);
  const lower = text.toLowerCase();
  const out = [];
  let i = 0;
  while (i < text.length) {
    const idx = lower.indexOf(q, i);
    if (idx < 0) {
      out.push(Strings.escapeHtml(text.slice(i)));
      break;
    }
    if (idx > i) out.push(Strings.escapeHtml(text.slice(i, idx)));
    out.push("<span style=\"color:#eebebe;font-weight:700;\">" + Strings.escapeHtml(text.slice(idx, idx + q.length)) + "</span>");
    i = idx + q.length;
  }
  return out.join("");
}

function cleanText(s) {
  s = String(s || "");
  s = s.replace(/\r/g, "");
  s = s.replace(/\0/g, "");
  s = s.replace(/\u001f/g, "");
  s = s.replace(/\n/g, " \u21b5 ");
  s = s.replace(/\s+/g, " ");
  return s;
}

function preview(s) {
  let p = cleanText(s);
  if (p === "") p = "(empty)";
  return p;
}

function parseList(text) {
  const entries = [];
  const imageIds = [];
  if (!text) return { entries: entries, imageIds: imageIds };
  for (const line of text.split("\n")) {
    if (line.trim() === "") continue;
    const m = line.match(/^(\d+)\t(.*)$/);
    if (!m) continue;
    const id = m[1];
    const content = m[2];
    if (content.startsWith("[[ binary")) {
      imageIds.push(id);
    } else {
      entries.push({ id: id, content: content, preview: preview(content) });
    }
  }
  return { entries: entries, imageIds: imageIds };
}

function filterEntries(entries, query) {
  const q = (query || "").trim().toLowerCase();
  if (q === "") return entries.slice();
  const out = [];
  for (const e of entries) {
    if ((e.content + " " + e.preview).toLowerCase().includes(q)) out.push(e);
  }
  return out;
}

function thumbCommand(ids, dir) {
  if (!ids || ids.length === 0) return null;
  const quoted = ids.map((i) => Strings.shellQuote(i)).join(" ");
  return "mkdir -p " + Strings.shellQuote(dir) + "; printf '%s\\n' " + quoted +
      " | xargs -P 8 -I{} sh -c '[ -f \"" + dir + "/{}.png\" ] || { printf \"%s\" \"{}\" | cliphist decode | " +
      "magick - -thumbnail " + THUMB + "x" + THUMB + " -background none -gravity center -extent " +
      THUMB + "x" + THUMB + " \"" + dir + "/{}.png\" >/dev/null 2>&1; }'";
}

function copyCommand(id) {
  return "printf '%s' " + Strings.shellQuote(id) + " | cliphist decode | wl-copy";
}

function deleteCommand(id, dir) {
  return "printf '%s' " + Strings.shellQuote(id) + " | cliphist delete; rm -f " +
      Strings.shellQuote(dir + "/" + id + ".png");
}

function openCommand(id, dir) {
  const file = dir + "/" + id + ".png";
  return "mkdir -p " + Strings.shellQuote(dir) + "; find " + Strings.shellQuote(dir) +
      " -type f -name '*.png' -mmin +30 -delete 2>/dev/null; printf '%s' " + Strings.shellQuote(id) +
      " | cliphist decode > " + Strings.shellQuote(file) + "; [ -s " + Strings.shellQuote(file) +
      " ] && xdg-open " + Strings.shellQuote(file) + " >/dev/null 2>&1 &";
}

function hintText(mode) {
  const key = (k) => "<b><span style=\"color:#a2a8bc;\">" + k + "</span></b>";
  const lbl = (t) => "<span style=\"color:#6a707f;\">" + t + "</span>";
  const tab = key("tab") + " " + lbl("toggle mode");
  const del = key("delete") + " " + lbl("remove entry");
  const open = key("shift return") + " " + lbl("open image");
  if (mode === "image") return [tab, open, del];
  return [tab, del];
}
