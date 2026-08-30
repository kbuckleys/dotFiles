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

function basename(p) {
  const s = String(p).replace(/\/$/, "");
  const parts = s.split("/");
  return parts[parts.length - 1] || p;
}

// ── the index ────────────────────────────────────────────────────────────
//
// WHAT THIS USED TO DO, because the difference is the whole point: every
// debounced keystroke ran `fd -t f -H . $HOME | fzf --filter …` from scratch.
// Measured here, that is 518,413 files and ~240ms of eight saturated cores,
// per keystroke, to search a set that had not changed since the last one.
//
// It is now indexed once and searched many times. Two changes make that work:
//
// 1. EXCLUDES INSTEAD OF DROPPING -H. Of those 518k, 355,700 were in
//    .local/share (Steam, flatpak), 49,600 .rustup, 31,045 .config/discord,
//    22,925 .cargo. Dropping -H altogether cuts it to 396 files and makes
//    ~/.config unsearchable, which is where the interesting dotfiles live.
//    Excluding the caches instead — including the generic Electron cache
//    directory names, which is most of it — gives ~4k entries built in 19ms,
//    and nothing a person would ever look for is lost.
// 2. THE INDEX IS NEVER READ INTO QML. Only fzf opens it. The engine only
//    ever sees the <=500 lines that came back, so a 3.6MB index costs no
//    QML memory at all.
function excludes() {
  return [
    // package and toolchain stores
    ".cache", ".local/share", ".cargo", ".rustup", ".git", "node_modules",
    ".npm", ".var", ".steam", ".gradle", ".venv", "__pycache__", ".nv",
    // browser profiles — .mozilla and .config/mozilla are different paths
    "mozilla", ".mozilla", ".thumbnails",
    // Every Electron app buries tens of thousands of files under these exact
    // names. Excluding the NAMES rather than discord/helium/... by hand means
    // the next such app is already handled.
    "Cache", "Cache_Data", "Code Cache", "GPUCache", "DawnCache",
    "ComputeCache", "Service Worker", "CacheStorage", "blob_storage",
    "IndexedDB", "Crashpad", "file-history"
  ].map((d) => "-E " + shellQuote(d)).join(" ");
}

// Directories are indexed too, and carry a trailing slash so a result can say
// what it is without anyone having to stat it back.
//
// Written to a temp and moved into place: a rename is atomic, so a search that
// lands mid-rebuild reads the whole old index rather than half of a new one.
function indexCommand(root, indexPath) {
  const r = shellQuote(root);
  const out = shellQuote(indexPath);
  const tmp = shellQuote(indexPath + ".new");
  const ex = excludes();
  // fd already terminates a directory with "/", which is what marks it in
  // the index — directories are listed first so they win ties in a browse.
  return "{ fd -t d -H " + ex + " . " + r + " 2>/dev/null ; " +
         "fd -t f -H " + ex + " . " + r + " 2>/dev/null ; } > " + tmp +
         " && mv -f " + tmp + " " + out;
}

// The per-keystroke half, and all it does now is rank. ~7ms against the
// cached index, versus ~400ms for the traversal it replaces.
function filterCommand(indexPath, query, dirsOnly) {
  const src = dirsOnly
    ? "grep '/$' " + shellQuote(indexPath)
    : "cat " + shellQuote(indexPath);
  return src + " 2>/dev/null | fzf --filter " + shellQuote(String(query).trim()) +
    " 2>/dev/null | head -n 500";
}

// The listing shown before anything is typed, restricted to directories when
// that toggle is on.
function browseCommand(indexPath, dirsOnly) {
  if (dirsOnly) return "grep '/$' " + shellQuote(indexPath) + " 2>/dev/null | head -n 200";
  return "head -n 200 " + shellQuote(indexPath) + " 2>/dev/null";
}

function parseResults(text) {
  if (!text) return [];
  const out = [];
  for (const line of String(text).split("\n")) {
    const p = line.trim();
    if (p === "") continue;
    // `displayText` used to be set here on every one of up to 500 objects and
    // read by nothing at all.
    out.push({ path: p, preview: p, isDir: p.charAt(p.length - 1) === "/" });
  }
  return out;
}

// ── frecency ─────────────────────────────────────────────────────────────
//
// What the panel shows before you type. It used to be
// `fd --max-results 200 | sort`, which bails after the first 200 hits in
// nondeterministic parallel traversal order — so it opened on 200 essentially
// random files, usually whatever cache directory fd's threads reached first.
// Ranking what you actually open is the same trick runner.js already plays
// with its rofi-run-freq file.
function bumpFreq(freq, path) {
  const next = {};
  for (const k in freq) next[k] = freq[k];
  next[path] = (next[path] || 0) + 1;
  return next;
}

function freqRanked(freq, limit) {
  const keys = [];
  for (const k in freq) keys.push(k);
  keys.sort((a, b) => {
    const d = (freq[b] || 0) - (freq[a] || 0);
    return d !== 0 ? d : (a < b ? -1 : a > b ? 1 : 0);
  });
  return keys.slice(0, limit).map((p) => ({
    path: p, preview: p, isDir: p.charAt(p.length - 1) === "/"
  }));
}

// A path that has been opened before but has since been deleted should not
// keep a seat in the opening view forever.
function pruneFreq(freq, alive) {
  const next = {};
  for (const k in freq) if (alive.indexOf(k) >= 0) next[k] = freq[k];
  return next;
}

// ── rendering ────────────────────────────────────────────────────────────

// Fit a path to the row, losing the MIDDLE rather than the tail. The old
// version sliced the end off, which on a file finder throws away the filename
// — the one part you were looking for.
function fitPath(p, avail) {
  const str = String(p);
  if (str.length <= avail || avail < 4) return str;
  const dir = str.charAt(str.length - 1) === "/";
  const base = basename(str) + (dir ? "/" : "");
  if (base.length + 2 >= avail) return "\u2026" + base.slice(base.length - (avail - 1));
  return str.slice(0, avail - base.length - 2) + "\u2026/" + base;
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

// A file goes to whatever owns its type; a folder goes to yazi in a terminal.
// xdg-open on a directory hands it to a graphical file manager, which is not
// what a keyboard-and-terminal shell wants — and the same
// `xdg-terminal-exec --title=... -e ...` shape the bar's own click actions
// already use (btop, bandwhich, wiremix).
function openCommand(path, isDir) {
  if (isDir) {
    return "xdg-terminal-exec --title=yazi -e yazi " + shellQuote(path) +
      " >/dev/null 2>&1 &";
  }
  return "xdg-open " + shellQuote(path) + " >/dev/null 2>&1 &";
}

function hintText(dirsOnly) {
  const key = (k) => "<b><span style=\"color:#a2a8bc;\">" + k + "</span></b>";
  const lbl = (t) => "<span style=\"color:#6a707f;\">" + t + "</span>";
  return [
    key("return") + " " + lbl("open"),
    key("alt c") + " " + lbl("copy path"),
    key("alt d") + " " + lbl(dirsOnly ? "all results" : "directories only"),
    key("alt r") + " " + lbl("reindex")
  ];
}
