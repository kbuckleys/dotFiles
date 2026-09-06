// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

// rbw ls --raw → JSON array [{ id, name, user, folder, uris, type }]
function parseEntries(jsonText) {
  let data;
  try { data = JSON.parse(jsonText); } catch (e) { return []; }
  if (!Array.isArray(data)) return [];
  const rows = [];
  for (const e of data) {
    if (!e || typeof e.name !== "string" || !e.id) continue;
    rows.push({
      id: e.id,
      name: e.name,
      user: typeof e.user === "string" ? e.user : "",
      folder: typeof e.folder === "string" ? e.folder : "",
    });
  }
  // folder-less entries float to the top, then alphabetical by name
  rows.sort((a, b) => {
    const fa = a.folder, fb = b.folder;
    if ((fa === "") !== (fb === "")) return fa === "" ? -1 : 1;
    const n = a.name.toLowerCase().localeCompare(b.name.toLowerCase());
    if (n !== 0) return n;
    return a.user.localeCompare(b.user);
  });
  return rows;
}

function filterEntries(rows, query) {
  const q = String(query).toLowerCase();
  if (!q) return rows;
  return rows.filter((r) =>
    r.name.toLowerCase().indexOf(q) >= 0 ||
    r.user.toLowerCase().indexOf(q) >= 0 ||
    r.folder.toLowerCase().indexOf(q) >= 0);
}

// query matches render bold #eebebe across every field
function highlight(text, query) {
  text = String(text);
  const esc = (s) => String(s).replace(/&/g, "&amp;")
    .replace(/</g, "&lt;").replace(/>/g, "&gt;");
  if (!query) return esc(text);
  const lower = text.toLowerCase();
  const ql = String(query).toLowerCase();
  let out = "", pos = 0, i;
  while ((i = lower.indexOf(ql, pos)) >= 0) {
    out += esc(text.slice(pos, i));
    out += "<b><span style=\"color:#eebebe;\">" +
      Strings.escapeHtml(text.substr(i, ql.length)) + "</span></b>";
    pos = i + ql.length;
  }
  return out + esc(text.slice(pos));
}
