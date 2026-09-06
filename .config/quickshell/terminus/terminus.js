// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// TERMINUS' pure half — what a directory is, and the commands that change one.
// No QML in here; TerminusWindow draws it and runs these.

// ── reading a directory ───────────────────────────────────────────────────
// find, not ls. `ls -A1p` gives names and a trailing slash and nothing else,
// so a size or a date costs a stat per row; find hands over every field in one
// pass, and -printf says exactly which ones rather than leaving them to be
// picked out of a column layout meant for a human.
//
// The separators are \037 UNIT SEPARATOR between fields and \036 RECORD
// SEPARATOR between rows, not tab and newline. A filename may legally contain
// a newline — and a tab, and a quote — so the obvious choice silently splits
// one file into two rows and mis-sizes both. These two bytes are the ones
// ASCII set aside for this job and no tool puts them in a name.
//
//   %y  type as it sits on disk      — 'l' says this entry IS a symlink
//   %Y  type after following it      — 'd'/'f', or 'N' for a broken link
//   %m  permission bits, octal       — the executable bit, for the exec glyph
//   %s  size in bytes
//   %T@ mtime as a unix float
//   %f  the name alone, without the path
// Written as escapes, not as the literal bytes: they are invisible in an
// editor, they do not survive a copy through a terminal, and a reader has no
// way to tell a lone \037 from a stray space.
const FIELD = "\u001f";
const RECORD = "\u001e";

// The one -printf format, shared by the listing and by the search results, so
// the two cannot drift into producing rows of different shapes. Kept as the
// bare format as well, for the caller that hands find its arguments directly
// rather than writing a shell line — see statArgv.
const PRINTF_FMT = "%y\\037%Y\\037%m\\037%s\\037%T@\\037%p\\036";
const PRINTF = " -printf '" + PRINTF_FMT + "' ";

// A TRAILING SLASH on the search path, and it is not cosmetic.
//
// `find some-symlink-to-a-directory -maxdepth 1` prints nothing and exits 0:
// find treats the link as the file it is and never looks inside. So entering
// a symlinked directory in terminus produced an empty listing with no error to
// say why. `find some-symlink/` follows it, and a trailing slash on a real
// directory changes nothing at all — the printed paths are identical either
// way, single-slashed.
//
// Not `find -L`: that would resolve every entry as well, so %y would report
// the TARGET's type for each row and terminus would lose the one thing that
// tells it a row is a link.
function listPath(dir) {
  const d = String(dir);
  return d === "" || d.charAt(d.length - 1) === "/" ? d : d + "/";
}

function listCommand(dir) {
  return "find " + Strings.shellQuote(listPath(dir)) + " -maxdepth 1 -mindepth 1"
    + PRINTF + "2>/dev/null";
}

// The same listing, capped. A preview pane is a glance into a directory, and
// a glance at /usr/lib does not need forty thousand rows parsed and turned
// into objects to show you the first thirty.
function peekCommand(dir) {
  return "find " + Strings.shellQuote(listPath(dir)) + " -maxdepth 1 -mindepth 1"
    + PRINTF + "2>/dev/null | head -c 200000";
}

function parseListing(text, dir) {
  const rows = [];
  for (const rec of String(text || "").split(RECORD)) {
    if (rec === "") continue;
    const f = rec.split(FIELD);
    if (f.length < 6) continue;
    // %p, not %f: the search results need the full path and one format has to
    // serve both. The name is the tail of it.
    const full = f[5];
    const name = basename(full);
    if (name === "" || name === "." || name === "..") continue;
    const mode = parseInt(f[2], 8) || 0;
    rows.push({
      name: name,
      path: full,
      isDir: f[1] === "d",
      isLink: f[0] === "l",
      broken: f[1] === "N",
      // any of the three x bits — a file you could run earns its own glyph
      isExec: (mode & 73) !== 0,
      // kept whole, not just the exec bit: the permissions editor needs
      // somewhere to start, and re-statting the file to find out what it
      // already is would be asking a question find has already answered
      mode: mode,
      isHidden: name.charAt(0) === ".",
      size: parseInt(f[3], 10) || 0,
      mtime: parseFloat(f[4]) || 0
    });
  }
  return rows;
}

// ── paths ─────────────────────────────────────────────────────────────────
function joinPath(dir, name) {
  return dir === "/" ? "/" + name : dir + "/" + name;
}

function dirname(p) {
  const s = String(p);
  if (s === "/") return "/";
  const cut = s.lastIndexOf("/");
  return cut <= 0 ? "/" : s.slice(0, cut);
}

// The name without its extension, for yazi's `c n`. A leading dot is part of
// the name, not an extension: ".bashrc" has no stem to strip.
function stem(name) {
  const n = String(name);
  const cut = n.lastIndexOf(".");
  return cut > 0 ? n.slice(0, cut) : n;
}

// Trailing slashes are stripped first. fd marks a directory by appending one,
// and the obvious basename of "…/terminus/" is the empty string — which the row
// builder then threw away, so a search never showed a single directory.
function basename(p) {
  const s = String(p).replace(/\/+$/, "");
  if (s === "") return "/";
  const cut = s.lastIndexOf("/");
  return cut >= 0 ? s.slice(cut + 1) : s;
}

// The path as a row of pieces, each carrying the path it leads to, so the
// crumb bar is a set of jump targets rather than a label. Built here because
// it is string work, and the window should only have to render it.
function crumbs(path) {
  const out = [{ label: "/", path: "/" }];
  let at = "";
  for (const part of String(path).split("/")) {
    if (part === "") continue;
    at += "/" + part;
    out.push({ label: part, path: at });
  }
  return out;
}

// WHERE a result was found, said as briefly as it can be said.
//
// A result's own name is already in the NAME column, so the half worth a
// column of its own is the directory it came out of — and against a search
// started in ~/Projects, "spoot/src" says everything
// "/home/buck/Projects/spoot/src" does and fits. The search root itself is
// ".", the answer every tool gives; anything NOT under the root keeps its full
// path, because a relative name for it would be a lie.
function whereOf(path, base) {
  const dir = dirname(path);
  let b = String(base || "");
  if (b !== "/") b = b.replace(/\/+$/, "");
  if (b === "") return dir;
  if (dir === b) return ".";
  const pre = b === "/" ? "/" : b + "/";
  return dir.indexOf(pre) === 0 ? dir.slice(pre.length) : dir;
}

// ── shape of the list ─────────────────────────────────────────────────────
// Directories first, always, whatever the sort is. Not a preference: a size
// sort that interleaves folders among files makes the folders unfindable, and
// every file manager worth using has settled on the same rule.
function sortEntries(rows, key, desc) {
  const dir = desc ? -1 : 1;
  const n = rows.length;

  // DECORATE, SORT, UNDECORATE — and the reason is arithmetic.
  //
  // The comparator used to read its key off the row on every comparison: a
  // lower-cased name, and for `kind` a rank and an extension worked out from
  // the name each time. A sort asks n log n questions, so four thousand rows
  // meant something like fifty thousand extractions to carry four thousand
  // rows' worth of information. Pulling the keys out once first is a linear
  // pass and leaves the comparator doing nothing but comparing.
  //
  // `i` is carried so ties keep the order they arrived in — a stable sort, so
  // a directory cannot shuffle under the cursor between two identical sorts.
  const dec = new Array(n);
  const kind = key === "kind";
  // "usage" is the disk-usage view's order: what is BIG, regardless of what
  // it is. It reads `du` — the measured recursive size, which the caller
  // attaches — and falls back to the entry's own size for a file, which is
  // already the whole truth about a file.
  const usage = key === "usage";
  for (let i = 0; i < n; ++i) {
    const r = rows[i];
    const nm = displaySound_(r);
    dec[i] = {
      r: r,
      // Directories first, always — EXCEPT in the usage view, where that rule
      // is the one thing you do not want: a 4GB file below every empty folder
      // answers the opposite of the question being asked.
      d: usage ? 0 : (r.isDir ? 0 : 1),
      nm: nm,
      num: usage ? (r.du !== undefined && r.du !== null ? r.du : r.size)
         : (key === "size" ? r.size : (key === "time" ? r.mtime : 0)),
      kr: kind ? kindRank(r.name) : 0,
      ex: kind ? extOf(nm) : "",
      i: i
    };
  }

  const byName = (a, b) => a.nm < b.nm ? -1 : (a.nm > b.nm ? 1 : 0);
  let cmp;
  if (key === "size" || key === "time" || usage)
    cmp = (a, b) => (a.num - b.num) * dir || byName(a, b);
  else if (kind)
    // Broad type first, extension second, name third — so every .jpg lands
    // together inside the pictures rather than merely near them.
    cmp = (a, b) => (a.kr - b.kr) * dir
      || (a.ex < b.ex ? -1 : (a.ex > b.ex ? 1 : 0)) * dir
      || byName(a, b);
  else
    cmp = (a, b) => byName(a, b) * dir;

  dec.sort((a, b) => (a.d - b.d) || cmp(a, b) || (a.i - b.i));

  const out = new Array(n);
  for (let i = 0; i < n; ++i) out[i] = dec[i].r;
  return out;
}

// The query half on its own, for filtering a list that is ALREADY sorted.
// Sorting is order and filtering is membership, and filtering never disturbs
// order — so the sort can happen once when the directory or the sort key
// changes, and a keystroke only has to filter. Doing both per keystroke meant
// re-sorting a few thousand rows to answer a question about a substring.
// How well a name answers a query, or -1 for not at all.
//
// Substring first, because that is what most typing is and it should win
// outright: "conf" means .config, not some scattering of c-o-n-f across a
// longer name. Only when nothing contains the query does it fall back to a
// SUBSEQUENCE — the letters in order but not adjacent — which is what makes
// "cfg" reach .config and "dwn" reach Downloads.
//
// The score orders the survivors rather than deciding them. Higher is better,
// and every rule below is about putting the name you meant at the top:
// matching at the start beats matching in the middle, matching at a word
// boundary beats matching mid-word, and adjacent letters beat scattered ones.
// Word boundary, by character code rather than by regex.
//
// This is asked once per candidate per keystroke and, in the subsequence
// branch, once per LETTER of the query per candidate — so a four-thousand-row
// directory ran tens of thousands of regex tests for every key pressed. The
// question is only "is the character before this one alphanumeric", which is
// four comparisons.
function wordStart_(hay, k) {
  if (k === 0) return true;
  const c = hay.charCodeAt(k - 1);
  return !((c >= 97 && c <= 122) || (c >= 48 && c <= 57));
}

function fuzzyScore(hay, q) {
  if (q === "") return 0;
  const at = hay.indexOf(q);
  if (at >= 0) {
    // 1000 keeps every substring hit above every subsequence one
    let sc = 1000 - at;
    if (at === 0) sc += 200;
    else if (wordStart_(hay, at)) sc += 100;
    return sc - hay.length * 0.01;
  }

  let sc = 0, from = 0, last = -2, runs = 0;
  for (let i = 0; i < q.length; ++i) {
    const k = hay.indexOf(q.charAt(i), from);
    if (k < 0) return -1;
    // adjacent to the previous letter: the run is what makes a scattered
    // match feel deliberate rather than accidental
    if (k === last + 1) { runs++; sc += 8 + runs; }
    else { runs = 0; sc += 2; }
    if (k === 0) sc += 12;
    else if (wordStart_(hay, k)) sc += 6;
    last = k;
    from = k + 1;
  }
  return sc - hay.length * 0.02;
}

