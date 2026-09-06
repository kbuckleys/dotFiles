// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

// The multi-select mark: a bolt, U+F140B. Past the BMP, so it is written as
// the surrogate pair a JS string literal needs rather than as the codepoint.
const BALLOT = "\uDB85\uDC0B";

function formatMemKb(kb) {
  const v = parseInt(kb, 10);
  if (isNaN(v)) return kb;
  if (v >= 1048576) return (v / 1048576).toFixed(1) + "G";
  return Math.round(v / 1024) + "M";
}

// ps -eo pid=,user=,pcpu=,rss=,args= --sort=-pcpu (rss in KiB)
function parseProcesses(text) {
  const rows = [];
  for (const line of String(text).split("\n")) {
    const m = line.match(/^\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.*)$/);
    if (m && m[1] && m[5] !== "") {
      // memKb keeps the raw rss the formatted `mem` throws away — sorting by
      // memory on "512M" vs "1.4G" would order them as strings and lie.
      rows.push({ pid: m[1], user: m[2], cpu: m[3], mem: formatMemKb(m[4]),
                  memKb: parseInt(m[4], 10) || 0, args: m[5] });
    }
  }
  return rows;
}

// The command's own name, for sorting by it. `args` is the whole command
// line, so this is the basename of argv[0] — and kernel threads arrive
// already bracketed, which is a name too, just not a path.
function procName(args) {
  const head = String(args).trim().split(/\s+/)[0] || "";
  if (head.charAt(0) === "[") return head.replace(/^\[|\]$/g, "");
  const cut = head.lastIndexOf("/");
  return cut >= 0 ? head.slice(cut + 1) : head;
}

// Filter first, then order: the sort only has to touch what survived, and the
// two are separate questions you change independently. (Same reasoning, and
// the same shape, as picasso.js sortRows.)
//
// Every comparison falls back to pid, so rows that tie hold still across the
// 2.5s refresh instead of swapping places under the cursor.
function sortRows(rows, key, desc) {
  const dir = desc ? -1 : 1;
  const byPid = (a, b) => (parseInt(a.pid, 10) || 0) - (parseInt(b.pid, 10) || 0);
  const num = (pick) => (a, b) => {
    const d = pick(a) - pick(b);
    return d !== 0 ? d * dir : byPid(a, b);
  };
  const str = (pick) => (a, b) => {
    const x = pick(a).toLowerCase(), y = pick(b).toLowerCase();
    if (x === y) return byPid(a, b);
    return (x < y ? -1 : 1) * dir;
  };
  const cmp = {
    cpu:  num((r) => parseFloat(r.cpu) || 0),
    mem:  num((r) => r.memKb || 0),
    pid:  num((r) => parseInt(r.pid, 10) || 0),
    user: str((r) => String(r.user)),
    name: str((r) => procName(r.args))
  }[key];
  // slice(): sort is in place, and `rows` is the unfiltered list the caller
  // still owns
  return cmp ? rows.slice().sort(cmp) : rows;
}

// fixed-width data columns; monospace font keeps them aligned
function display(r) {
  return r.pid.padStart(6) + " " + r.user.padEnd(9) +
    (r.cpu + "%").padStart(6) + " " +
    r.mem.padStart(5) + "  " + r.args;
}

function filterRows(rows, query) {
  const q = String(query).toLowerCase();
  if (!q) return rows;
  return rows.filter((r) => display(r).toLowerCase().indexOf(q) >= 0);
}

// Matches render bold #eebebe (rasi: highlight bold #eebebe)
function highlight(text, query) {
  text = String(text);
  if (!query) return Strings.escapeHtml(text);
  const lower = text.toLowerCase();
  const ql = String(query).toLowerCase();
  let out = "", pos = 0, i;
  while ((i = lower.indexOf(ql, pos)) >= 0) {
    out += Strings.escapeHtml(text.slice(pos, i));
    out += "<b><span style=\"color:#eebebe;\">" +
      Strings.escapeHtml(text.substr(i, ql.length)) + "</span></b>";
    pos = i + ql.length;
  }
  return out + Strings.escapeHtml(text.slice(pos));
}

// uptime -p → strip the leading "up "
function uptimeClean(text) {
  return String(text).replace(/^up\s+/, "").replace(/\s+$/, "");
}

