// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

// The shared pollers. One directory at the shell root rather than inside
// morpheus, because zeus reads the same ones the bar does and a script the
// process monitor depends on has no business living in the status bar's folder.
//
// Quickshell.shellDir is the directory the loaded shell file came from, so this
// no longer hand-rolls the XDG lookup — and it is right whatever path the
// config was launched from.
function script(name) {
  return Quickshell.shellDir + "/scripts/" + name;
}

function collapse(s) {
  return (s ?? "").replace(/ {2,}/g, " ");
}

function pangoToStyled(s) {
  if (!s) return "";
  return s
    .replace(/<span\b[^>]*\bforeground=(["'])([^"']+)\1[^>]*>/g, '<font color="$2">')
    .replace(/<span\b[^>]*>/g, "")
    .replace(/<\/span\s*>/g, "</font>");
}

function apply(s) {
  return collapse(pangoToStyled(s));
}

function tooltip(s) {
  return (s ?? "")
    .replace(/<span\b[^>]*\bforeground=(["'])([^"']+)\1[^>]*>/g, '<font color="$2">')
    .replace(/<span\b[^>]*>/g, "")
    .replace(/<\/span\s*>/g, "</font>")
    .replace(/\n/g, "<br/>");
}

// Strip the <font> tags back out of a styled block, leaving its text and
// structure. The update toast and the update tooltip are built by ONE function
// so they can never drift; this is the only difference between them — the
// tooltip keeps its colours, the toast does not want them.
function stripMarkup(s) {
  return String(s ?? "").replace(/<\/?font[^>]*>/g, "");
}

function pad(n) {
  n = Math.trunc(n);
  return n < 10 ? "0" + n : String(n);
}

// The unlit face behind a seven-segment reading. DSEG only ghosts if you draw
// every segment lit behind the live digits, so the ghost has to be the same
// SHAPE as what sits on top of it or the two will not register. Lives here
// rather than in chronos: the clock, the countdowns, the forecast and zeus'
// graphs all draw the same way, and that is one rule, not four.
function ghostText(s) {
  return String(s ?? "").replace(/\d/g, "8");
}

// "2.1MB/s" -> { num: "2.1", unit: "MB/s" }. A throughput reading is a number
// in the segment face with its unit beside it in the text face, so the two have
// to come apart — DSEG has no letters worth looking at.
function splitRate(s) {
  const m = String(s ?? "").match(/^([\d.]+)(.*)$/);
  return m ? { num: m[1], unit: m[2] } : { num: String(s ?? ""), unit: "" };
}

function powFormat(val) {
  const units = ["", "k", "M", "G", "T", "P"];
  let fraction = Math.max(0, val);
  let pow = 0;
  while (pow + 1 < units.length && fraction / 1000 >= 1) {
    fraction /= 1000;
    ++pow;
  }
  return fraction.toFixed(1) + units[pow] + "B/s";
}

function giB(kb) {
  return Math.round(kb / 10485.76) / 100;
}

function format1f(v) {
  return v.toFixed(1);
}