// Filtered and RANKED. The old version filtered on a substring and left the
// order alone; a fuzzy match without ranking puts the accidental hits among
// the intended ones, which is worse than not matching them at all.
//
// The sort is stable in effect because the score carries a length penalty and
// ties fall back to the name, so a directory does not shuffle under the cursor
// between two identical filters.
function filterQuery(rows, query) {
  const q = String(query || "").toLowerCase();
  if (q === "") return rows;
  const scored = [];
  for (let i = 0; i < rows.length; ++i) {
    const sc = fuzzyScore(displaySound_(rows[i]), q);
    if (sc >= 0) scored.push({ row: rows[i], sc: sc, i: i });
  }
  scored.sort((a, b) => (b.sc - a.sc) || (a.i - b.i));
  const out = [];
  for (let i = 0; i < scored.length; ++i) out.push(scored[i].row);
  return out;
}

// The lower-cased haystack for a row, cached ON THE ROW the first time it is
// asked for.
//
// Every sort compares names case-insensitively and every filter matches
// against them, so a four-thousand-row directory was calling toLowerCase about
// fifty thousand times per sort and again on every letter typed. Lazily rather
// than at parse: a directory that is listed and never sorted or filtered — the
// second pane's, most of the time — pays nothing.
function displaySound_(r) {
  if (r.hay === undefined) r.hay = String(r.name).toLowerCase();
  return r.hay;
}

function filterEntries(rows, query, showHidden) {
  const q = String(query || "").toLowerCase();
  // The common call is (rows, "", true) — every listing, both panes, on every
  // sort change. Handing back the same array rather than a copy of it is the
  // difference between allocating four thousand-element arrays for nothing and
  // not.
  if (q === "" && showHidden) return rows;
  return rows.filter((r) => {
    if (!showHidden && r.isHidden) return false;
    return q === "" || displaySound_(r).indexOf(q) >= 0;
  });
}

// ── how it reads ──────────────────────────────────────────────────────────
// Binary units, because that is what the filesystem allocates in and what
// every other tool on this machine reports.
function formatSize(n) {
  const v = Number(n) || 0;
  if (v >= 1073741824) return (v / 1073741824).toFixed(1) + " GiB";
  if (v >= 1048576) return (v / 1048576).toFixed(1) + " MiB";
  if (v >= 1024) return (v / 1024).toFixed(1) + " KiB";
  return v + " B";
}

// A date you can act on: how long ago while that is still the useful answer,
// and the actual day once "31d ago" has stopped being one.
function formatTime(epoch) {
  const t = Number(epoch) || 0;
  if (t <= 0) return "";
  const age = Date.now() / 1000 - t;
  if (age < 60) return "just now";
  if (age < 3600) return Math.floor(age / 60) + "m ago";
  if (age < 86400) return Math.floor(age / 3600) + "h ago";
  if (age < 2592000) return Math.floor(age / 86400) + "d ago";
  const d = new Date(t * 1000);
  const pad = (n) => String(n).padStart(2, "0");
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
}

// What the selection adds up to, for the status strip. Directories are left
// out of the total rather than counted at their entry size, which is the size
// of the directory RECORD — 4096 bytes for a folder holding a gigabyte — and
// would make the number a lie.
function selectionSize(rows) {
  let n = 0;
  for (const r of rows) if (!r.isDir) n += r.size;
  return n;
}

// ── colour, as yazi decides it ────────────────────────────────────────────
// Straight off the [filetype] rules in the ZENON flavor, in the order they are
// listed there, because yazi takes the FIRST rule that matches:
//
//   image/*                       #b6e0a4   Zenon.green
//   {audio,video}/*               #e0d8a4   Zenon.sand
//   archives                      #fab387   Zenon.yellow
//   application/{pdf,doc,rtf}     #9bbfbf   Zenon.cyan
//   inode/empty                   #a0a09b   grey
//   orphan                        #e78284   Zenon.red
//   link                          #c8a4e0   Zenon.magenta
//   exec                          #fab387   Zenon.yellow
//   directory fallback            #9bbfbf   Zenon.cyan
//   file fallback                 #dfdfdd   Zenon.white
//
// Yazi asks a mime database; this asks the extension. That is a real
// difference and it is the honest one to make here — a mime lookup is a
// process per row, and the answer only ever changes the colour of a name.
const CAT_EXTS = {
  media: {
    mp3:1, flac:1, wav:1, ogg:1, oga:1, opus:1, m4a:1, aac:1, wma:1, mid:1,
    mp4:1, mkv:1, webm:1, avi:1, mov:1, wmv:1, flv:1, m4v:1, mpg:1, mpeg:1,
    "3gp":1, ts:1
  },
  archive: {
    zip:1, rar:1, "7z":1, tar:1, gz:1, tgz:1, bz2:1, xz:1, zst:1, lzma:1,
    lz4:1, cpio:1, arj:1, xar:1, cab:1, iso:1, deb:1, rpm:1, pkg:1, jar:1
  },
  document: {
    pdf:1, doc:1, docx:1, rtf:1, odt:1, epub:1, djvu:1, ps:1
  }
};

function categoryOf(name) {
  if (isImage(name)) return "image";
  const n = String(name);
  const cut = n.lastIndexOf(".");
  if (cut <= 0) return "";
  const e = n.slice(cut + 1).toLowerCase();
  if (CAT_EXTS.media[e]) return "media";
  if (CAT_EXTS.archive[e]) return "archive";
  if (CAT_EXTS.document[e]) return "document";
  return "";
}

// ── what KIND of thing a name is ──────────────────────────────────────────
// Broader than categoryOf, which lumps audio and video together as "media"
// because that is all the colouring rules need. Sorting wants them apart: a
// folder of downloads is far more useful with the music in one run and the
// films in another.
//
// The order IS the sort order. Pictures first because a folder of them is the
// commonest reason to reach for this, and the two nameless groups last —
// "other" is a file with an extension nothing here recognises and "file" one
// with no extension at all, which is usually a script or a README.
const KIND_ORDER = ["image", "video", "audio", "document", "text", "archive",
                    "other", "file"];

// Text and code, which is most of what is in most directories and was landing
// in "other" — a column that calls a .md file "other" is a column nobody
// reads. Not a preview question: isText is about what the row SAYS it is, and
// bat decides what can actually be shown.
const TEXT_EXTS = {
  txt: 1, md: 1, markdown: 1, rst: 1, log: 1, csv: 1, tsv: 1,
  json: 1, yaml: 1, yml: 1, toml: 1, ini: 1, conf: 1, cfg: 1, env: 1,
  xml: 1, html: 1, htm: 1, css: 1, scss: 1, svg: 0,
  sh: 1, bash: 1, zsh: 1, fish: 1, ps1: 1,
  c: 1, h: 1, cc: 1, cpp: 1, hpp: 1, rs: 1, go: 1, py: 1, rb: 1, pl: 1,
  lua: 1, js: 1, mjs: 1, ts: 1, tsx: 1, jsx: 1, java: 1, kt: 1, cs: 1,
  qml: 1, vim: 1, el: 1, sql: 1, diff: 1, patch: 1, desktop: 1, service: 1
};

function isText(name) {
  return TEXT_EXTS[extOf(name)] === 1;
}

function extOf(name) {
  const n = String(name);
  const cut = n.lastIndexOf(".");
  // a leading dot is a hidden file, not an extension: ".bashrc" has none
  return cut > 0 ? n.slice(cut + 1).toLowerCase() : "";
}

function kindOf(name) {
  if (isImage(name)) return "image";
  if (isVideo(name)) return "video";
  if (isAudio(name)) return "audio";
  if (isArchive(name)) return "archive";
  const e = extOf(name);
  if (e === "") return "file";
  if (CAT_EXTS.document[e] || isFont(name)) return "document";
  if (isText(name)) return "text";
  return "other";
}

// ONE LOOKUP PER EXTENSION, EVER — not a walk through five tables per row.
//
// kindOf asks isImage, then isVideo, then isAudio, then isArchive, each of
// which splits the name again, and the kind sort asks it once per row. On a
// four-thousand-row directory that was the whole cost of the sort.
//
// The answer for a given extension is a constant, so it is worked out once and
// remembered. Asked of kindOf itself rather than by reading the tables
// directly: the tables are declared further down this file, so naming them
// here is a forward reference Qt warns about — and, worse, it would be a
// second copy of kindOf's order of questions, free to drift from the first.
// A directory holds a handful of distinct extensions, so this fills up almost
// immediately and then costs one property read.
var KIND_BY_EXT_ = ({});

function kindRank(name) {
  const e = extOf(name);
  if (e === "") return KIND_ORDER.indexOf("file");
  let r = KIND_BY_EXT_[e];
  if (r === undefined) {
    r = KIND_ORDER.indexOf(kindOf("x." + e));
    if (r < 0) r = KIND_ORDER.length;
    KIND_BY_EXT_[e] = r;
  }
  return r;
}

// ── previews ──────────────────────────────────────────────────────────────
// What Qt's own image loader will open. Checked by extension rather than by
// asking `file`, because a preview that costs a process per keypress is a
// preview you feel — and being wrong here shows a glyph instead of a picture,
// which is the cheapest possible way to be wrong.
const IMAGE_EXTS = {
  png: 1, jpg: 1, jpeg: 1, gif: 1, bmp: 1, webp: 1, svg: 1, ico: 1,
  tif: 1, tiff: 1, avif: 1, jxl: 1, pbm: 1, pgm: 1, ppm: 1, xbm: 1, xpm: 1
};

// Video, for the thumbnails and the preview pane. Separate from isImage
// because the two are made differently — Qt decodes a picture itself, and a
// video has to have a frame pulled out of it first.
const VIDEO_EXTS = {
  mp4: 1, mkv: 1, webm: 1, avi: 1, mov: 1, wmv: 1, flv: 1, m4v: 1,
  mpg: 1, mpeg: 1, "3gp": 1, ts: 1, ogv: 1, m2ts: 1, mts: 1, vob: 1
};

function isVideo(name) {
  const n = String(name);
  const cut = n.lastIndexOf(".");
  if (cut <= 0) return false;
  return VIDEO_EXTS[n.slice(cut + 1).toLowerCase()] === 1;
}

function isImage(name) {
  const n = String(name);
  const cut = n.lastIndexOf(".");
  if (cut <= 0) return false;
  return IMAGE_EXTS[n.slice(cut + 1).toLowerCase()] === 1;
}

