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

// Red multi-select ballot (JetBrainsMono Nerd Font, U+F09FC)
const BALLOT = "\uDB82\uDDFC";

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
      rows.push({ pid: m[1], user: m[2], cpu: m[3], mem: formatMemKb(m[4]), args: m[5] });
    }
  }
  return rows;
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
