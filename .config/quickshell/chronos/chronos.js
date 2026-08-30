// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/

const MONTHS = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"
];

const DAYS = [
  "Monday", "Tuesday", "Wednesday", "Thursday",
  "Friday", "Saturday", "Sunday"
];

// Monday-first, which is what the grid is laid out as
const DAYS_SHORT = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"];

function monthName(m) { return MONTHS[((m % 12) + 12) % 12]; }

function dayShort(i) { return DAYS_SHORT[((i % 7) + 7) % 7]; }

// Monday-first index of a Date, so it lines up with the grid's columns
function weekIndex(d) { return (d.getDay() + 6) % 7; }

// The one-line form the bar's clock hangs off: month, day, year.
function oneLine(d) {
  return monthName(d.getMonth()) + " " + d.getDate() + " " + d.getFullYear();
}

// "Saturday 29 August" — the footer under the grid. No year: the header above
// it is already showing one, and repeating it is the kind of noise that makes
// a panel feel like a form.
function longDay(d) {
  return DAYS[weekIndex(d)] + " " + d.getDate() + " " + monthName(d.getMonth());
}

// A month as 42 cells, Monday-first, six rows always — so the grid never
// changes height as you page through months, and a calendar does not resize
// under the cursor.
//
// The leading and trailing cells carry the neighbouring months' real dates
// rather than blanks: they are drawn dimmed, which keeps the grid a continuous
// run of days instead of a shape with two bites out of it, and means clicking
// anywhere in the grid lands on an actual date.
//
// Each cell is { y, m, d, cur } — a full date, so a caller never has to work
// out which month a dim cell belonged to.
function monthGrid(year, month) {
  // Date normalizes an out-of-range month for us, so month 12 is January of
  // the next year and the "is this cell in the current month" test below can
  // compare against one already-resolved pair.
  const first = new Date(year, month, 1);
  const y = first.getFullYear();
  const m = first.getMonth();
  const offset = weekIndex(first);
  const cells = [];
  for (let i = 0; i < 42; ++i) {
    const d = new Date(y, m, 1 + i - offset);
    cells.push({
      y: d.getFullYear(), m: d.getMonth(), d: d.getDate(),
      cur: d.getMonth() === m && d.getFullYear() === y
    });
  }
  return cells;
}

// YYYY-MM-DD in LOCAL time. Date.toISOString() converts to UTC first, which
// shifts the date by one either side of midnight — and these keys are matched
// against open-meteo's local-timezone daily rows.
function isoDay(y, m, d) {
  const p = (n) => (n < 10 ? "0" + n : String(n));
  return y + "-" + p(m + 1) + "-" + p(d);
}

function isoOf(date) {
  return isoDay(date.getFullYear(), date.getMonth(), date.getDate());
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

// How the cells in the pomodoro band divide up. Up to three across, and rows
// balanced rather than filled — four timers come out 2+2, not 3+1, because a
// lone cell stretched across a whole row does not read as one of a set.
function bandRows(n, perRow) {
  if (n <= 0) return [];
  const rows = Math.ceil(n / perRow);
  const out = [];
  let left = n;
  for (let r = 0; r < rows; ++r) {
    const take = Math.ceil(left / (rows - r));
    out.push(take);
    left -= take;
  }
  return out;
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