// ── previewing something that is not a picture ────────────────────────────
// bat, not head, when bat is there: it syntax-highlights, it knows markdown,
// and it stops at a line range so a huge file costs the same as a small one.
// --color=always because it is not writing to a terminal and would otherwise
// helpfully turn colour off.
function batCommand(path) {
  // --theme=ansi is the whole trick for keeping this in Zenon. It makes bat
  // emit ONLY the sixteen base ANSI colours instead of a theme's own hexes,
  // and the sixteen are ours to define — see xterm256 below. The alternative
  // was writing a Zenon .tmTheme for bat, which is a second copy of the
  // palette living outside Zenon.qml.
  // 90 lines, not 300. The pane shows forty at most, and every line past
  // that is paid for three times: bat highlights it, ansiToRich turns it into
  // markup, and Qt lays that markup out as rich text. That last one is the
  // expensive part and it is proportional to what it is given.
  return "bat --color=always --theme=ansi --style=plain --paging=never"
    + " --line-range=1:90 -- "
    + Strings.shellQuote(path) + " 2>/dev/null";
}

// A PDF is a picture of a page. pdftoppm renders the first one at a modest
// dpi into the cache directory; -singlefile keeps the name predictable so the
// pane can point at it without parsing pdftoppm's output.
function pdfCommand(path, outStem) {
  // mkdir first: the rendered page lives with the thumbnails now rather than
  // loose in the cache root, and on a fresh machine that directory does not
  // exist until the first thumbnail batch has made it.
  return "mkdir -p " + Strings.shellQuote(dirname(outStem)) + "; "
    + "pdftoppm -png -f 1 -l 1 -r 72 -singlefile -- "
    + Strings.shellQuote(path) + " " + Strings.shellQuote(outStem) + " 2>/dev/null";
}

// Everything terminus caches on disk lives under one directory, so clearing it is
// one rm and nothing is left behind in the cache root.
function terminusCacheDir() {
  return Paths.cacheDir() + "/terminus";
}

// Audio, which until now was only ever half of "media". It earns its own
// list because it previews differently from everything else: there is nothing
// to look at unless the file happens to carry cover art, and the interesting
// part is what the tags say.
const AUDIO_EXTS = {
  mp3: 1, flac: 1, wav: 1, ogg: 1, oga: 1, opus: 1, m4a: 1, aac: 1, wma: 1,
  aiff: 1, aif: 1, ape: 1, wv: 1, mka: 1, mid: 1, midi: 1
};

function isAudio(name) {
  return !!AUDIO_EXTS[extOf(name)];
}

// A font is previewed by BEING the preview: Qt can load the file and draw with
// it, which says more in one line of specimen than any list of facts about it.
// Only the formats Qt's FontLoader actually opens are listed — woff and woff2
// are web wrappers it does not read, and offering a preview that silently
// falls back to the default font would be worse than showing none.
const FONT_EXTS = { ttf: 1, otf: 1, ttc: 1, pfb: 1 };

function isFont(name) {
  return !!FONT_EXTS[extOf(name)];
}

function isPdf(name) {
  return /\.pdf$/i.test(String(name));
}

// ── disks ─────────────────────────────────────────────────────────────────
// lsblk in JSON, so there is nothing to parse by hand and nothing to break
// when a label contains a space. Only the leaves are of interest: a whole
// disk is not something you mount, its partitions are.
// FSAVAIL and FSSIZE come from lsblk itself, so knowing how full a disk is
// costs nothing extra — no df, no second process. They are only populated for
// a MOUNTED filesystem, which is exactly when the number is worth showing.
function disksCommand() {
  return "lsblk -J -o NAME,PATH,LABEL,SIZE,MOUNTPOINT,RM,TYPE,FSTYPE,FSAVAIL,FSSIZE"
    + " 2>/dev/null";
}

function parseDisks(text) {
  let tree;
  try { tree = JSON.parse(String(text || "{}")); } catch (e) { return []; }
  const out = [];

  const walk = (node) => {
    const kids = node.children || [];
    for (const k of kids) walk(k);
    // a node with children is a container, not a thing to mount
    if (kids.length > 0) return;
    if (node.type !== "part" && node.type !== "disk" && node.type !== "rom") return;
    // no filesystem means nothing to mount; swap and the boot partitions are
    // not places you browse
    const fs = String(node.fstype || "");
    if (fs === "" || fs === "swap") return;
    const mp = node.mountpoint;
    if (mp === "[SWAP]") return;
    out.push({
      name: String(node.label || node.name || ""),
      path: String(node.path || ""),
      size: String(node.size || ""),
      mount: mp ? String(mp) : "",
      removable: !!node.rm,
      fstype: fs,
      // strings as lsblk formats them ("412.3G"), or "" when not mounted
      avail: String(node.fsavail || ""),
      fsSize: String(node.fssize || "")
    });
  };

  for (const d of (tree.blockdevices || [])) walk(d);
  return out;
}

// Mounts the system is standing on. Offering to eject one is offering to take
// the floor out from under everything — udisks would refuse a busy /, but /home
// or a data partition might well unmount and take your session's files with it,
// and the honest answer is not to put the button there at all.
//
// Matched on the mountpoint rather than on `rm`, because removable says how the
// hardware is attached and this is a question about what the mount is FOR: an
// external disk holding /home is exactly as unejectable as an internal one.
const SYSTEM_MOUNTS = {
  "/": 1, "/home": 1, "/boot": 1, "/boot/efi": 1, "/efi": 1,
  "/usr": 1, "/var": 1, "/etc": 1, "/nix": 1, "/opt": 1, "/srv": 1
};

function isSystemMount(mp) {
  const m = String(mp || "");
  if (m === "") return false;                    // not mounted: safe to mount
  if (SYSTEM_MOUNTS[m]) return true;
  // anything nested under the boot partitions counts too
  return m.indexOf("/boot/") === 0 || m.indexOf("/efi/") === 0;
}

// udisksctl, not `mount`: it works without root for a user-session device,
// which is the entire reason a removable disk can be mounted from a file
// manager at all.
function mountCommand(path) {
  return "udisksctl mount -b " + Strings.shellQuote(path) + " 2>&1";
}

function unmountCommand(path) {
  return "udisksctl unmount -b " + Strings.shellQuote(path) + " 2>&1";
}

// What identifies a disk for "has the set changed" — the paths, in order, so
// plugging something in is a different string and a remount is not.
function diskKey(disks) {
  return disks.map((d) => d.path + ":" + d.mount).join("|");
}

// ── thumbnails ────────────────────────────────────────────────────────────
// They live in morpheus/thumbs.js now, shared with Picasso: the same pictures
// were being cached twice, at two sizes, under two names, in two directories.
// Nothing about them is terminus-specific, so nothing about them is here.

// ── ANSI to rich text ─────────────────────────────────────────────────────
// bat speaks SGR escapes and Qt's Text does not, so the colours have to be
// translated rather than stripped. Only the codes bat actually emits are
// handled — 24-bit and 256-colour foregrounds, bold, and the resets — and
// anything else is dropped, which loses a colour and never breaks the markup.
//
// The 256-colour cube is computed rather than tabled: 16-231 is a 6x6x6 cube
// and 232-255 is a grey ramp, both of which are formulas.
function xterm256(n) {
  // The sixteen, as Zenon defines them — including its own names for the
  // bright three it actually differentiates: bright black is `muted`, bright
  // red is `pink`, bright yellow is `sand`. The rest of the brights are the
  // base colour, because Zenon does not have a second one for them.
  const Z = Strings.zenonHex();
  const basic = [Z.black, Z.red, Z.green, Z.yellow, Z.blue, Z.magenta,
                 Z.cyan, Z.white, Z.muted, Z.pink, Z.green, Z.sand,
                 Z.blue, Z.magenta, Z.cyan, Z.white];
  if (n < 16) return basic[n];
  if (n < 232) {
    const c = n - 16;
    const lv = [0, 95, 135, 175, 215, 255];
    const hex = (v) => ("0" + v.toString(16)).slice(-2);
    return "#" + hex(lv[Math.floor(c / 36) % 6])
               + hex(lv[Math.floor(c / 6) % 6]) + hex(lv[c % 6]);
  }
  const g = 8 + (n - 232) * 10;
  const hx = ("0" + g.toString(16)).slice(-2);
  return "#" + hx + hx + hx;
}

function ansiToRich(text) {
  const src = String(text || "");
  let out = "";
  let open = 0;
  let i = 0;
  while (i < src.length) {
    const esc = src.indexOf("\u001b[", i);
    if (esc < 0) { out += Strings.escapeHtml(src.slice(i)); break; }
    out += Strings.escapeHtml(src.slice(i, esc));
    const end = src.indexOf("m", esc);
    if (end < 0) { i = src.length; break; }
    const codes = src.slice(esc + 2, end).split(";").map((n) => parseInt(n, 10) || 0);
    let k = 0;
    while (k < codes.length) {
      const c = codes[k];
      if (c === 0) {
        while (open > 0) { out += "</span>"; open--; }
        k++;
      } else if (c === 1) {
        out += "<span style=\"font-weight:700;\">"; open++; k++;
      } else if (c === 38 && codes[k+1] === 2) {
        out += "<span style=\"color:rgb(" + (codes[k+2]|0) + ","
          + (codes[k+3]|0) + "," + (codes[k+4]|0) + ");\">";
        open++; k += 5;
      } else if (c === 38 && codes[k+1] === 5) {
        out += "<span style=\"color:" + xterm256(codes[k+2]|0) + ";\">";
        open++; k += 3;
      } else if (c >= 30 && c <= 37) {
        out += "<span style=\"color:" + xterm256(c - 30) + ";\">"; open++; k++;
      } else if (c >= 90 && c <= 97) {
        out += "<span style=\"color:" + xterm256(c - 90 + 8) + ";\">"; open++; k++;
      } else k++;
    }
    i = end + 1;
  }
  while (open > 0) { out += "</span>"; open--; }
  // <pre>, because Qt's rich text collapses newlines and runs of spaces like
  // any other HTML — without it the whole file rendered as a single line.
  return "<pre>" + out + "</pre>";
}


// A file is "text" if the first block holds no NUL. That is the same test
// every other tool uses, it needs nothing installed, and it costs a scan of
// what has already been read.
function looksBinary(text) {
  return String(text || "").indexOf("\u0000") >= 0;
}

