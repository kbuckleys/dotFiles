// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// JANUS' pure half — what a directory is, and the commands that change one.
// No QML in here; JanusWindow draws it and runs these.

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
// the two cannot drift into producing rows of different shapes.
const PRINTF = " -printf '%y\\037%Y\\037%m\\037%s\\037%T@\\037%p\\036' ";

function listCommand(dir) {
  return "find " + Strings.shellQuote(dir) + " -maxdepth 1 -mindepth 1"
    + PRINTF + "2>/dev/null";
}

// The same listing, capped. A preview pane is a glance into a directory, and
// a glance at /usr/lib does not need forty thousand rows parsed and turned
// into objects to show you the first thirty.
function peekCommand(dir) {
  return "find " + Strings.shellQuote(dir) + " -maxdepth 1 -mindepth 1"
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
// and the obvious basename of "…/janus/" is the empty string — which the row
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

// ── shape of the list ─────────────────────────────────────────────────────
// Directories first, always, whatever the sort is. Not a preference: a size
// sort that interleaves folders among files makes the folders unfindable, and
// every file manager worth using has settled on the same rule.
function sortEntries(rows, key, desc) {
  const dir = desc ? -1 : 1;
  const byName = (a, b) => {
    const x = a.name.toLowerCase(), y = b.name.toLowerCase();
    return x < y ? -1 : x > y ? 1 : 0;
  };
  const cmp = {
    name: (a, b) => byName(a, b) * dir,
    size: (a, b) => (a.size - b.size) * dir || byName(a, b),
    time: (a, b) => (a.mtime - b.mtime) * dir || byName(a, b)
  }[key] || ((a, b) => byName(a, b) * dir);

  return rows.slice().sort((a, b) => {
    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
    return cmp(a, b);
  });
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
function fuzzyScore(hay, q) {
  if (q === "") return 0;
  const at = hay.indexOf(q);
  if (at >= 0) {
    // 1000 keeps every substring hit above every subsequence one
    let sc = 1000 - at;
    if (at === 0) sc += 200;
    else if (!/[a-z0-9]/.test(hay.charAt(at - 1))) sc += 100;
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
    else if (!/[a-z0-9]/.test(hay.charAt(k - 1))) sc += 6;
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

// the lower-cased haystack for a row, cached on the row the first time it is
// asked for: a filter types one character at a time over the same rows
function displaySound_(r) {
  if (r.hay === undefined) r.hay = String(r.name).toLowerCase();
  return r.hay;
}

function filterEntries(rows, query, showHidden) {
  const q = String(query || "").toLowerCase();
  return rows.filter((r) => {
    if (!showHidden && r.isHidden) return false;
    return q === "" || r.name.toLowerCase().indexOf(q) >= 0;
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
  return "pdftoppm -png -f 1 -l 1 -r 72 -singlefile -- "
    + Strings.shellQuote(path) + " " + Strings.shellQuote(outStem) + " 2>/dev/null";
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
// Cached on disk under ~/.cache/janus/thumbs, not decoded from the original
// every time. Qt caches decoded images in memory, which is enough within one
// session and nothing at all across restarts — and a folder of 40MP camera
// JPEGs costs a full decode per tile either way. A 256px PNG costs one decode
// once and a few KB forever.
//
// The name is derived from the path so two files with the same basename in
// different folders do not collide. It is not a checksum of the CONTENT: that
// would mean reading every file to find out whether its thumbnail is stale,
// which is the work being avoided. The mtime is in the name instead, so an
// edited file simply misses and is regenerated, and the stale one ages out.
function thumbDir() {
  return Paths.cacheDir() + "/janus/thumbs";
}

function thumbHash(path, mtime) {
  const key = String(path) + ":" + Math.floor(Number(mtime) || 0);
  let h1 = 0x811c9dc5, h2 = 0x01000193;
  for (let i = 0; i < key.length; ++i) {
    const c = key.charCodeAt(i);
    h1 = ((h1 ^ c) * 16777619) >>> 0;
    h2 = ((h2 + c) * 2654435761) >>> 0;
  }
  return ("00000000" + h1.toString(16)).slice(-8)
       + ("00000000" + h2.toString(16)).slice(-8);
}

function thumbPath(path, mtime) {
  return thumbDir() + "/" + thumbHash(path, mtime) + ".png";
}

// One process for the whole visible directory, not one per file. `magick` is
// handed the pairs and -P 8 keeps eight of them going, which is what folio's
// clipboard thumbnails already do.
// Pictures go through magick, videos through ffmpeg — a frame a second in,
// because frame zero of a great many videos is black. Both land as the same
// 256px PNG, so nothing downstream has to know which it was looking at.
//
// The kind is passed as a third field rather than re-derived in the shell:
// the extension test already ran in JS, and doing it again in sh would be the
// same rule written twice in two languages.
function thumbBatch(jobs) {
  if (jobs.length === 0) return "";
  const args = jobs.map((j) => j.kind + " " + Strings.shellQuote(j.src) + " "
    + Strings.shellQuote(j.out)).join("\n");
  return "mkdir -p " + Strings.shellQuote(thumbDir()) + "; printf '%s\n' "
    + Strings.shellQuote(args)
    + " | xargs -P 4 -L 1 sh -c '"
    + "test -s \"$2\" && exit 0; "
    + "if [ \"$0\" = v ]; then "
    + "ffmpeg -nostdin -loglevel quiet -ss 1 -i \"$1\" -frames:v 1"
    + " -vf scale=256:-1 -y \"$2\"; "
    + "else magick \"$1\"[0] -auto-orient -thumbnail 256x256 -strip \"$2\"; fi"
    + "' 2>/dev/null";
}

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

// The head of a file, for the text pane. -c not -n: a minified bundle is one
// line and would otherwise be read in its entirety to show forty characters
// of it.
function headCommand(path) {
  return "head -c 8192 -- " + Strings.shellQuote(path) + " 2>/dev/null";
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
// Recursive, and FUZZY — scout's two-step, in one pipe.
//
// fd on its own matches its argument as a regex against the filename, so
// "jnwn" finds nothing and "Janus Window" finds nothing either. Scout solved
// that by listing everything with fd and then ranking with `fzf --filter`,
// which is what makes typing four letters of a path work. Same here, minus
// scout's index file: scout re-searches one fixed root often enough to cache
// it, and janus searches whatever directory you happen to be in.
//
// Directories first, exactly as scout orders them, so they win ties. fd marks
// them with a trailing slash, which parseListing now strips.
function findCommand(dir, query) {
  const d = Strings.shellQuote(dir);
  const q = Strings.shellQuote(String(query).trim());
  return "{ fd -t d -H --no-ignore --color=never . " + d + " 2>/dev/null ; "
    + "fd -t f -H --no-ignore --color=never . " + d + " 2>/dev/null ; }"
    + " | fzf --filter " + q + " 2>/dev/null | head -n 500 | tr '\\n' '\\0'";
}

function grepCommand(dir, query) {
  return "rg --hidden --no-ignore --files-with-matches --null --color=never -- "
    + Strings.shellQuote(query) + " " + Strings.shellQuote(dir)
    + " 2>/dev/null | head -c 400000";
}

// A found path becomes the same row shape the listing produces, so one
// delegate draws both. stat is asked once for the whole set rather than once
// per path — the difference on a two thousand row result is seconds.
function statCommand(paths) {
  return "find " + paths.map((p) => Strings.shellQuote(p)).join(" ")
    + " -maxdepth 0" + PRINTF + "2>/dev/null";
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
// A shell where you are standing. The same xdg-terminal-exec shape the bar's
// own click actions use.
function shellCommand(dir) {
  return "xdg-terminal-exec --title=janus-shell -e sh -c "
    + Strings.shellQuote("cd " + Strings.shellQuote(dir) + " && exec $SHELL")
    + " >/dev/null 2>&1 &";
}

// yazi's `a`: a trailing slash means a directory, anything else a file.
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

function openCommand(path) {
  return "xdg-open " + Strings.shellQuote(path) + " >/dev/null 2>&1 &";
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
  "janus_free() {\n" +
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
const ITEM_MARK = "@@JANUS-ITEM@@";

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
      + "  t=$(janus_free " + dest + " \"$(basename -- \"$p\")\" \"$p\")\n"
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

function copyCommand(paths, destDir) {
  return "cp -a -- " + paths.map((p) => Strings.shellQuote(p)).join(" ")
    + " " + Strings.shellQuote(destDir);
}

function moveCommand(paths, destDir) {
  return "mv -- " + paths.map((p) => Strings.shellQuote(p)).join(" ")
    + " " + Strings.shellQuote(destDir);
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
    + " <<'JANUS_PY'\n" + RESTORE_PY + "JANUS_PY\n";
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

// Extracted into a directory of its own, ALWAYS. An archive that holds twenty
// loose files at its top level would otherwise spray them across the folder
// you were standing in, and picking them back out by hand is a worse problem
// than the one extracting was meant to solve.
function extractCommand(path, destDir) {
  const stem = stripArchiveExt(basename(path));
  return "d=" + Strings.shellQuote(destDir) + "; "
    + "t=$(janus_free_dir \"$d\" " + Strings.shellQuote(stem) + "); "
    + "mkdir -p \"$d/$t\" && bsdtar -xf " + Strings.shellQuote(path)
    + " -C \"$d/$t\"";
}

// "archive.tar.gz" -> "archive", not "archive.tar"
function stripArchiveExt(name) {
  let n = String(name).replace(/\.(gz|bz2|xz|zst|lz4|lzma)$/i, "");
  return n.replace(/\.(tar|zip|7z|rar|iso|jar|cab|tgz|tbz2?|txz|tzst)$/i, "");
}

// A free DIRECTORY name, the same idea as janus_free and for the same reason:
// extracting the same archive twice should give you two directories, not a
// merge of the two into one.
const FREE_DIR =
  "janus_free_dir() {\n" +
  "  d=$1; n=$2\n" +
  "  [ -e \"$d/$n\" ] || { printf '%s' \"$n\"; return; }\n" +
  "  i=1\n" +
  "  while [ -e \"$d/$n ($i)\" ]; do i=$((i+1)); done\n" +
  "  printf '%s' \"$n ($i)\"\n" +
  "}\n";

function extractScript(paths, destDir) {
  let cmd = FREE_DIR;
  for (let i = 0; i < paths.length; ++i) {
    cmd += extractCommand(paths[i], destDir) + " || exit 1\n";
  }
  return cmd;
}

// bsdtar -a picks the format out of the NAME, so ".tar.zst" and ".zip" both
// work without a table here. 7z is written by 7z itself.
function compressCommand(paths, archivePath) {
  const names = paths.map((p) => Strings.shellQuote(basename(p))).join(" ");
  const dir = dirname(paths[0]);
  const cd = "cd " + Strings.shellQuote(dir) + " && ";
  if (/\.7z$/i.test(archivePath)) {
    return cd + "7z a -- " + Strings.shellQuote(archivePath) + " " + names;
  }
  return cd + "bsdtar -a -cf " + Strings.shellQuote(archivePath) + " -- " + names;
}

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
// The selection, one name per line, in your own editor. Renaming forty files
// is a text-editing problem, and an editor is far better at it than forty
// prompts would be.
//
// xdg-terminal-exec BLOCKS until the terminal closes (timed: a 2s command took
// 2055ms), so the edited file can simply be printed afterwards and read from
// stdout. The result is checked against the original list before anything is
// renamed — see applyBulk.
function bulkRenameCommand(names) {
  const lines = names.map((n) => Strings.shellQuote(n)).join(" ");
  return "t=$(mktemp /tmp/janus-rename.XXXXXX) || exit 1; "
    + "printf '%s\\n' " + lines + " > \"$t\"; "
    + "xdg-terminal-exec --title=janus-rename -e sh -c "
    + Strings.shellQuote("exec ${EDITOR:-nvim} \"$1\"") + " sh \"$t\" "
    + ">/dev/null 2>&1; "
    + "cat \"$t\"; rm -f \"$t\"";
}

// What the editor came back with, paired against what went in. A line that did
// not change is not a rename; a file that vanished from the list is not a
// delete. Anything that does not line up one-for-one is refused outright,
// because a bulk rename that half-applies is worse than one that does not run.
function bulkPairs(oldNames, text) {
  const out = String(text || "").replace(/\n+$/, "").split("\n");
  if (out.length !== oldNames.length) return null;
  const pairs = [];
  const seen = {};
  for (let i = 0; i < out.length; ++i) {
    const to = out[i].trim();
    if (to === "" || to.indexOf("/") >= 0) return null;
    if (seen[to]) return null;
    seen[to] = true;
    if (to !== oldNames[i]) pairs.push([oldNames[i], to]);
  }
  return pairs;
}

// Renamed through a temporary name when the new name is one that another file
// in the same batch still has. Swapping two names is the obvious case, and
// doing it directly would destroy one of them.
function bulkRenameApply(dir, pairs) {
  const d = Strings.shellQuote(dir);
  let cmd = "cd " + d + " || exit 1\n";
  const stamp = "janus.tmp." + Date.now() + ".";
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
    + "for dir in \"$HOME/.local/share/applications\" /usr/share/applications; do "
    + "if [ -f \"$dir/$id\" ]; then "
    + "nm=$(sed -n 's/^Name=//p' \"$dir/$id\" | head -1); "
    + "printf '%s\\037%s\\036' \"$id\" \"${nm:-$id}\"; break; fi; done; done";
}

function parseApps(text) {
  const out = [];
  const recs = String(text || "").split(RECORD);
  for (let i = 0; i < recs.length; ++i) {
    if (recs[i] === "") continue;
    const f = recs[i].split(FIELD);
    if (f.length >= 2) out.push({ id: f[0], name: f[1] });
  }
  return out;
}

function openWithCommand(desktopId, path) {
  return "gtk-launch " + Strings.shellQuote(desktopId) + " "
    + Strings.shellQuote(path) + " >/dev/null 2>&1 &";
}

// ── looking inside an archive ───────────────────────────────────────────
// A .zip or .tar.zst previewed as "binary", which is true and useless: the one
// thing worth knowing about an archive before you extract it is what is in it.
// bsdtar reads every format janus can extract, so the preview and the extract
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
  const fmt = "%w x %h" + FIELD + "%m" + FIELD + "%[bit-depth]-bit" + FIELD + "%[colorspace]";
  return "magick identify -format " + Strings.shellQuote(fmt) + " "
    + Strings.shellQuote(path + "[0]") + " 2>/dev/null";
}

function parseImageInfo(text) {
  const f = String(text || "").trim().split(FIELD);
  if (f.length < 4 || f[0] === "") return null;
  return { dims: f[0], format: f[1], depth: f[2], colorspace: f[3] };
}

// ── typing a path ───────────────────────────────────────────────────────
// What `g` then space opens: somewhere to type a destination rather than
// clicking down to it. Everything here is about turning half-typed text into
// something the rest of janus can navigate to.

// `~` and `~/...` mean home, and nothing else does — `~foo` is another user's
// home on some systems and janus has no business guessing at that. A relative
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
