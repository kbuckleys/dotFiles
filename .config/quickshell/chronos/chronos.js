// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/

const MONTHS = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"
];

function monthName(m) { return MONTHS[((m % 12) + 12) % 12]; }

// The one-line form the bar's clock hangs off: month, day, year.
function oneLine(d) {
  return monthName(d.getMonth()) + " " + d.getDate() + " " + d.getFullYear();
}

// A month as 42 cells, Monday-first, with 0 for the leading and trailing
// blanks. Six rows always, so the grid never changes height as you page
// through months — a calendar that resizes under the cursor is unusable.
function monthCells(year, month) {
  const first = new Date(year, month, 1);
  const offset = (first.getDay() + 6) % 7;
  const days = new Date(year, month + 1, 0).getDate();
  const cells = [];
  for (let i = 0; i < 42; ++i) {
    cells.push(i < offset || i >= offset + days ? 0 : i - offset + 1);
  }
  return cells;
}

function sameDay(a, b) {
  return a.getFullYear() === b.getFullYear()
    && a.getMonth() === b.getMonth()
    && a.getDate() === b.getDate();
}

// mm:ss, and hh:mm:ss once a timer is long enough to need it
function clock(secs) {
  const s = Math.max(0, Math.floor(secs));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  const pad = (n) => (n < 10 ? "0" + n : String(n));
  return (h > 0 ? pad(h) + ":" : "") + pad(m) + ":" + pad(r);
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function serialize(timers) {
  // running state is deliberately not persisted: a timer that was counting
  // when the shell restarted did not keep counting, and resurrecting it
  // half-elapsed would be a lie about when it will go off
  return JSON.stringify((timers || []).map((t) => ({
    label: t.label, minutes: t.minutes
  })));
}

function parse(text) {
  try {
    const v = JSON.parse(text || "[]");
    if (!Array.isArray(v)) return [];
    return v.map((t, i) => ({
      label: String(t.label ?? ("Timer " + (i + 1))),
      minutes: Math.max(1, Math.min(600, parseInt(t.minutes, 10) || 25)),
      remaining: 0,
      running: false
    }));
  } catch (e) {
    return [];
  }
}