// ── searching ─────────────────────────────────────────────────────────────
// Two searches, because yazi has two and they answer different questions:
// `s` is "where is the file called…", `S` is "which files contain…".
//
// Both print NUL-separated paths so a filename with a newline in it survives,
// and both are capped: a search that returns forty thousand rows has not
// answered anything, and building that list costs more than running it.
// Recursive, and FUZZY — artemis' two-step, in one pipe.
//
// fd on its own matches its argument as a regex against the filename, so
// "jnwn" finds nothing and "Terminus Window" finds nothing either. Artemis solved
// that by listing everything with fd and then ranking with `fzf --filter`,
// which is what makes typing four letters of a path work. Same here, minus
// artemis' index file: artemis re-searches one fixed root often enough to cache
// it, and terminus searches whatever directory you happen to be in.
//
// Directories first, exactly as artemis orders them, so they win ties. fd marks
// them with a trailing slash, which parseListing now strips.
// MATCHED AGAINST THE NAME, not against the whole path.
//
// fzf was handed complete paths, so the letters you typed could be satisfied
// by directory names three levels up — `spt` matched
// `/home/buck/Projects/spoot/src/main.rs` through the middle of "Projects" and
// scored it above a file actually called `spt`. That is what made the results
// read as random: every one of them was a genuine fuzzy hit, on a string you
// were not searching.
//
// `-d / --nth -1` restricts both the match and the score to the last path
// segment, which is the thing being named. The whole line is still printed.
function findCommand(dir, query) {
  const d = Strings.shellQuote(dir);
  const q = Strings.shellQuote(String(query).trim());
  // DIRECTORIES FIRST, each group ranked on its own. Both were fed through one
  // fzf before, which scored them together and interleaved them — a folder
  // called exactly what you typed could sit below eight files that merely
  // contain the letters. A place you can go is a different kind of answer from
  // a file you can open, and it is nearly always the one being looked for.
  //
  // `--nth -2` for the directories and `-1` for the files, because fd ends a
  // directory with a slash — so its last field is the empty string, and every
  // directory scored zero and vanished from the results entirely. The caller
  // strips the trailing slash again when it parses.
  const rank = (nth) => " | fzf --filter " + q + " -d / --nth " + nth
    + " 2>/dev/null";
  return "{ fd -t d -H --no-ignore --color=never . " + d + " 2>/dev/null"
    + rank(-2)
    + " ; fd -t f -H --no-ignore --color=never . " + d + " 2>/dev/null"
    + rank(-1)
    + " ; } | head -n 500 | tr '\\n' '\\0'";
}

// Sorted, because rg's is a PARALLEL walk and the order it finishes in is not
// an order at all — the same query twice ran the same files past you in two
// different arrangements. There is no relevance to preserve here the way there
// is for a name search: every one of these files contains what you asked for,
// so the useful order is the one you can predict.
// TWO THINGS MADE THIS TAKE A MINUTE AND A HALF, and they compounded.
//
// `--no-ignore` AND `--hidden` together switch off every filter ripgrep has:
// no .gitignore, no .ignore, no skipping of dot-directories. Pointed at a home
// directory that is what it says — walk .cache, .cargo/registry, the Steam
// library, all of it. Measured searching $HOME for "function": either flag on
// its own finishes in under a tenth of a second, and the two together took
// 79.2 seconds. Yazi passes neither; `rg --color=never --files-with-matches
// --smart-case` is its whole content search, which is why it answers instantly
// on the same tree.
//
// And `sort` sat between rg and the cap. `head -c` closes the pipe when it has
// enough, which is what lets rg stop early — but sort cannot emit its first
// byte until its input has ENDED, so the cap could never reach rg and the walk
// always ran to completion. The bound has to come before the sort to be a
// bound at all.
//
// HIDDEN FILES YES, .local NO — and that pairing is the whole answer.
//
// Plain --hidden costs 79 seconds searching $HOME, and the cap does not save
// you: a common word fills 2000 matches early and head closes the pipe, so rg
// dies young, but a RARE one — a name, which is what you search for most —
// never fills it, and rg walks every byte before it can say it found four
// things. "function" answered instantly and "kbuck" took 72 seconds from the
// same command on the same tree, which is what made this so hard to see.
//
// But the cost is not spread across the hidden directories. It is ONE of them.
// Measured for "kbuck" from ~:
//
//   no --hidden                  0.0s      24 hits
//   --hidden                    79.4s     846 hits
//   --hidden, minus .local       0.7s     840 hits
//
// .local is 819GB of Steam library on this machine and contributed SIX of the
// 846. Everything people actually grep for in a hidden directory — .config,
// .cache, dotfiles at the top of home — is in the other 840, and it arrives in
// under a second. So the exclusion is one entry rather than a policy.
//
// It is also scoped rather than absolute: the glob is relative to the search
// ROOT, so standing in ~/.local and searching still searches it. It only means
// "do not descend into .local on your way somewhere else".
//
// The rest: ripgrep's own ignore rules are respected, and the result count is
// capped where the cap can still be felt upstream. --smart-case is yazi's too
// — a lower-case query matches either case, one with a capital means it.
//
// Sorted AFTER that, because rg's is a parallel walk and the order it finishes
// in is not an order — the same query twice ran the same files past you in two
// different arrangements. Every one of these files contains what you asked
// for, so the useful order is the one you can predict. Past the cap it is the
// first 2000 rg found rather than the first 2000 alphabetically; that is the
// price of being able to stop it, and a search that broad is being narrowed
// again anyway.
function grepCommand(dir, query) {
  return "rg --files-with-matches --smart-case --null --color=never --hidden"
    + " -g " + Strings.shellQuote("!.local")
    + " -- " + Strings.shellQuote(query) + " " + Strings.shellQuote(dir)
    + " 2>/dev/null | head -z -n 2000 | sort -z | head -c 400000";
}

// A found path becomes the same row shape the listing produces, so one
// delegate draws both. stat is asked once for the whole set rather than once
// per path — the difference on a two thousand row result is seconds.
// AS ARGV, NOT AS A SHELL LINE, and the difference is the whole point.
//
// Linux caps a SINGLE argument at MAX_ARG_STRLEN — 32 pages, 128KB — while the
// whole list may run to ARG_MAX, 2MB. Joining thousands of result paths into
// one `sh -c "find … "` string puts the entire search inside one argument, and
// a content search across a large tree goes past 128KB easily: 2722 matches
// measured 291KB here, and execve refused it with E2BIG.
//
// The failure was invisible from the outside. The search itself succeeded, the
// stat that turns its paths into rows never started, and the results came back
// empty — so a search that matched too much looked exactly like a search that
// matched nothing.
//
// Handed to find as separate arguments each path is its own short argument, so
// only the 2MB total applies, and grepCommand's own 400KB output cap keeps the
// whole list an order of magnitude below it.
//
// No `2>/dev/null` any more, because there is no shell to redirect with. That
// is acceptable here: every path came out of a search that had just listed it,
// so a path find cannot stat is a file that vanished in between — rare, and
// worth a line in the log rather than silence.
function statArgv(paths) {
  return ["find"].concat(paths).concat(["-maxdepth", "0", "-printf", PRINTF_FMT]);
}

// Results come back through the same parser the listing uses, because they are
// the same rows — that is the whole point of sharing one -printf format.
function parseStat(text) {
  return parseListing(text, "");
}

// What a directory actually holds. `du -sb` walks it, which is the only way
// to know — a directory's own size field is the size of the RECORD, 4096 bytes
// for a folder containing a gigabyte. It is asked for on demand, never while
// drawing a list: walking every row of /home would take longer than the panel.
function sizeCommand(paths) {
  return "du -sbc -- " + paths.map((p) => Strings.shellQuote(p)).join(" ")
    + " 2>/dev/null | tail -1 | cut -f1";
}

// ── the verbs ─────────────────────────────────────────────────────────────
// ── how big a folder really is ────────────────────────────────────────────
// A directory's `size` is the size of its RECORD — 4096 bytes for a folder
// holding a gigabyte — so the listing shows a dash rather than a number that
// is never the one anybody means. The real answer costs a walk of the whole
// tree, which is why it is asked for rather than offered.
//
// -sb, not -sbc: one line per path and no total, because several folders can
// be measured at once and each needs its own answer. The output is
// "bytes<TAB>path", and paths can contain anything except a tab or a newline,
// so the first tab is the only split that is safe.
function dirSizeCommand(paths) {
  return "du -sb -- " + paths.map((p) => Strings.shellQuote(p)).join(" ")
    + " 2>/dev/null";
}

function parseDirSizes(text) {
  const out = {};
  for (const line of String(text || "").split("\n")) {
    const cut = line.indexOf("\t");
    if (cut <= 0) continue;
    const n = parseInt(line.slice(0, cut), 10);
    const p = line.slice(cut + 1);
    if (p !== "" && n >= 0) out[p] = n;
  }
  return out;
}

// A shell where you are standing. The same xdg-terminal-exec shape the bar's
// own click actions use.
function shellCommand(dir) {
  return "xdg-terminal-exec --title=terminus-shell -e sh -c "
    + Strings.shellQuote("cd " + Strings.shellQuote(dir) + " && exec $SHELL")
    + " >/dev/null 2>&1 &";
}

// yazi's `a`: a trailing slash means a directory, anything else a file.
// A NAME NOTHING IN THIS DIRECTORY IS USING.
//
// Creating something now makes it first and asks what to call it second, so it
// has to arrive with a name — "new file", or "new file 2" if that is taken.
// Worked out from the listing already in hand rather than by asking the disk:
// the listing is what the row will appear in, and a name free in it is free.
function freeName(rows, base) {
  const taken = {};
  for (let i = 0; i < rows.length; ++i) taken[rows[i].name] = true;
  if (!taken[base]) return base;
  for (let i = 2; i < 1000; ++i) {
    const n = base + " " + i;
    if (!taken[n]) return n;
  }
  return base + " " + Date.now();
}

function createCommand(dir, name) {
  const target = joinPath(dir, name.replace(/\/+$/, ""));
  if (/\/$/.test(name)) return "mkdir -p -- " + Strings.shellQuote(target);
  return "mkdir -p -- " + Strings.shellQuote(dirname(target))
    + " && touch -- " + Strings.shellQuote(target);
}

// yazi's `D`, which is not the trash. Kept separate from trashCommand on
// purpose: one of these is recoverable and the other is not, and they should
// not be reachable by the same key or built by the same function.
function deleteCommand(paths) {
  return "rm -rf -- " + paths.map((p) => Strings.shellQuote(p)).join(" ");
}

// gio open, NOT xdg-open, and the difference is TERMINAL APPLICATIONS.
//
// xdg-open on this system falls through to its generic branch, which runs the
// handler's Exec line as a plain child. For a desktop entry carrying
// `Terminal=true` — nvim's, and every other TUI's — that means nvim is started
// with no terminal attached at all: no window appears, nothing is drawn, and
// the process sits there forever. `ps` after a few attempts showed a pile of
// headless `nvim <file>` children of xdg-open and not one surface on screen.
//
// GLib honours Terminal=true and spawns the entry through xdg-terminal-exec,
// which lands in foot. Verified both ways on the same text file: xdg-open gave
// an orphan nvim, gio open gave `foot -e nvim <file>` and a window.
function openCommand(path) {
  return "gio open " + Strings.shellQuote(path) + " >/dev/null 2>&1 &";
}

function mkdirCommand(dir, name) {
  return "mkdir -p -- " + Strings.shellQuote(joinPath(dir, name));
}

// -T so a rename onto an existing DIRECTORY fails loudly instead of quietly
// moving the source inside it, which is mv's default and is never what a
// rename meant.
function renameCommand(path, newName) {
  return "mv -T -- " + Strings.shellQuote(path) + " "
    + Strings.shellQuote(joinPath(dirname(path), newName));
}