// ── bandwhich ─────────────────────────────────────────────────────────────
// `bandwhich --raw` prints the same three tables its TUI draws, one row per
// line, a block a second, forever. All three are read: the view is meant to be
// what bandwhich shows, not a chosen slice of it.
//
//   Refreshing:
//   process: <1788161614> "claude" up/down Bps: 16/16 connections: 1
//   connection: <1788161614> <enp7s0>:39504 => 160.79.104.10:443 (tcp) up/down Bps: 16/16 process: "claude"
//   remote_address: <1788161614> 160.79.104.10 up/down Bps: 16/16 connections: 1
//
// These came off a real capture. An earlier pass reconstructed them from the
// binary's format strings and got the field ORDER wrong in all three — the
// <angle brackets> hold a unix timestamp, not the pid, the address or the
// connection, and every row carries one. Worth stating, because the strings
// are still in the binary in the misleading order and the next reader will
// find them too.
//
// `Bps` is bytes per second as a plain integer — raw mode does not humanise,
// which is exactly what a sort wants.
//
// The three are normalised on the way in, because they are the same four
// columns wearing different names: a thing, what it is bound to, and its two
// rates. One row shape means one delegate and one sort.
const NET_RE = {
  // process: <ts> "name" up/down Bps: u/d connections: n
  process: /^process: <\d+> "(.*)" up\/down Bps: (\d+)\/(\d+) connections: (\d+)\s*$/,
  // remote_address: <ts> addr up/down Bps: u/d connections: n
  remote: /^remote_address: <\d+> (.+?) up\/down Bps: (\d+)\/(\d+) connections: (\d+)\s*$/,
  // connection: <ts> <iface>:port => remote:port (proto) up/down Bps: u/d process: "name"
  connection: /^connection: <\d+> <(.+?)>:(\d+) => (.+) \((\w+)\) up\/down Bps: (\d+)\/(\d+)(?: process: "(.*)")?\s*$/
};

// bandwhich's own frame marker — it prints this before every block, so there
// is no need to guess where one ends from the timing of the lines.
function isNetFrame(line) {
  return /^Refreshing:/.test(String(line).trim());
}

function parseNetLine(line) {
  const t = String(line).trim();
  if (t === "") return null;
  let m;

  if ((m = NET_RE.process.exec(t))) {
    return { table: "process", name: m[1] || "?", detail: m[4] + " conn",
             up: parseInt(m[2], 10) || 0, down: parseInt(m[3], 10) || 0 };
  }
  if ((m = NET_RE.remote.exec(t))) {
    return { table: "remote", name: m[1], detail: m[4] + " conn",
             up: parseInt(m[2], 10) || 0, down: parseInt(m[3], 10) || 0 };
  }
  if ((m = NET_RE.connection.exec(t))) {
    return { table: "connection", name: m[3],
             detail: (m[7] || "?") + " · " + m[4] + " · " + m[1],
             up: parseInt(m[5], 10) || 0, down: parseInt(m[6], 10) || 0 };
  }
  return null;
}

// A line bandwhich clearly meant as a row that no pattern above matched — the
// one thing worth saying out loud, because it means a format changed under us
// and the table would otherwise just look short for no stated reason.
function isNetRow(line) {
  return /^(process|remote_address|connection): /.test(String(line).trim());
}

// Bytes per second, at the width the meters' own tooltips use.
function formatBps(n) {
  const v = Number(n) || 0;
  if (v >= 1048576) return (v / 1048576).toFixed(1) + "M";
  if (v >= 1024) return (v / 1024).toFixed(1) + "K";
  return v + "B";
}

// What a row reads as, for the filter to match against. The same job display()
// does for a process row, over the columns this table has.
function displayNet(r) {
  return r.name + " " + r.detail;
}

function filterNet(rows, query) {
  const q = String(query).toLowerCase();
  if (!q) return rows;
  return rows.filter((r) => displayNet(r).toLowerCase().indexOf(q) >= 0);
}

// Sorted like the kill list, over this table's columns. The tiebreak is the
// name rather than a pid: these rows have no pid to fall back on, and two of
// the three tables are not about processes at all.
function sortNet(rows, key, desc) {
  const dir = desc ? -1 : 1;
  const tie = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  const num = (pick) => (a, b) => {
    const d = pick(a) - pick(b);
    return d !== 0 ? d * dir : tie(a, b);
  };
  const str = (pick) => (a, b) => {
    const x = pick(a).toLowerCase(), y = pick(b).toLowerCase();
    if (x === y) return tie(a, b);
    return (x < y ? -1 : 1) * dir;
  };
  const cmp = {
    name:   str((r) => String(r.name)),
    detail: str((r) => String(r.detail)),
    up:     num((r) => r.up),
    down:   num((r) => r.down)
  }[key];
  return cmp ? rows.slice().sort(cmp) : rows;
}

// The one line worth showing out of a multi-line complaint. bandwhich's is a
// bare "Error:", a blank, the interface names, then the sentence that actually
// says what went wrong, then a bulleted workaround — and a strip one line tall
// can show exactly one of those.
function firstProblem(text) {
  const lines = String(text).split("\n")
    .map((l) => l.trim())
    .filter((l) => l !== "" && l !== "Error:" && l[0] !== "*" && !/:$/.test(l));
  const joined = lines.join(" ");
  const stop = joined.indexOf(". ");
  const one = stop > 0 ? joined.slice(0, stop + 1) : joined;
  return one.length > 140 ? one.slice(0, 137) + "…" : one;
}
