// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function basename(p) {
  const parts = String(p).split("/");
  return parts[parts.length - 1] || p;
}

function dirname(p) {
  if (!p || p === "/") return "/";
  const s = String(p).replace(/\/+$/, "");
  const idx = s.lastIndexOf("/");
  if (idx <= 0) return "/";
  return s.slice(0, idx);
}

function isHidden(name) {
  return name.length > 0 && name[0] === ".";
}

function sortFiles(a, b) {
  // directories first, then alphabetically case-insensitive
  if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
  const al = a.name.toLowerCase();
  const bl = b.name.toLowerCase();
  if (al < bl) return -1;
  if (al > bl) return 1;
  return 0;
}

function parseLsOutput(text, dir) {
  if (!text) return [];
  const out = [];
  // ls -A1p output: one entry per line, dirs end with "/"
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; ++i) {
    const raw = lines[i];
    if (raw === "") continue;
    const isDir = raw.endsWith("/");
    const name = isDir ? raw.slice(0, -1) : raw;
    if (name === "") continue;
    // ls -p marks only; keep hidden files included as-is
    const path = dir.endsWith("/") ? dir + name : dir + "/" + name;
    out.push({
      name: name,
      path: path,
      isDir: isDir,
      isHidden: isHidden(name)
    });
  }
  out.sort(sortFiles);
  return out;
}

function listCommand(dir) {
  return "ls -A1p -- " + shellQuote(dir) + " 2>/dev/null";
}

function openCommand(path) {
  return "xdg-open " + shellQuote(path) + " >/dev/null 2>&1 &";
}

function openTerminalCommand(dir) {
  return "xdg-terminal --working-directory " + shellQuote(dir) + " >/dev/null 2>&1 &";
}