// -a keeps permissions, timestamps and links. No -T here: the destination IS
// the directory being copied into, which is the one case where mv and cp's
// default behaviour is the wanted one.
// ── how far along a copy is ───────────────────────────────────────────────
// rsync REPORTS it, which is better than measuring it. --info=progress2 gives
// a running percentage for the whole transfer rather than per file, and
// --remove-source-files turns the same command into a move.
//
// This replaced a du-based estimate — total the sources, poll the destination,
// divide — which worked but was approximate at every edge (sparse files, hard
// links, a destination that already held some of the names) and cost a process
// every 400ms to maintain.
//
// -a keeps permissions, times and links. --no-inc-recursive makes rsync scan
// everything up front, which is what lets the percentage mean anything from
// the start instead of climbing towards a total it is still discovering.
// What to do about a name the destination already has. Three answers, and
// which one you get is CHOSEN rather than assumed, because exactly one of them
// destroys something: overwrite is the only outcome a paste cannot be undone
// from, so it does not get to be the default that happens while you are not
// looking.
//
//   overwrite  rsync as it always was: the incoming copy wins
//   skip       --ignore-existing: keep what is there, take the rest
//   keep       both, the new one renamed "name (1).ext"
const CLASH = { overwrite: "overwrite", skip: "skip", keep: "keep" };

// Finding the free name is done in the SHELL, at the moment of writing, not
// here from the listing we happen to be holding. Two reasons: the listing can
// be seconds stale, and a transfer of several items creates names as it goes —
// "report (1).pdf" has to be taken into account by the time the second report
// arrives, and only the filesystem knows that.
//
// A dotfile has no extension to preserve: ${n%.*} on ".bashrc" leaves an empty
// stem and an extension of ".bashrc", which would produce " (1).bashrc". A
// directory has no extension either, whatever a dot in its name suggests.
const FREE_NAME =
  "terminus_free() {\n" +
  "  d=$1; n=$2; s=$3\n" +
  "  [ -e \"$d/$n\" ] || { printf '%s' \"$n\"; return; }\n" +
  "  if [ -d \"$s\" ]; then stem=$n; ext=\n" +
  "  else\n" +
  "    case $n in *.*) stem=${n%.*}; ext=.${n##*.} ;; *) stem=$n; ext= ;; esac\n" +
  "  fi\n" +
  "  [ -n \"$stem\" ] || { stem=$n; ext=; }\n" +
  "  i=1\n" +
  "  while [ -e \"$d/$stem ($i)$ext\" ]; do i=$((i+1)); done\n" +
  "  printf '%s' \"$stem ($i)$ext\"\n" +
  "}\n";

// Printed before each item in the modes that copy one at a time, so the panel
// can say "3 of 7" instead of watching the percentage drop back to zero six
// times with no explanation. Carried on \r, the same separator rsync's own
// progress uses, so one parser reads both kinds of line.
const ITEM_MARK = "@@TERMINUS-ITEM@@";

function transferCommand(paths, destDir, move, clash) {
  const mode = clash || CLASH.overwrite;
  const quoted = paths.map((p) => Strings.shellQuote(p));
  const dest = Strings.shellQuote(destDir);
  const flags = "-a --info=progress2 --no-inc-recursive"
    + (move ? " --remove-source-files" : "");

  let cmd;
  if (mode === CLASH.keep) {
    // One rsync per item, because rsync renames only when it is given a single
    // source and a full target path — there is no per-file rename for a batch.
    cmd = FREE_NAME
      + "i=0\n"
      + "for p in " + quoted.join(" ") + "; do\n"
      + "  i=$((i+1))\n"
      + "  printf '" + ITEM_MARK + "%s\\r' \"$i\"\n"
      + "  t=$(terminus_free " + dest + " \"$(basename -- \"$p\")\" \"$p\")\n"
      + "  rsync " + flags + " -- \"$p\" " + dest + "/\"$t\" || exit 1\n"
      + "done\n";
  } else {
    // --ignore-times on overwrite, and it is not optional.
    //
    // rsync's quick check calls a file unchanged when its size and mtime
    // match, which is right for a sync and wrong for this: paste NEW over an
    // OLD of the same length and rsync transfers nothing, so the one answer
    // that promised "the incoming copy wins" silently did nothing at all.
    // Verified — two 4-byte files with equal mtimes, and the destination kept
    // its own contents. An explicit overwrite has to actually write.
    cmd = "rsync " + flags
      + (mode === CLASH.skip ? " --ignore-existing" : " --ignore-times")
      + " -- " + quoted.join(" ") + " " + Strings.shellQuote(destDir + "/") + "\n";
  }

  // --remove-source-files empties the source directories but leaves the
  // directories themselves, so a move has to sweep them afterwards
  if (move) {
    cmd += "find " + quoted.join(" ")
      + " -depth -type d -empty -delete 2>/dev/null\n";
  }
  return cmd;
}

// rsync rewrites its progress line with a carriage return, so the stream is
// one long line with \r in it rather than many lines. The last percentage in
// whatever has arrived is the current one.
function parseProgress(text) {
  const m = String(text || "").match(/(\d+)%/g);
  if (!m || m.length === 0) return -1;
  return parseInt(m[m.length - 1], 10);
}

// Which item a "keep both" transfer has reached, or -1 for any other line.
function parseItem(line) {
  const t = String(line || "");
  const at = t.indexOf(ITEM_MARK);
  if (at < 0) return -1;
  const n = parseInt(t.slice(at + ITEM_MARK.length), 10);
  return isNaN(n) ? -1 : n;
}


// gio, not `rm`, and not a hand-rolled move into ~/.local/share/Trash.
//
// The XDG trash spec wants a .trashinfo file beside every trashed item holding
// its original path and the deletion time, and it wants name collisions
// resolved so two files called notes.txt from different directories both
// survive. gio does all of that, and refuses on filesystems where a trash
// cannot legally live — /tmp says "Trashing on system internal mounts is not
// supported" rather than pretending. A hand-rolled version gets the happy path
// right and loses the file on every other one.
function trashCommand(paths) {
  return "gio trash -- " + paths.map((p) => Strings.shellQuote(p)).join(" ");
}

// What is already there, asked BEFORE anything is written. cp and mv overwrite
// without a word, so the answer to this is the whole difference between a
// paste and a silent loss.
function conflictCommand(names, destDir) {
  const d = Strings.shellQuote(destDir);
  const tests = names.map((n) =>
    "[ -e " + d + "/" + Strings.shellQuote(n) + " ] && printf '%s\\036' "
    + Strings.shellQuote(n));
  return tests.join("; ") + "; true";
}

function parseConflicts(text) {
  return String(text || "").split(RECORD).filter((s) => s !== "");
}

// chmod, from nine booleans. Octal because that is what chmod takes and what
// every other tool reports, and because the symbolic form cannot express "set
// exactly this" without a mask.
function chmodCommand(paths, mode) {
  const oct = ("000" + (mode & 511).toString(8)).slice(-3);
  return "chmod " + oct + " -- "
    + paths.map((p) => Strings.shellQuote(p)).join(" ");
}

// The mode as the rwxrwxrwx string every listing shows, so the editor can be
// checked against `ls -l` without translating in your head.
function modeString(mode) {
  const bit = (i, ch) => ((mode >> i) & 1) ? ch : "-";
  return bit(8, "r") + bit(7, "w") + bit(6, "x")
       + bit(5, "r") + bit(4, "w") + bit(3, "x")
       + bit(2, "r") + bit(1, "w") + bit(0, "x");
}

// A name the filesystem will actually accept. A slash cannot appear in one at
// all, and the two dot names already belong to the directory itself.
function nameError(name) {
  const n = String(name || "");
  if (n === "") return "a name is required";
  if (n.indexOf("/") >= 0) return "a name cannot contain /";
  if (n === "." || n === "..") return "that name belongs to the filesystem";
  return "";
}

// ── the trash, and the way back out of it ───────────────────────────────
// gio puts a file IN the trash; getting it back out is our own job, because
// `gio trash --list` and `--restore` both need the gvfs trash backend, which
// is not installed here — asked, and it answers "Operation not supported".
//
// No real loss: the freedesktop spec is simple, and every trashed file has a
// .trashinfo beside it holding the path it came from. Reading that directly is
// more robust than depending on a daemon, and it is the same file every other
// trash implementation on the system writes.
function trashRoot() { return Paths.home() + "/.local/share/Trash"; }
function trashFilesDir() { return trashRoot() + "/files"; }
function isTrashDir(dir) { return String(dir) === trashFilesDir(); }

// Python, not shell, and for one specific reason: Path= is PERCENT-ENCODED
// per the spec. Decoding that in POSIX sh means sedding %XX into \xXX and
// feeding it through printf %b, which mangles any path containing a
// backslash — and a restore that picks the wrong destination puts a file
// somewhere you will never think to look for it.
const RESTORE_PY = [
  "import os, shutil, sys",
  "from urllib.parse import unquote",
  "root = sys.argv[1]",
  "mode = sys.argv[2]",
  "",
  "def original(info):",
  "    with open(info, 'r', errors='replace') as fh:",
  "        for line in fh:",
  "            if line.startswith('Path='):",
  "                return unquote(line[5:].strip())",
  "    return ''",
  "",
  "# 'path' mode is what undo uses: it knows where the file CAME FROM, not what",
  "# the trash decided to call it — gio appends a suffix when the name is taken,",
  "# so the two are not always the same string.",
  "names = []",
  "if mode == 'path':",
  "    want = set(sys.argv[3:])",
  "    infodir = os.path.join(root, 'info')",
  "    for entry in sorted(os.listdir(infodir)) if os.path.isdir(infodir) else []:",
  "        if not entry.endswith('.trashinfo'):",
  "            continue",
  "        if original(os.path.join(infodir, entry)) in want:",
  "            names.append(entry[:-len('.trashinfo')])",
  "else:",
  "    names = sys.argv[3:]",
  "",
  "for name in names:",
  "    info = os.path.join(root, 'info', name + '.trashinfo')",
  "    src = os.path.join(root, 'files', name)",
  "    if not os.path.isfile(info) or not os.path.exists(src):",
  "        sys.stderr.write('no trash record for ' + name + chr(10)); continue",
  "    dest = original(info)",
  "    if not dest:",
  "        sys.stderr.write('no original path for ' + name + chr(10)); continue",
  "    if not os.path.isabs(dest):",
  "        dest = os.path.join(os.path.expanduser('~'), dest)",
  "    if os.path.exists(dest):",
  "        sys.stderr.write('already exists: ' + dest + chr(10)); continue",
  "    parent = os.path.dirname(dest)",
  "    if parent:",
  "        os.makedirs(parent, exist_ok=True)",
  "    shutil.move(src, dest)",
  "    os.remove(info)",
  ""
].join("\n");

// `mode` is "name" when you are standing in the trash looking at the files, and
// "path" when undo is putting back something it watched you delete.
function restoreCommand(keys, mode) {
  return "python3 - " + Strings.shellQuote(trashRoot()) + " "
    + Strings.shellQuote(mode || "name") + " "
    + keys.map((n) => Strings.shellQuote(n)).join(" ")
    + " <<'TERMINUS_PY'\n" + RESTORE_PY + "TERMINUS_PY\n";
}

