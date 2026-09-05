// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// The file glyphs, READ FROM THE YAZI FLAVOR rather than copied out of it.
//
// ~/.config/yazi/flavors/ZENON.yazi/flavor.toml already carries 351 icon rules
// that were chosen once and are already right. Pasting them in here would make
// a second copy that starts identical and then drifts the first time one of
// them is corrected — which is exactly what nineteen copies of shellQuote did
// to this codebase. So the flavor stays the source and this parses it.
//
// It is not a TOML parser and does not try to be. The [icon] table is four
// arrays of the same two-key inline table:
//
//   [icon]
//   conds = [ { if = "dir",  text = " " }, ... ]
//   files = [ { name = "readme.md", text = " " }, ... ]
//   dirs  = [ { name = "projects", text = "󰲃 " }, ... ]
//   exts  = [ { name = "rs", text = " " }, ... ]
//
// One shape, no nesting, no multi-line strings, no escapes in the values —
// checked against the real file. Anything it cannot read it skips, and a miss
// costs one glyph, not a broken panel.

// Yazi writes a trailing space into every icon so its own list has a gutter.
// The layout here owns its spacing, so it comes off.
function parseRules(body) {
  const out = {};
  const rx = /\{\s*(?:name|if)\s*=\s*"((?:[^"\\]|\\.)*)"\s*,\s*text\s*=\s*"((?:[^"\\]|\\.)*)"\s*\}/g;
  let m;
  while ((m = rx.exec(body)) !== null) {
    out[m[1].toLowerCase()] = m[2].replace(/\s+$/, "");
  }
  return out;
}

// The four arrays out of the [icon] table. Sliced by locating each key and
// reading to its closing bracket, so a key that does not exist simply yields
// nothing rather than dragging the next one's rules in with it.
function parse(text) {
  const t = String(text || "");
  const icon = t.indexOf("\n[icon]");
  const body = icon < 0 ? t : t.slice(icon);
  const grab = (key) => {
    const at = body.search(new RegExp("^" + key + "\\s*=\\s*\\[", "m"));
    if (at < 0) return {};
    const end = body.indexOf("]", at);
    return parseRules(body.slice(at, end < 0 ? body.length : end));
  };
  return {
    conds: grab("conds"),
    files: grab("files"),
    dirs:  grab("dirs"),
    exts:  grab("exts")
  };
}

function extensionOf(name) {
  const n = String(name);
  const cut = n.lastIndexOf(".");
  // a leading dot is a hidden file, not an extension: ".bashrc" has none
  if (cut <= 0 || cut === n.length - 1) return "";
  return n.slice(cut + 1).toLowerCase();
}

// Yazi's own precedence: the most specific rule that matches wins. An exact
// filename beats an extension, and an extension beats the catch-all condition
// for "is a directory" or "is not". Directories are matched against `dirs` and
// never against `exts`, because "src.old" is a folder, not an .old file.
function glyphFor(maps, entry) {
  if (!maps || !entry) return "";
  const name = String(entry.name || "").toLowerCase();

  if (entry.isDir) {
    if (maps.dirs[name] !== undefined) return maps.dirs[name];
    return maps.conds["dir"] || "";
  }

  if (entry.isLink && entry.broken && maps.conds["orphan"] !== undefined)
    return maps.conds["orphan"];

  if (maps.files[name] !== undefined) return maps.files[name];

  const ext = extensionOf(name);
  if (ext && maps.exts[ext] !== undefined) return maps.exts[ext];

  if (entry.isExec && maps.conds["exec"] !== undefined) return maps.conds["exec"];
  if (entry.isLink && maps.conds["link"] !== undefined) return maps.conds["link"];
  return maps.conds["!dir"] || "";
}

// Where the flavor is. Named rather than written out, and derived from the
// config dir so a machine that moves XDG_CONFIG_HOME is still read correctly.
function flavorPath(configDir, flavor) {
  return configDir + "/yazi/flavors/" + flavor + ".yazi/flavor.toml";
}
