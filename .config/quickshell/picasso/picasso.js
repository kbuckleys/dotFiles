// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

// The name a wallpaper goes by in the picker: the file's own, without the
// directory or the extension.
function label(path) {
  const base = String(path || "").split("/").pop();
  const dot = base.lastIndexOf(".");
  return dot > 0 ? base.slice(0, dot) : base;
}

function filter(files, query) {
  const q = String(query || "").trim().toLowerCase();
  if (q === "") return files;
  return files.filter((f) => label(f).toLowerCase().indexOf(q) >= 0);
}

// single-quote for /bin/sh, so a directory with a space or a quote in it
// cannot end the argument early
function shellQuote(s) {
  return "'" + String(s ?? "").replace(/'/g, "'\\''") + "'";
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function serialize(map) {
  return JSON.stringify(map);
}

function parse(text) {
  try {
    const v = JSON.parse(text || "{}");
    return (v && typeof v === "object" && !Array.isArray(v)) ? v : {};
  } catch (e) {
    return {};
  }
}