// ── archives ────────────────────────────────────────────────────────────
// bsdtar reads all of these and writes most of them, which is why it is the
// one tool here rather than a switch over tar/unzip/7z. 7z is the exception:
// libarchive will not create one, so that format keeps its own writer.
const ARCHIVE_EXTS = {
  zip: 1, tar: 1, gz: 1, tgz: 1, bz2: 1, tbz: 1, tbz2: 1, xz: 1, txz: 1,
  zst: 1, tzst: 1, "7z": 1, rar: 1, iso: 1, jar: 1, cab: 1, lz4: 1, lzma: 1
};

function isArchive(name) {
  const ext = String(name).split(".").pop().toLowerCase();
  return ARCHIVE_EXTS[ext] === 1;
}

// "archive.tar.gz" -> "archive", not "archive.tar"
function stripArchiveExt(name) {
  let n = String(name).replace(/\.(gz|bz2|xz|zst|lz4|lzma)$/i, "");
  return n.replace(/\.(tar|zip|7z|rar|iso|jar|cab|tgz|tbz2?|txz|tzst)$/i, "");
}

// A free DIRECTORY name, the same idea as terminus_free and for the same reason:
// extracting the same archive twice should give you two directories, not a
// merge of the two into one.
const FREE_DIR =
  "terminus_free_dir() {\n" +
  "  d=$1; n=$2\n" +
  "  [ -e \"$d/$n\" ] || { printf '%s' \"$n\"; return; }\n" +
  "  i=1\n" +
  "  while [ -e \"$d/$n ($i)\" ]; do i=$((i+1)); done\n" +
  "  printf '%s' \"$n ($i)\"\n" +
  "}\n";

// ── links ───────────────────────────────────────────────────────────────
// Both kinds, because they answer different questions: a symlink points at a
// path and breaks if it moves, a hard link is the same file under a second
// name and survives anything but deleting them all. -n so linking to an
// existing symlinked directory replaces the link rather than landing inside
// whatever it points at.
function linkCommand(paths, destDir, symbolic) {
  return "ln " + (symbolic ? "-sn" : "-n") + " -t "
    + Strings.shellQuote(destDir) + " -- "
    + paths.map((p) => Strings.shellQuote(p)).join(" ");
}

// ── bulk rename ─────────────────────────────────────────────────────────
// Renaming forty files is a text-editing problem, and for a long time the
// answer here was to hand the forty names to $EDITOR in a terminal and read
// the file back. It worked, and it meant the feature only existed if you had
// an editor configured, opened a window you then had to find, and could not
// tell you a name was illegal until after you had closed it.
//
// So the editing happens in terminus now — see the bulk card in
// TerminusWindow.qml — and what is left here is the part that was always the
// interesting half: deciding whether a proposed set of names is one we can act
// on, and turning it into moves that cannot destroy anything.

// What is wrong with each proposed name, by index: "" when the name is fine,
// otherwise the reason, short enough to sit on the row.
//
// ONE list of rules. The card marks a row and the gate refuses the batch, and
// they read the same function so they cannot disagree about what a legal name
// is.
//
// The seen-map has a NULL PROTOTYPE. A plain object inherits "toString",
// "constructor" and a dozen more, so a file actually called toString made the
// old duplicate check fire against a name nothing had used.
function bulkIssues(oldNames, newNames) {
  const out = [];
  const seen = Object.create(null);
  for (let i = 0; i < newNames.length; ++i) {
    const to = String(newNames[i] === undefined ? "" : newNames[i]).trim();
    if (to === "") { out.push("empty"); continue; }
    if (to.indexOf("/") >= 0) { out.push("has a /"); continue; }
    if (to === "." || to === "..") { out.push("reserved"); continue; }
    if (seen[to] !== undefined) {
      out.push("same as row " + (seen[to] + 1));
      continue;
    }
    seen[to] = i;
    out.push("");
  }
  return out;
}

// The renames a proposed set amounts to, or null if the set is not one we can
// act on. A name that did not change is not a rename. Anything illegal refuses
// the WHOLE batch, because a bulk rename that half-applies is worse than one
// that does not run.
function bulkPairs(oldNames, newNames) {
  if (!newNames || newNames.length !== oldNames.length) return null;
  const bad = bulkIssues(oldNames, newNames);
  for (let i = 0; i < bad.length; ++i) if (bad[i] !== "") return null;
  const pairs = [];
  for (let i = 0; i < newNames.length; ++i) {
    const to = String(newNames[i]).trim();
    if (to !== oldNames[i]) pairs.push([oldNames[i], to]);
  }
  return pairs;
}

// Find-and-replace across the whole set at once, which is the thing the editor
// was really being borrowed for.
//
// PLAIN TEXT, not a regular expression. These strings are filenames, and
// filenames are full of dots and brackets and parentheses — quietly treating
// "(1)" as a capture group would make the tool a trap. An empty needle changes
// nothing rather than inserting between every character.
function bulkReplace(names, find, repl) {
  const f = String(find === undefined ? "" : find);
  if (f === "") return names.slice();
  const r = String(repl === undefined ? "" : repl);
  return names.map((n) => String(n).split(f).join(r));
}

// Renamed through a temporary name when the new name is one that another file
// in the same batch still has. Swapping two names is the obvious case, and
// doing it directly would destroy one of them.
function bulkRenameApply(dir, pairs) {
  const d = Strings.shellQuote(dir);
  let cmd = "cd " + d + " || exit 1\n";
  const stamp = "terminus.tmp." + Date.now() + ".";
  for (let i = 0; i < pairs.length; ++i) {
    cmd += "mv -n -- " + Strings.shellQuote(pairs[i][0]) + " "
      + Strings.shellQuote(stamp + i) + " || exit 1\n";
  }
  for (let i = 0; i < pairs.length; ++i) {
    cmd += "mv -n -- " + Strings.shellQuote(stamp + i) + " "
      + Strings.shellQuote(pairs[i][1]) + " || exit 1\n";
  }
  return cmd;
}

// ── open with ───────────────────────────────────────────────────────────
// The applications that claim this file's type, with the names they call
// themselves. One process rather than one per candidate: gio names the desktop
// files, and the Name= is pulled straight out of them.
function appsCommand(path) {
  return "m=$(xdg-mime query filetype " + Strings.shellQuote(path) + " 2>/dev/null); "
    + "[ -n \"$m\" ] || exit 0; "
    + "gio mime \"$m\" 2>/dev/null | sed -n 's/^\\t//p' | awk '!seen[$0]++' | "
    + "while read -r id; do "
    // the shared XDG search path — see morpheus/Desktop.qml. This used to be
    // two hardcoded directories, which could not see an entry installed
    // anywhere else.
    + "for dir in " + Desktop.dirsExpr() + "; do "
    + "if [ -f \"$dir/$id\" ]; then "
    + "nm=$(sed -n 's/^Name=//p' \"$dir/$id\" | head -1); "
    // the FULL PATH as well as the id: gio launch takes a file rather than an
    // id, and this loop is already standing in the directory that holds it
    + "printf '%s\\037%s\\037%s\\036' \"$id\" \"${nm:-$id}\" \"$dir/$id\"; "
    + "break; fi; done; done";
}

function parseApps(text) {
  const out = [];
  const recs = String(text || "").split(RECORD);
  for (let i = 0; i < recs.length; ++i) {
    if (recs[i] === "") continue;
    const f = recs[i].split(FIELD);
    // the path is the third field. An entry parsed from older output has only
    // the first two, and a row with no file simply cannot be launched — which
    // the caller checks, rather than building a menu entry that does nothing.
    if (f.length >= 2)
      out.push({ id: f[0], name: f[1], file: f.length >= 3 ? f[2] : "" });
  }
  return out;
}

// Launching by ID rather than by the file the scan found.
//
// The scan reports the FIRST file with that id, which is a user entry in
// ~/.local/share/applications whenever one exists. That entry can be stale —
// buck's nvim.desktop pointed at kitty long after kitty was uninstalled — and
// gio refuses to load an entry whose Exec binary is missing. Handing gio that
// one file meant "Open with -> Neovim" did nothing, which is precisely the
// complaint this was supposed to fix.
//
// Desktop.launchCommand walks the whole search path and stops at the first
// entry that actually launches, so a stale override falls through to the
// system's copy. The scanned path is still what names the row in the menu;
// it is just not what the launch is pinned to.
function openWithCommand(desktopId, path) {
  return Desktop.launchCommand(desktopId, path);
}

// ── what a video IS ───────────────────────────────────────────────────────
// ffprobe, which ffmpeg already brings — the same package that pulls the
// thumbnail frame out of the file, so this adds no dependency either.
//
// `default=noprint_wrappers=1` prints one `key=value` line per field and the
// parse reads them BY NAME. `-of csv` was the shorter spelling and the wrong
// one: it prints bare values, and a file that reports no bit_rate shifts every
// column after it by one without saying so.
function videoInfoCommand(path) {
  return "ffprobe -v error -select_streams v:0 -show_entries "
    + "stream=width,height,codec_name,r_frame_rate:"
    + "format=duration,bit_rate,format_name"
    + " -of default=noprint_wrappers=1 -- " + Strings.shellQuote(path)
    + " 2>/dev/null";
}

function parseVideoInfo(text) {
  const kv = {};
  for (const line of String(text || "").split("\n")) {
    const cut = line.indexOf("=");
    if (cut > 0) kv[line.slice(0, cut)] = line.slice(cut + 1);
  }
  const w = parseInt(kv.width, 10);
  const h = parseInt(kv.height, 10);
  // no video stream is not an error worth a message, it is a file with nothing
  // to say about itself — the panel simply leaves those rows out
  if (!(w > 0) || !(h > 0)) return null;
  return {
    dims: w + " \u00d7 " + h,
    codec: kv.codec_name || "",
    fps: frameRate(kv.r_frame_rate),
    duration: formatDuration(kv.duration),
    bitrate: formatRate(kv.bit_rate),
    // "mov,mp4,m4a,3gp,3g2,mj2" is one container answering to six names, and
    // the first is the one anybody means by it
    container: String(kv.format_name || "").split(",")[0]
  };
}

// ffprobe reports a rate as an exact fraction — 24000/1001 — because 23.976 is
// not one. The fraction is the honest answer and the useless one.
function frameRate(text) {
  const parts = String(text || "").split("/");
  const n = Number(parts[0]);
  const d = parts.length > 1 ? Number(parts[1]) : 1;
  if (!(n > 0) || !(d > 0)) return "";
  const v = n / d;
  return (Math.abs(v - Math.round(v)) < 0.01
    ? String(Math.round(v)) : v.toFixed(3)) + " fps";
}

function formatDuration(secs) {
  const t = Math.round(Number(secs) || 0);
  if (t <= 0) return "";
  const pad = (n) => String(n).padStart(2, "0");
  const h = Math.floor(t / 3600);
  const m = Math.floor((t % 3600) / 60);
  return (h > 0 ? h + ":" + pad(m) : String(m)) + ":" + pad(t % 60);
}

