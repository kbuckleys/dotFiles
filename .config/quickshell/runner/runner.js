// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

function home() {
  return Quickshell.env("HOME");
}

function cacheDir() {
  return Quickshell.env("XDG_CACHE_HOME") || home() + "/.cache";
}

function histPath() {
  return cacheDir() + "/runner-history";
}

function freqPath() {
  return cacheDir() + "/rofi-run-freq";
}

function shell() {
  return Quickshell.env("SHELL") || "/bin/bash";
}

const ICON_T = "\uEA85";
const ICON_P = "\uEB7F";
const ICON_B = "\uEE23";

const HIST_MAX = 200;

function stripIcon(entry) {
  let rest = entry;
  for (const ic of [ICON_T, ICON_P]) {
    if (rest.startsWith(ic)) {
      rest = rest.slice(ic.length);
      break;
    }
  }
  return rest;
}

function stripPrefix(s) {
  const idx = s.indexOf("  ");
  return idx >= 0 ? s.slice(idx + 2) : s;
}

function parseHistory(text) {
  const lines = [];
  if (!text) return lines;
  for (const line of text.split("\n")) {
    if (line.trim() === "") continue;
    if (stripIcon(line).trim() === "") continue;
    lines.push(line);
  }
  return lines;
}

function parseFreq(text) {
  const map = {};
  if (!text) return map;
  for (const line of text.split("\n")) {
    const m = line.match(/^(.*)=(\d+)$/);
    if (m && m[1] !== "") map[m[1]] = parseInt(m[2], 10);
  }
  return map;
}

function stripFieldCodes(exec) {
  return exec.replace(/%[fFuUdDnNickvm]/g, "").replace(/\s+$/, "");
}

function getApps(modelValues) {
  const apps = [];
  const seen = {};
  for (const v of modelValues) {
    if (!v) continue;
    const name = (v.name || "").trim();
    const exec = stripFieldCodes(v.exec || "").trim();
    const id = v.id || "";
    if (!name || !exec) continue;
    const key = name.toLowerCase();
    if (seen[key]) continue;
    seen[key] = true;
    apps.push({ name, exec, id, icon: v.icon || "", terminal: !!v.terminal });
  }
  apps.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return apps;
}

function buildRows(apps, histLines, freq) {
  const appNames = {};
  for (const a of apps) appNames[a.name.toLowerCase()] = true;

  const rows = [];
  for (const a of apps) {
    rows.push({ kind: "app", key: a.name, text: a.name, exec: a.exec, id: a.id, icon: a.icon, displayText: a.name });
  }
  for (const line of histLines) {
    const cmd = stripPrefix(line);
    if (appNames[cmd.toLowerCase()]) continue;
    const glyph = line.startsWith(ICON_P) ? ICON_P : ICON_T;
    rows.push({ kind: "hist", key: cmd, text: cmd, exec: "", glyph, raw: line, displayText: line });
  }
  rows.sort((a, b) => {
    const fa = freq[a.key] || 0;
    const fb = freq[b.key] || 0;
    if (fa !== fb) return fb - fa;
    return a.key < b.key ? -1 : a.key > b.key ? 1 : 0;
  });
  return rows;
}

function filterRows(rows, query) {
  const q = (query || "").trim().toLowerCase();
  if (q === "") return rows.slice();
  const out = [];
  for (const r of rows) {
    const hay = (r.text + " " + (r.exec || "")).toLowerCase();
    if (hay.includes(q)) out.push(r);
  }
  return out;
}

function addHistory(lines, cmd, mode, customIcon) {
  const icon = customIcon || (mode === "Terminal" ? ICON_T : ICON_P);
  const formatted = icon + "  " + cmd;
  const filtered = lines.filter((e) => e !== formatted);
  filtered.unshift(formatted);
  return filtered.slice(0, HIST_MAX);
}

function deleteHistoryLine(lines, rawLine) {
  return lines.filter((e) => e !== rawLine);
}

function bumpFreq(map, key) {
  if (!key) return map;
  map[key] = (map[key] || 0) + 1;
  return map;
}

function serializeHistory(lines) {
  return lines.length ? lines.join("\n") + "\n" : "";
}

function serializeFreq(map) {
  const parts = [];
  for (const k in map) parts.push(k + "=" + map[k]);
  return parts.length ? parts.join("\n") + "\n" : "";
}

function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function writeCommand(path, content) {
  return "printf '%s' " + shellQuote(content) + " > " + shellQuote(path);
}

function terminalCommand(cmd) {
  const t = String(cmd).trim().toLowerCase();
  if (t === "kitty") {
    return "setsid kitty --detach " + shellQuote(cmd) + " >/dev/null 2>&1 &";
  }
  return "xdg-terminal-exec --title=runner --hold -e " + shell() + " -i -c " + shellQuote(cmd) + " >/dev/null 2>&1 &";
}

function processCommand(cmd) {
  return "setsid " + shell() + " -i -c " + shellQuote(cmd) + " >/dev/null 2>&1 &";
}

function launchAppCommand(id) {
  return "gtk-launch " + shellQuote(id) + " >/dev/null 2>&1 &";
}

function escMarkup(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function highlight(text, query) {
  const t = String(text);
  const q = (query || "").trim();
  if (q === "") return escMarkup(t);
  const idx = t.toLowerCase().indexOf(q.toLowerCase());
  if (idx < 0) return escMarkup(t);
  return escMarkup(t.slice(0, idx)) + "<u>" + escMarkup(t.slice(idx, idx + q.length)) +
      "</u>" + escMarkup(t.slice(idx + q.length));
}
