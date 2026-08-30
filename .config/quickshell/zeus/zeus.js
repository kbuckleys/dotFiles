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
  if (!query) return escapeHtml(text);
  const lower = text.toLowerCase();
  const ql = String(query).toLowerCase();
  let out = "", pos = 0, i;
  while ((i = lower.indexOf(ql, pos)) >= 0) {
    out += escapeHtml(text.slice(pos, i));
    out += "<b><span style=\"color:#eebebe;\">" +
      escapeHtml(text.substr(i, ql.length)) + "</span></b>";
    pos = i + ql.length;
  }
  return out + escapeHtml(text.slice(pos));
}

// uptime -p → strip the leading "up "
function uptimeClean(text) {
  return String(text).replace(/^up\s+/, "").replace(/\s+$/, "");
}