// Decimal units, and deliberately not formatSize's binary ones: a bitrate has
// always been quoted in millions of bits per second, never in mebibits, and
// making this one consistent with the file sizes would make it wrong.
function formatRate(bps) {
  const v = Number(bps) || 0;
  if (v <= 0) return "";
  if (v >= 1000000) return (v / 1000000).toFixed(1) + " Mb/s";
  if (v >= 1000) return Math.round(v / 1000) + " kb/s";
  return v + " b/s";
}

// The same probe as a video's, asking the audio stream instead — plus the
// TAGS, which are the whole point: a file called "01.mp3" has a title, an
// artist and an album inside it and the listing can only show the number.
function audioInfoCommand(path) {
  return "ffprobe -v error -select_streams a:0 -show_entries "
    + "stream=codec_name,sample_rate,channels,bit_rate:"
    + "format=duration,bit_rate,format_name:"
    + "format_tags=title,artist,album,date,track"
    + " -of default=noprint_wrappers=1 -- " + Strings.shellQuote(path)
    + " 2>/dev/null";
}

function parseAudioInfo(text) {
  const kv = {};
  for (const line of String(text || "").split("\n")) {
    const cut = line.indexOf("=");
    if (cut > 0) {
      const k = line.slice(0, cut);
      // Stream and format BOTH answer bit_rate, and ffprobe prints the stream
      // first. The stream's is the honest one for the audio; the container's
      // includes everything else in the file. First wins.
      if (kv[k] === undefined) kv[k] = line.slice(cut + 1);
    }
  }
  if (!kv.codec_name && !kv.duration) return null;
  const rate = Number(kv.sample_rate) || 0;
  const ch = Number(kv.channels) || 0;
  return {
    title: kv["TAG:title"] || kv.title || "",
    artist: kv["TAG:artist"] || kv.artist || "",
    album: kv["TAG:album"] || kv.album || "",
    date: kv["TAG:date"] || kv.date || "",
    track: kv["TAG:track"] || kv.track || "",
    duration: formatDuration(kv.duration),
    codec: kv.codec_name || "",
    container: String(kv.format_name || "").split(",")[0],
    bitrate: formatRate(kv.bit_rate),
    // kHz, because 44100 is a number everybody reads as 44.1
    rate: rate > 0 ? (rate / 1000).toFixed(1).replace(/\.0$/, "") + " kHz" : "",
    channels: ch === 1 ? "mono" : (ch === 2 ? "stereo" : (ch > 0 ? ch + " ch" : ""))
  };
}

// ── looking inside an archive ───────────────────────────────────────────
// A .zip or .tar.zst previewed as "binary", which is true and useless: the one
// thing worth knowing about an archive before you extract it is what is in it.
// bsdtar reads every format terminus can extract, so the preview and the extract
// agree by construction.
//
// Capped, because a package archive can hold tens of thousands of paths and
// the preview pane shows perhaps forty.
function archiveListCommand(path) {
  return "bsdtar -tf " + Strings.shellQuote(path) + " 2>/dev/null | head -n 200";
}

function archivePreview(text) {
  const lines = String(text || "").split("\n").filter((l) => l !== "");
  if (lines.length === 0) return "";
  const out = [];
  for (let i = 0; i < lines.length; ++i) out.push(Strings.escapeHtml(lines[i]));
  return "<pre>" + out.join("\n") + "</pre>";
}

// ── emptying the trash ──────────────────────────────────────────────────
// Both halves, together. `files` holds what was deleted and `info` the records
// saying where each came from; removing one without the other leaves a trash
// that every other implementation then reports inconsistently.
function emptyTrashCommand() {
  const r = Strings.shellQuote(trashRoot());
  return "rm -rf -- " + r + "/files/* " + r + "/files/.[!.]* "
    + r + "/info/* " + r + "/info/.[!.]* 2>/dev/null; true";
}

// How much the trash is holding — the files, not the records, which are a few
// bytes each and are not what the question is about.
function trashSizeCommand() {
  return "du -sh " + Strings.shellQuote(trashFilesDir()) + " 2>/dev/null | cut -f1";
}

// ── what a file actually is ─────────────────────────────────────────────
// Computed ON REQUEST, never as part of opening the properties dialog: sha256
// over a few gigabytes takes real time, and a dialog that stalls every time you
// open it on a video is worse than not having the field at all.
function checksumCommand(path) {
  return "sha256sum -- " + Strings.shellQuote(path) + " 2>/dev/null | cut -d' ' -f1";
}

// Dimensions and the few image facts worth a glance. magick already makes the
// thumbnails, so this adds no dependency. [0] is the first frame — asking a
// multi-page PDF or an animation about its size otherwise prints one line per
// page.
function imageInfoCommand(path) {
  // Width and height come across as SEPARATE fields and are joined here, so
  // the one place that decides how a size reads is this file rather than a
  // format string — the video panel next to it spells it the same way.
  const fmt = "%w" + FIELD + "%h" + FIELD + "%m" + FIELD
    + "%[bit-depth]-bit" + FIELD + "%[colorspace]";
  return "magick identify -format " + Strings.shellQuote(fmt) + " "
    + Strings.shellQuote(path + "[0]") + " 2>/dev/null";
}

function parseImageInfo(text) {
  const f = String(text || "").trim().split(FIELD);
  if (f.length < 5 || f[0] === "") return null;
  return {
    dims: f[0] + " \u00d7 " + f[1],
    format: f[2],
    depth: f[3],
    colorspace: f[4]
  };
}

// ── typing a path ───────────────────────────────────────────────────────
// What `g` then space opens: somewhere to type a destination rather than
// clicking down to it. Everything here is about turning half-typed text into
// something the rest of terminus can navigate to.

// `~` and `~/...` mean home, and nothing else does — `~foo` is another user's
// home on some systems and terminus has no business guessing at that. A relative
// path is taken against the directory you are standing in, which is what a
// shell would do and therefore what the fingers expect.
function expandPath(text, home, cwd) {
  let t = String(text || "").trim();
  if (t === "") return "";
  if (t === "~") return home;
  if (t.indexOf("~/") === 0) t = home + t.slice(1);
  if (t.charAt(0) !== "/") t = joinPath(cwd, t);
  // collapse any // and trailing / so two spellings of one path compare equal
  t = t.replace(/\/+/g, "/");
  if (t.length > 1) t = t.replace(/\/+$/, "");
  return t;
}

// The directory whose contents could finish this, and the part already typed.
// Trailing slash means "inside here, nothing typed yet"; anything else means
// the last segment is a fragment to match on.
function completionContext(text, home, cwd) {
  const raw = String(text || "");
  const endsSlash = /\/$/.test(raw.trim()) || raw.trim() === "~";
  const full = expandPath(raw, home, cwd);
  if (full === "") return { dir: cwd, frag: "" };
  if (endsSlash) return { dir: full, frag: "" };
  return { dir: dirname(full), frag: basename(full) };
}

// Directories only. This is `g` — go — and completing to a file you cannot
// enter would be offering a destination that does not work.
function completeCommand(dir) {
  return "find " + Strings.shellQuote(dir)
    + " -maxdepth 1 -mindepth 1 -type d -printf '%f\\036' 2>/dev/null";
}

// Fuzzy over the same scorer the inline filter uses, so completing a path and
// filtering a listing behave identically — "dwn" reaches Downloads in both,
// and neither has its own idea of what a match is.
//
// A prefix match still wins, because fuzzyScore already ranks a hit at
// position 0 above everything else. Hidden directories stay out until you have
// typed the dot, the same rule the listing uses.
function completionsFor(text, frag) {
  const all = String(text || "").split(RECORD).filter((n) => n !== "");
  const f = String(frag || "");
  const lf = f.toLowerCase();
  const scored = [];
  for (const n of all) {
    if (f === "" && n.charAt(0) === ".") continue;
    const sc = lf === "" ? 0 : fuzzyScore(n.toLowerCase(), lf);
    if (sc < 0) continue;
    scored.push({ n: n, sc: sc });
  }
  scored.sort((a, b) => (b.sc - a.sc)
    || (a.n.toLowerCase() < b.n.toLowerCase() ? -1 : 1));
  const out = [];
  for (let i = 0; i < scored.length; ++i) out.push(scored[i].n);
  return out;
}

// What the ghost should trail after the typed fragment.
//
// Only ever a genuine PREFIX of the best candidate: with fuzzy matching the
// top hit for "dwn" is Downloads, and printing "ownloads" after "dwn" would be
// a suggestion that spells something that is not a path. When the top hit does
// not start with what you typed, the list below carries the answer instead and
// Tab takes it whole.
function ghostFor(hits, frag) {
  const pre = completePrefix(hits, frag);
  const f = String(frag || "");
  return pre.length > f.length ? pre.slice(f.length) : "";
}

// How far the candidates agree, IN THE FILESYSTEM'S OWN CASE.
//
// Matching ignores case, so completing has to hand back the real spelling
// rather than the one you typed: type "doc" at a directory holding Documents
// and appending the tail would leave "documents", which is not a path. The
// caller replaces the whole fragment with this instead of appending to it.
//
// Empty when the best candidate does not start with what you typed — a fuzzy
// hit like "dwn" for Downloads has no prefix to agree on, and spelling one out
// would suggest something that does not exist. Tab takes the whole candidate
// in that case; see the path bar.
function completePrefix(hits, frag) {
  if (!hits || hits.length === 0) return "";
  const f = String(frag || "");
  const lf = f.toLowerCase();
  if (hits[0].toLowerCase().indexOf(lf) !== 0) return "";
  const pre = [];
  for (const h of hits) {
    if (h.toLowerCase().indexOf(lf) === 0) pre.push(h);
  }
  return commonPrefix(pre);
}

// How far every candidate agrees, so Tab can fill in the part that is not yet
// a choice — the shell behaviour: two directories sharing six letters means
// Tab types those six and stops rather than picking one for you.
function commonPrefix(names) {
  if (!names || names.length === 0) return "";
  if (names.length === 1) return names[0];
  let pre = names[0];
  for (let i = 1; i < names.length; ++i) {
    const n = names[i];
    let k = 0;
    while (k < pre.length && k < n.length
           && pre.charAt(k).toLowerCase() === n.charAt(k).toLowerCase()) k++;
    pre = pre.slice(0, k);
    if (pre === "") break;
  }
  return pre;
}

// What the field should read once a candidate is taken. Built from the
// directory rather than by patching the typed text, so a half-typed segment
// and a `~` spelling both end up somewhere valid.
function completedPath(dir, name) {
  return joinPath(dir, name) + "/";
}

// ── how full a disk is ──────────────────────────────────────────────────
// lsblk prints sizes as it likes to read them — "907.1M", "32.3G", "1.8T" —
// so turning two of those back into a fraction means parsing them. Binary
// units, because that is what lsblk means by them and what the filesystem
// allocates in.
const SIZE_UNITS = {
  B: 1, K: 1024, M: 1048576, G: 1073741824,
  T: 1099511627776, P: 1125899906842624
};

