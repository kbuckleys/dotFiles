// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function escapeHtml(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Parse /usr/share/unicode/emoji/emoji-test.txt (Unicode 17.0).
// Keeps fully-qualified + minimally-qualified entries with their names;
// components (skin tones, ZWJ pieces) and unqualified duplicates are dropped.
function parseEmojiTest(text) {
  const entries = [];
  let group = "", subgroup = "";
  for (const line of String(text).split("\n")) {
    if (line.startsWith("# group: ")) { group = line.slice(9).trim(); continue; }
    if (line.startsWith("# subgroup: ")) { subgroup = line.slice(12).trim(); continue; }
    if (!line || line.startsWith("#")) continue;

    const m = line.match(/^([0-9A-F][0-9A-F ]*?)\s*;\s*(\S+)\s*#\s*(.+)$/);
    if (!m) continue;
    const status = m[2];
    if (status === "component" || status === "unqualified") continue;

    // tail is "<emoji> E<version> <name>" — lazy up to the version token,
    // which the emoji itself can never contain
    const tail = m[3].match(/^(.*?)\s+E[0-9]+(?:\.[0-9]+)?\s+(.*)$/);
    if (!tail) continue;

    let char = "";
    for (const cp of m[1].trim().split(" ")) {
      const n = parseInt(cp, 16);
      if (n > 0) char += String.fromCodePoint(n);
    }

    entries.push({
      char: char,
      name: tail[2],
      group: group,
      subgroup: subgroup,
    });
  }
  return entries;
}

// .nf-<class>:before { content: "\XXXX" } from nerdfonts.com webfont.css
function parseNerdCss(css) {
  const icons = [];
  const re = /\.((?:nf-)?[a-z0-9_-]+):before\s*\{\s*content:\s*"\\([0-9a-f]+)"/gi;
  let m;
  while ((m = re.exec(css)) !== null) {
    icons.push({
      cls: m[1],
      code: m[2],
      char: String.fromCodePoint(parseInt(m[2], 16)),
    });
  }
  return icons;
}

function filterEntries(entries, query) {
  const q = String(query).toLowerCase();
  if (!q) return entries;
  return entries.filter((e) => {
    if (e.cls) return e.cls.toLowerCase().indexOf(q) >= 0 ||
                      e.code.toLowerCase().indexOf(q) >= 0;
    return (e.name && e.name.toLowerCase().indexOf(q) >= 0) ||
           e.char.indexOf(q) >= 0;
  });
}
