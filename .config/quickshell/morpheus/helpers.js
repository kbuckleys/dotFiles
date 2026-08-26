// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

function home() {
  return Quickshell.env("HOME");
}

// module dir, resolved via XDG spec — no machine-specific paths
function configDir() {
  const xdg = Quickshell.env("XDG_CONFIG_HOME");
  return (xdg && xdg !== "" ? xdg : home() + "/.config") + "/quickshell/morpheus";
}

function script(name) {
  return configDir() + "/scripts/" + name;
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

function pad(n) {
  n = Math.trunc(n);
  return n < 10 ? "0" + n : String(n);
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

// waybar-updates' tooltip is a header of per-source counts, a blank line, then
// the package list. Only the list belongs in a notification body.
function updateList(tip) {
  const parts = (tip ?? "").split("\n\n");
  return parts.length > 1 ? parts.slice(1).join("\n\n") : (tip ?? "");
}