function parseSizeStr(text) {
  const m = String(text || "").trim().match(/^([0-9]*\.?[0-9]+)\s*([BKMGTP])?/i);
  if (!m) return -1;
  const n = parseFloat(m[1]);
  if (isNaN(n)) return -1;
  const u = (m[2] || "B").toUpperCase();
  return n * (SIZE_UNITS[u] || 1);
}

// The proportion of a disk that is in use, or -1 when it cannot be known —
// an unmounted partition reports neither figure, and a bar drawn from a guess
// would be worse than no bar.
function usedFraction(avail, total) {
  const a = parseSizeStr(avail), t = parseSizeStr(total);
  if (a < 0 || t <= 0) return -1;
  const used = 1 - (a / t);
  return Math.max(0, Math.min(1, used));
}

// ── what git thinks of this directory ───────────────────────────────────
//
// One command answers both questions a file manager has: WHERE the repository
// is, and what is dirty inside it. They arrive in one process rather than two
// because the second is worthless without the first — porcelain paths are
// relative to the repository root, always, no matter which subdirectory git
// was invoked from, so the root is what turns them back into real paths.
//
// The two halves are separated by a NUL. That is not decoration: with -z the
// records themselves are NUL-terminated because a filename may legally contain
// a NEWLINE, and git stops quoting them under -z. So newline cannot separate
// anything here, and NUL can — the header is two lines of git's own output,
// which cannot contain one.
//
// --no-optional-locks matters more than it looks. Plain `git status` writes
// the index back when it refreshes stat information, so a file manager polling
// it would take the index lock every few seconds and lose races with whatever
// the user is running in a terminal. This flag makes it read-only.
//
// The pathspec is `.`, so only the subtree being looked at is scanned. Walking
// a whole kernel-sized repository to draw thirty rows is the difference
// between a listing that appears and one that arrives.
function gitCommand(dir) {
  const d = Strings.shellQuote(dir);
  return "git -C " + d + " --no-optional-locks rev-parse"
    + " --show-toplevel --abbrev-ref HEAD 2>/dev/null; printf '\\0'; "
    + "git -C " + d + " --no-optional-locks status --porcelain=v1 -z"
    + " --no-renames -- . 2>/dev/null";
}

// The porcelain's two columns are the index and the working tree, in that
// order, and between them they say everything. Read worst-first: a conflict is
// not also "modified", it is a conflict.
function gitState(code) {
  const x = code.charAt(0), y = code.charAt(1);
  if (code === "??") return "untracked";
  if (code === "!!") return "ignored";
  // Both sides touched the same path. git spells this six ways and they all
  // mean the same thing to someone looking at a list of files.
  if (x === "U" || y === "U" || code === "AA" || code === "DD") return "conflict";
  if (y === "D" || x === "D") return "deleted";
  // The working tree column first: an edit you have not staged is the one
  // thing you could still lose.
  if (y !== " " && y !== "") return "modified";
  if (x !== " " && x !== "") return "staged";
  return "";
}

// Worst-first, and the order is the point: a directory shows one mark for
// everything underneath it, so the mark has to be the one that matters most.
const GIT_RANK = { conflict: 5, deleted: 4, modified: 3, staged: 2, untracked: 1, ignored: 0 };

function gitWorse(a, b) {
  if (!a) return b || "";
  if (!b) return a;
  return (GIT_RANK[a] || 0) >= (GIT_RANK[b] || 0) ? a : b;
}

function parseGit(text) {
  const s = String(text || "");
  const cut = s.indexOf("\0");
  // No NUL at all means the command did not run — not a repository, or no git.
  if (cut === -1) return { root: "", branch: "", entries: [] };

  const head = s.slice(0, cut).split("\n");
  const root = (head[0] || "").trim();
  // In a repository with no commits yet, rev-parse can answer the first
  // question and fail the second. A root with no branch is still a repository.
  let branch = (head[1] || "").trim();
  if (branch === "HEAD") branch = "detached";
  if (root === "") return { root: "", branch: "", entries: [] };

  const entries = [];
  for (const recRaw of s.slice(cut + 1).split("\0")) {
    // "XY path": two status columns, one space, then the path — which may
    // itself begin with a space, so slice at a fixed offset rather than split.
    if (recRaw.length < 4) continue;
    const state = gitState(recRaw.slice(0, 2));
    if (state === "") continue;
    const rel = recRaw.slice(3);
    if (rel === "") continue;
    entries.push({ path: joinPath(root, rel), state: state });
  }
  return { root: root, branch: branch, entries: entries };
}

// Folds the repository's whole answer down to the rows actually on screen.
//
// Every reported path is either one of this directory's entries or something
// beneath one of them, so taking the first path segment below `cwd` names the
// row it belongs to either way — and a directory ends up holding the worst
// state of everything it contains without anyone walking a tree to work it
// out. An untracked directory arrives from git already collapsed to "dir/",
// which lands on the same row by the same rule.
function gitRollup(entries, cwd) {
  const out = {};
  const base = cwd === "/" ? "/" : String(cwd) + "/";
  for (const e of entries) {
    if (e.path.indexOf(base) !== 0) continue;
    const rest = e.path.slice(base.length);
    if (rest === "") continue;
    const cut = rest.indexOf("/");
    const name = cut === -1 ? rest : rest.slice(0, cut);
    if (name === "") continue;
    const key = base + name;
    out[key] = gitWorse(out[key], e.state);
  }
  return out;
}

// One character, because it sits in a gutter beside the name and anything
// wider would be a column. They are git's own letters where git has one, which
// makes them free to learn for anyone who has read a `git status`.
const GIT_MARK = {
  conflict: "U", deleted: "D", modified: "M",
  staged: "+", untracked: "?", ignored: "·"
};

// ── compressing and extracting, with something to watch ─────────────────
//
// Neither tool reports a percentage, so the percentage is COUNTED: how many
// entries have gone by against how many there are. That total is known before
// the work starts — `find` for a compress, the archive's own table of contents
// for an extract — so the bar is honest from the first entry rather than
// guessing from bytes, which compression makes a lie anyway.
//
// The entry lines arrive in different places depending on the tool: bsdtar
// writes its -v listing to STDERR for both -c and -x, 7z writes "+ path" to
// stdout under -bb1. Either way they are filtered out of the stream and turned
// into one progress record each, and a line that is NOT an entry is a real
// error, forwarded to stderr where the job's collector already reads it.
//
// The tool's exit status has to survive a pipeline, so it is parked in a file
// and re-raised at the end. Without that the status seen is the counting
// loop's, which succeeds cheerfully even when the archive failed to write.
const JOB_TOTAL = "T";
const JOB_AT = "P";

function archiveScript(prefix, countCmd, tool, entryPat, fromStdout) {
  // For bsdtar the pipe carries STDERR, so a line that is not an entry is a
  // real error and is forwarded on. For 7z the pipe carries STDOUT, where the
  // only other traffic is a copyright banner — its real errors go to stderr,
  // which is left alone to reach the job's collector untouched. Forwarding
  // there too would have reported "7-Zip 26.02 Copyright (c) Igor Pavlov" as
  // the reason your archive failed.
  const plumb = fromStdout ? "" : "2>&1 >/dev/null ";
  const other = fromStdout
    ? "*) ;;"
    : "*) [ -n \"$l\" ] && printf '%s\\n' \"$l\" >&2 ;;";
  return prefix
    + "rc=$(mktemp) || exit 1\n"
    + "total=$(" + countCmd + ")\n"
    + "[ -n \"$total\" ] || total=0\n"
    + "printf '" + JOB_TOTAL + "%s\\r' \"$total\"\n"
    + "{ " + tool + "; echo $? > \"$rc\"; } " + plumb + "| {\n"
    + "  i=0\n"
    + "  while IFS= read -r l; do\n"
    + "    case \"$l\" in\n"
    + "      " + entryPat + ") i=$((i+1)); printf '" + JOB_AT + "%s\\r' \"$i\" ;;\n"
    + "      " + other + "\n"
    + "    esac\n"
    + "  done\n"
    + "}\n"
    + "s=$(cat \"$rc\" 2>/dev/null); rm -f \"$rc\"\n"
    + "exit \"${s:-1}\"\n";
}

function compressJobCommand(paths, archivePath) {
  const names = paths.map((p) => Strings.shellQuote(basename(p))).join(" ");
  const ar = Strings.shellQuote(archivePath);
  const sevenZ = /\.7z$/i.test(archivePath);
  const prefix = "cd " + Strings.shellQuote(dirname(paths[0])) + " || exit 1\n";
  if (sevenZ) {
    // 7z counts files only: it has no entry of its own for a directory
    return archiveScript(prefix, "find " + names + " -type f 2>/dev/null | wc -l",
      "7z a -bb1 -bd -- " + ar + " " + names, "'+ '*", true);
  }
  return archiveScript(prefix, "find " + names + " 2>/dev/null | wc -l",
    "bsdtar -a -cvf " + ar + " -- " + names, "'a '*", false);
}

// One archive at a time, so the count means something, and into a directory of
// its own ALWAYS: an archive holding twenty loose files at its top level would
// otherwise spray them across the folder you were standing in, and picking
// those back out by hand is a worse problem than extracting was meant to solve.
function extractJobCommand(path, destDir) {
  const p = Strings.shellQuote(path);
  const stem = stripArchiveExt(basename(path));
  const prefix = FREE_DIR
    + "d=" + Strings.shellQuote(destDir) + "\n"
    + "t=$(terminus_free_dir \"$d\" " + Strings.shellQuote(stem) + ")\n"
    + "mkdir -p \"$d/$t\" || exit 1\n";
  return archiveScript(prefix, "bsdtar -tf " + p + " 2>/dev/null | wc -l",
    "bsdtar -xvf " + p + " -C \"$d/$t\"", "'x '*", false);
}

// ── what a finished job is called ───────────────────────────────────────
//
// The one line a notification gets. Past tense, because by the time this is
// read the thing has already happened, and the SUBJECT is the file when there
// is one file and a count when there are several — "Copied notes.txt" tells
// you which, "Copied 40 items" tells you how many, and neither is improved by
// being told both.
//
// Here rather than in the window for the usual reason: it is a decision about
// wording with no pixels in it, so it can be checked.
function jobSummary(op, names) {
  const verb = op === "copy" ? "Copied"
             : op === "move" ? "Moved"
             : op === "compress" ? "Compressed"
             : op === "extract" ? "Extracted"
             : "Finished";
  const list = names || [];
  if (list.length === 0) return verb;
  if (list.length === 1) return verb + " " + list[0];
  return verb + " " + list.length + " items";
}

// A progress record, or null for a line that is not one. The counting loop
// emits nothing else on stdout, so anything unrecognised is simply ignored.
function parseArchiveProgress(line) {
  const s = String(line || "");
  if (s.indexOf(JOB_TOTAL) === 0) {
    const n = parseInt(s.slice(JOB_TOTAL.length), 10);
    return isNaN(n) ? null : { total: Math.max(0, n) };
  }
  if (s.indexOf(JOB_AT) === 0) {
    const n = parseInt(s.slice(JOB_AT.length), 10);
    return isNaN(n) ? null : { at: Math.max(0, n) };
  }
  return null;
}
