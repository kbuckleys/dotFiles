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

function dictHistoryPath() {
  return cacheDir() + "/dict-history";
}

function transHistoryPath() {
  return cacheDir() + "/translate-history";
}

function usagePath() {
  return cacheDir() + "/translate-usage";
}

const UA = "qs-lexicon/1.0 (https://github.com/kbuckleys/)";
const TRANSLATE_ENDPOINT = "https://translate.googleapis.com/translate_a/single";
const WIKT_API = "https://en.wiktionary.org/w/api.php";
const WIKT_AUDIO_BASE = "https://commons.wikimedia.org/wiki/Special:FilePath/";

// Icons (JetBrainsMono Nerd Font). JS "\uXXXX" is strictly four hex digits,
// so astral-plane codepoints are written as explicit surrogate pairs:
//   U+F405 → \uF405 · U+F040 → \uF040 · U+F07C5 → \uDB81\uDFC5
//   U+F05CA → \uDB81\uDDCA · U+F02DA → \uDB80\uDEDA
const ICON_HEAD = "\uF405";
const ICON_AUDIO = "\uDB81\uDFC5";
const ICON_CORRECTED = "\uF040";
const ICON_TRANSLATE = "\uDB81\uDDCA";
const ICON_STAR = "\uDB80\uDEDA";

// History caps
const DICT_HISTORY_MAX = 100;
const TRANS_HISTORY_MAX = 20;

// TTS: Google rejects a single request over ~200 chars; split on sentence
// boundaries where possible and pack into chunks of at most this size.
const TTS_CHUNK_MAX = 190;
const TTS_REQUEST_GAP = 0.25;

// Target languages: native name + Google code. Source is auto-detected
// unless the input carries an explicit "<code>: " prefix.
const LANGS = [
  ["ar", "العربية"], ["bg", "Български"], ["bn", "বাংলা"], ["ca", "Català"],
  ["cs", "Čeština"], ["da", "Dansk"], ["de", "Deutsch"], ["el", "Ελληνικά"],
  ["en", "English"], ["es", "Español"], ["et", "Eesti"], ["fa", "فارسی"],
  ["fi", "Suomi"], ["fil", "Filipino"], ["fr", "Français"], ["gu", "ગુજરાતી"],
  ["he", "עברית"], ["hi", "हिन्दी"], ["hr", "Hrvatski"], ["hu", "Magyar"],
  ["id", "Indonesia"], ["it", "Italiano"], ["ja", "日本語"], ["kn", "ಕನ್ನಡ"],
  ["ko", "한국어"], ["lt", "Lietuvių"], ["lv", "Latviešu"], ["ml", "മലയാളം"],
  ["mr", "मराठी"], ["ms", "Bahasa Melayu"], ["nl", "Nederlands"], ["no", "Norsk"],
  ["pl", "Polski"], ["pt", "Português"], ["pt-BR", "Português (Brasil)"],
  ["ro", "Română"], ["ru", "Русский"], ["sk", "Slovenčina"], ["sl", "Slovenščina"],
  ["sr", "Српски"], ["sv", "Svenska"], ["sw", "Kiswahili"], ["ta", "தமிழ்"],
  ["te", "తెలుగు"], ["th", "ไทย"], ["tr", "Türkçe"], ["uk", "Українська"],
  ["ur", "اردو"], ["vi", "Tiếng Việt"], ["zh-CN", "简体中文"], ["zh-TW", "繁體中文"],
];

const SOURCE_NAMES = {};
for (const l of LANGS) SOURCE_NAMES[l[0]] = l[1];
SOURCE_NAMES["iw"] = "עברית";
SOURCE_NAMES["jw"] = "Jawa";

function sourceName(code) {
  return (code && SOURCE_NAMES[code]) || (code ? String(code).toUpperCase() : "");
}

const KNOWN_CODES = {};
for (const c of [
  "af","sq","am","ar","hy","az","eu","be","bn","bs","bg","ca","ceb","zh-CN",
  "zh-TW","co","hr","cs","da","nl","en","eo","et","fi","fr","fy","gl","ka","de",
  "el","gu","ht","ha","haw","he","hi","hmn","hu","is","ig","id","ga","it","ja",
  "jv","kn","kk","km","ko","ku","ky","lo","la","lv","lt","lb","mk","mg","ms",
  "ml","mt","mi","mr","mn","my","ne","no","ny","or","ps","fa","pl","pt","pa",
  "ro","ru","sm","gd","sr","st","sn","sd","si","sk","sl","so","es","su","sw",
  "sv","tg","ta","te","th","tr","tk","uk","ur","ug","uz","vi","cy","xh","yi",
  "yo","zu","iw","jw",
]) KNOWN_CODES[c] = true;

function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function escapeHtml(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Truncate by Unicode code point so surrogate pairs are never split.
function truncate(text, max) {
  const chars = Array.from(String(text));
  if (chars.length <= max) return String(text);
  return chars.slice(0, max).join("") + "…";
}

function hasContent(s) {
  return /\S/.test(s);
}

// Parse the "<code>: text" source-language prefix, mirroring translate.lua:
// only a recognised code counts, so "no: way" isn't read as Norwegian.
function splitSourcePrefix(raw) {
  const m = String(raw).match(/^(\S+)\s*:\s*(\S.*)$/);
  if (m && KNOWN_CODES[m[1]] && hasContent(m[2])) {
    return { text: m[2], source: m[1] };
  }
  return { text: String(raw), source: null };
}

// Build a Google Translate request. POST body so long inputs aren't
// constrained by URL length limits, mirroring translate.lua.
function translateRequest(text, tl, sl) {
  const src = sl && KNOWN_CODES[sl] ? sl : "auto";
  return {
    url: TRANSLATE_ENDPOINT,
    body: "client=gtx&sl=" + encodeURIComponent(src) +
      "&tl=" + encodeURIComponent(tl) +
      "&dt=t&dt=rm&q=" + encodeURIComponent(text),
  };
}

// Response shape: [[["trans","src echo",null,null,"roman"],...], null, "src"]
function parseTranslateResponse(body) {
  let data;
  try { data = JSON.parse(body); } catch (e) { return null; }
  if (!data || !Array.isArray(data) || !Array.isArray(data[0])) return null;

  const parts = [];
  let roman = null;
  // translate.lua read seg[3] in 1-indexed Lua — JS index 2 here. Some
  // response variants carry it at JS index 3 instead.
  for (const seg of data[0]) {
    if (!Array.isArray(seg)) continue;
    if (typeof seg[0] === "string" && seg[0] !== "") parts.push(seg[0]);
    if (roman === null) {
      if (typeof seg[2] === "string" && seg[2] !== "") roman = seg[2];
      else if (typeof seg[3] === "string" && seg[3] !== "") roman = seg[3];
    }
  }
  if (parts.length === 0) return null;
  return {
    translation: parts.join(""),
    roman: roman,
    source: typeof data[2] === "string" ? data[2] : null,
  };
}

// Split text into sentence-aligned chunks Google's TTS will accept
// (port of split_tts from translate.lua).
function ttsChunks(text) {
  const chunks = [];
  const sentences = [];
  for (const seg of String(text).split(/(?<=[.!?\n。．！？])/)) {
    const piece = seg.replace(/^\s+/, "");
    if (hasContent(piece)) sentences.push(piece);
  }

  let cur = "";
  const flush = () => {
    if (hasContent(cur)) chunks.push(cur);
    cur = "";
  };

  for (const s of sentences) {
    const chars = Array.from(s);
    if (cur !== "" && Array.from(cur).length + chars.length > TTS_CHUNK_MAX) flush();
    if (chars.length <= TTS_CHUNK_MAX) {
      cur += s;
    } else {
      let rest = s;
      while (Array.from(rest).length > TTS_CHUNK_MAX) {
        chunks.push(Array.from(rest).slice(0, TTS_CHUNK_MAX).join(""));
        rest = Array.from(rest).slice(TTS_CHUNK_MAX).join("");
      }
      cur = rest;
    }
  }
  flush();
  return chunks;
}

// One-shot shell script: fetch every TTS chunk sequentially (Google rate
// limit), concatenate into a valid MP3 stream, wait until non-empty, play,
// clean up. Fully detached — quickshell never waits on it.
function ttsScript(prefix, text, code, playerCmd) {
  const chunks = ttsChunks(text);
  if (chunks.length === 0) return null;
  const n = chunks.length;
  const path = "/tmp/" + prefix + ".mp3";

  const cmds = [];
  const pieces = [];
  for (let i = 0; i < n; ++i) {
    const url = "https://translate.google.com/translate_tts?ie=UTF-8&client=tw-ob" +
      "&tl=" + encodeURIComponent(code) +
      "&total=" + n + "&idx=" + i +
      "&textlen=" + chunks[i].length +
      "&q=" + encodeURIComponent(chunks[i]);
    const piece = path + "." + i;
    cmds.push("curl -sL --max-time 12 -A " + shellQuote(UA) + " " +
      shellQuote(url) + " -o " + shellQuote(piece));
    pieces.push(shellQuote(piece));
  }

  return "{ " + cmds.join(" && sleep " + TTS_REQUEST_GAP + " && ") + "; } && " +
    "cat " + pieces.join(" ") + " > " + shellQuote(path) + " && " +
    "rm -f " + pieces.join(" ") + " && " +
    "for i in $(seq 1 40); do [ -s " + shellQuote(path) + " ] && break; sleep 0.1; done && " +
    playerCmd + " " + shellQuote(path) + " >/dev/null 2>&1";
}

// Dictionary pronunciation: download to <path> then play, tolerating a slow
// start (the prefetch may still be running when the key lands).
function audioPlayScript(path, playerCmd) {
  return "for i in $(seq 1 30); do [ -s " + shellQuote(path) + " ] && break; sleep 0.1; done && " +
    "[ -s " + shellQuote(path) + " ] && " +
    playerCmd + " " + shellQuote(path) + " >/dev/null 2>&1";
}

// Player preference, best first — same ladder as the Lua scripts.
const PLAYERS = [
  ["mpv", "mpv --no-video --really-quiet"],
  ["mpg123", "mpg123 -q"],
  ["ffplay", "ffplay -nodisp -autoexit -loglevel quiet"],
  ["paplay", "paplay"],
];

function playerProbeCommand() {
  let out = "if command -v " + PLAYERS[0][0] + " >/dev/null 2>&1; then echo " +
    shellQuote(PLAYERS[0][1]) + ";";
  for (let i = 1; i < PLAYERS.length; ++i) {
    out += " elif command -v " + PLAYERS[i][0] + " >/dev/null 2>&1; then echo " +
      shellQuote(PLAYERS[i][1]) + ";";
  }
  return out + " else :; fi";
}

const CLIPBOARDS = [["wl-copy", "wl-copy"], ["xclip", "xclip -selection clipboard"],
  ["xsel", "xsel --clipboard --input"], ["pbcopy", "pbcopy"]];

function clipboardProbeCommand() {
  let out = "if command -v " + CLIPBOARDS[0][0] + " >/dev/null 2>&1; then echo " +
    shellQuote(CLIPBOARDS[0][1]) + ";";
  for (let i = 1; i < CLIPBOARDS.length; ++i) {
    out += " elif command -v " + CLIPBOARDS[i][0] + " >/dev/null 2>&1; then echo " +
      shellQuote(CLIPBOARDS[i][1]) + ";";
  }
  return out + " else :; fi";
}

// ---------------------------------------------------------------- history --

// Plain lines, most recent first
function parseDictHistory(text) {
  const list = [];
  if (!text) return list;
  for (const line of String(text).split("\n")) {
    if (line.trim() !== "") list.push(line);
  }
  return list;
}

function serializeDictHistory(list) {
  return list.slice(0, DICT_HISTORY_MAX).join("\n") + "\n";
}

function addDictHistory(list, word) {
  const lower = word.toLowerCase();
  const filtered = list.filter((w) => w.toLowerCase() !== lower);
  filtered.unshift(word);
  return filtered.slice(0, DICT_HISTORY_MAX);
}

function removeDictHistory(list, word) {
  const lower = word.toLowerCase();
  return list.filter((w) => w.toLowerCase() !== lower);
}

// JSON lines: { code, source?, text, translation }
function parseTransHistory(text) {
  const entries = [];
  if (!text) return entries;
  for (const line of String(text).split("\n")) {
    if (line.trim() === "") continue;
    try {
      const e = JSON.parse(line);
      if (e && typeof e.code === "string" && typeof e.text === "string") {
        entries.push({ code: e.code, source: e.source || null,
          text: e.text, translation: e.translation || "" });
      }
    } catch (err) {}
  }
  return entries;
}

function serializeTransHistory(entries) {
  if (entries.length === 0) return "";
  return entries.slice(0, TRANS_HISTORY_MAX)
    .map((e) => JSON.stringify(e)).join("\n") + "\n";
}

function addTransHistory(entries, code, source, text, translation) {
  const out = [{ code: code, source: source, text: text, translation: translation }];
  let n = 1;
  for (const e of entries) {
    if (n >= TRANS_HISTORY_MAX) break;
    if (e.code === code && e.text === text) continue;
    out.push(e);
    n++;
  }
  return out;
}

function removeTransHistory(entries, code, text) {
  return entries.filter((e) => !(e.code === code && e.text === text));
}

// One-line picker row for a saved translation
function transHistoryRow(e) {
  const t = truncate((e.text || "").replace(/\n/g, " "), 45);
  const tr = truncate((e.translation || "").replace(/\n/g, " "), 45);
  return t + "  →  " + tr + "  (" + sourceName(e.code) + ")";
}

// ------------------------------------------------------- language ranking --

function parseUsage(text) {
  const usage = {};
  if (!text) return usage;
  for (const line of String(text).split("\n")) {
    const m = line.match(/^(\S+)\s+(\d+)$/);
    if (m) usage[m[1]] = parseInt(m[2], 10);
  }
  return usage;
}

function serializeUsage(usage) {
  const lines = [];
  for (const c in usage) {
    if (usage[c] > 0) lines.push(c + " " + usage[c]);
  }
  return lines.length > 0 ? lines.join("\n") + "\n" : "";
}

// Usage-ranked index list into LANGS: used languages first (stable within
// rank), then the curated order.
function rankedLangs(usage) {
  const order = [];
  for (let i = 0; i < LANGS.length; ++i) order.push(i);
  order.sort((a, b) => {
    const ua = usage[LANGS[a][0]] || 0;
    const ub = usage[LANGS[b][0]] || 0;
    if (ua !== ub) return ub - ua;
    return a - b;
  });
  return order.map((i) => ({
    code: LANGS[i][0], name: LANGS[i][1],
    used: (usage[LANGS[i][0]] || 0) > 0,
  }));
}

// ===========================================================================
// Wiktionary engine
// ===========================================================================

// Accents we prefer to hear, best first
const ACCENT_PREFERENCE = ["US", "UK", "AU"];

const MAX_DEFS_PER_POS = 2;
const MAX_SYNONYMS = 6;

const POS_HEADINGS = {};
for (const h of [
  "noun", "proper noun", "verb", "adjective", "adverb", "preposition",
  "conjunction", "interjection", "pronoun", "determiner", "numeral", "number",
  "article", "particle", "phrase", "proverb", "prepositional phrase",
  "verb phrase", "adjective phrase", "adverbial phrase", "contraction",
  "idiom", "abbreviation", "acronym", "initialism", "prefix", "suffix",
]) POS_HEADINGS[h] = true;

const AUDIO_EXT = { ogg: true, oga: true, mp3: true, wav: true, flac: true };

function trim(s) {
  return String(s).replace(/^\s+/, "").replace(/\s+$/, "");
}

// Dictionary lookups are considered contentful only on ASCII alphanumerics,
// ASCII alphanumerics only
function hasAlpha(s) {
  return /[\w]/.test(s);
}

function decodeHtml(s) {
  s = s.replace(/&nbsp;/g, " ");
  s = s.replace(/&amp;/g, "&");
  s = s.replace(/&lt;/g, "<");
  s = s.replace(/&gt;/g, ">");
  s = s.replace(/&quot;/g, '"');
  s = s.replace(/&#39;/g, "'");
  s = s.replace(/&apos;/g, "'");
  return s;
}

// ------------------------------------------------------------------ HTTP --

function httpGet(url) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let req = new XMLHttpRequest();
    req.open("GET", url);
    try { req.setRequestHeader("User-Agent", UA); } catch (e) {}
    req.onreadystatechange = () => {
      if (req.readyState !== XMLHttpRequest.DONE || settled) return;
      settled = true;
      if (req.status >= 200 && req.status < 300) resolve(req.responseText);
      else reject(req.status === 0 ? "network" : "http");
    };
    try {
      req.send();
    } catch (e) {
      if (!settled) { settled = true; reject("network"); }
    }
  });
}

function httpGetJson(url) {
  return httpGet(url).then((body) => {
    try { return JSON.parse(body); } catch (e) { throw "network"; }
  });
}

// ------------------------------------------------------- wikitext parsing --

// Inner text of the template starting at position 0 of s, or null.
// Brace-aware so nested templates don't truncate the match.
function templateInner(s) {
  if (!s.startsWith("{{")) return null;
  let depth = 0, i = 0;
  while (i < s.length) {
    const two = s.substr(i, 2);
    if (two === "{{") { depth++; i += 2; }
    else if (two === "}}") {
      depth--; i += 2;
      if (depth === 0) return s.slice(2, i - 2);
    } else i++;
  }
  return null;
}

// Split template arguments on "|", ignoring pipes nested in {{ }} or [[ ]]
function splitArgs(inner) {
  const parts = [];
  let cur = "", depth = 0;
  for (let i = 0; i < inner.length;) {
    const two = inner.substr(i, 2);
    const c = inner[i];
    if (two === "{{" || two === "[[") { depth++; cur += two; i += 2; }
    else if (two === "}}" || two === "]]") { depth--; cur += two; i += 2; }
    else if (c === "|" && depth <= 0) { parts.push(cur); cur = ""; i++; }
    else { cur += c; i++; }
  }
  parts.push(cur);
  return parts;
}

function isNamedArg(p) {
  return /^\s*[\w\-\s]+=/.test(p);
}

// Positional (unnamed) arguments of a template, lang code dropped
function positionalArgs(parts) {
  const pos = [];
  for (let i = 1; i < parts.length; ++i) {
    if (!isNamedArg(parts[i])) pos.push(trim(parts[i]));
  }
  if (pos[0] === "en") pos.shift();
  return pos;
}

function namedArg(parts, key) {
  for (let i = 1; i < parts.length; ++i) {
    const m = parts[i].match(/^\s*([\w-]+)\s*=(.*)$/);
    if (m && m[1].toLowerCase() === key) return trim(m[2]);
  }
  return null;
}

function templateName(parts) {
  return trim(parts[0] || "").toLowerCase();
}

// Replace a single template with the text it should contribute
function renderTemplate(inner) {
  const parts = splitArgs(inner);
  const name = templateName(parts);
  const pos = positionalArgs(parts);

  // Templates that stand in for a word: show the target, not a trailing gloss
  if (name === "w" || name === "l" || name === "m" || name === "ll"
      || name === "link" || name === "mention" || name === "glossary")
    return pos[0] || "";
  // Non-gloss definitions and glosses: keep the prose
  if (name === "n-g" || name === "ngd" || name === "non-gloss"
      || name === "non-gloss definition" || name === "gloss" || name === "gl")
    return pos[pos.length - 1] || "";
  // Inline qualifiers render parenthesised, as they do on the site
  if (name === "q" || name === "qualifier" || name === "qual" || name === "i")
    return pos.length > 0 ? "(" + pos.join(", ") + ")" : "";
  // Everything else (quotes, references, categories) contributes nothing
  return "";
}

// Reduce wikitext markup to plain prose
function stripWikitext(s) {
  if (!s) return "";

  s = String(s);
  s = s.replace(/<ref[^>]*\/>/g, "");
  s = s.replace(/<ref[^>]*>[\s\S]*?<\/ref>/g, "");

  // Innermost-first so nested templates resolve correctly
  for (let i = 0; i < 8; ++i) {
    const next = s.replace(/\{\{([^{}]*)\}\}/g, (m, inner) => renderTemplate(inner));
    if (next === s) break;
    s = next;
  }
  s = s.replace(/\{\{/g, "").replace(/\}\}/g, "");

  s = s.replace(/\[\[[^\[\]|]*\|([^\[\]|]*)\]\]/g, "$1");
  s = s.replace(/\[\[([^\[\]]*)\]\]/g, "$1");
  s = s.replace(/\[https?:\/\/\S+\s+([^\]]*)\]/g, "$1");
  s = s.replace(/\[https?:\/\/\S+\]/g, "");

  s = s.replace(/'''''/g, "").replace(/'''/g, "").replace(/''/g, "");
  s = s.replace(/<[^>]*>/g, "");

  s = decodeHtml(s);
  s = s.replace(/\s+/g, " ");
  // Tidy space left behind by dropped templates
  s = s.replace(/\s+([,;.!?])/g, "$1");
  s = s.replace(/^[\s,;:]+/, "");
  return trim(s);
}

// Slice out the ==English== section; Wiktionary pages hold many languages
function englishSection(wikitext) {
  const out = [];
  let inEn = false;
  for (const line of String(wikitext).split("\n")) {
    const heading = line.match(/^==\s*([^=]+)\s*==\s*$/);
    if (heading) {
      inEn = trim(heading[1]).toLowerCase() === "english";
    } else if (inEn) {
      out.push(line);
    }
  }
  return out.join("\n");
}

// Pull a leading {{lb|en|...}} off a definition line.
// Returns { label: string|null, rest: string }
function extractLabel(line) {
  const m = line.match(/^\s*(\{\{.*)$/);
  if (!m) return { label: null, rest: line };
  const lead = m[1];
  const inner = templateInner(lead);
  if (!inner) return { label: null, rest: line };

  const parts = splitArgs(inner);
  const name = templateName(parts);
  if (name !== "lb" && name !== "label" && name !== "lbl" && name !== "tlb")
    return { label: null, rest: line };

  const labels = [];
  for (const p of positionalArgs(parts)) {
    // "_", "and", "or" are Wiktionary's label connectors, not labels
    if (p !== "" && p !== "_" && p !== "and" && p !== "or") labels.push(p);
  }

  const rest = lead.slice(inner.length + 4);
  if (labels.length === 0) return { label: null, rest };
  return { label: labels.join(", "), rest };
}

// Classify a recording by filename prefix (En-us-…), falling back to |a=
function audioAccent(file, annotation) {
  const prefix = file ? file.toLowerCase().match(/^en-([a-z]+)-/) : null;
  if (prefix) return prefix[1].toUpperCase();
  if (annotation && annotation !== "") {
    const a = annotation.toLowerCase().replace(/[^a-z]/g, "");
    if (a === "us" || a === "ga" || a === "genam" || a === "america"
        || a === "american" || a === "generalamerican") return "US";
    if (a === "uk" || a === "rp" || a === "british" || a === "britain"
        || a === "england" || a === "receivedpronunciation") return "UK";
    if (a === "au" || a === "aus" || a === "australia"
        || a === "australian") return "AU";
  }
  return null;
}

function accentRank(code) {
  const idx = ACCENT_PREFERENCE.indexOf(code);
  if (idx >= 0) return idx;
  return code ? ACCENT_PREFERENCE.length : ACCENT_PREFERENCE.length + 1;
}

// Parse the English section into a structured entry
function parseEntry(wikitext) {
  const section = englishSection(wikitext);
  if (section === "") return null;

  const entry = {
    posOrder: [],
    grouped: {},
    ipa: null,
    audio: null,
    synonyms: [],
  };

  const seenSyn = {};

  function addSynonyms(list) {
    for (const raw of list) {
      // A "Synonyms" bullet holds several {{l|en|…}} in one line, so the
      // stripped result is comma-joined; split it back into terms.
      const stripped = stripWikitext(raw) + ",";
      for (const term of stripped.split(/[,;]/)) {
        const clean = trim(term);
        // Thesaurus cross-links aren't usable synonyms, and "see also …"
        // survives template stripping, so match anywhere in the string
        if (clean !== "" && !clean.includes("Thesaurus:")
            && !seenSyn[clean.toLowerCase()]) {
          seenSyn[clean.toLowerCase()] = true;
          entry.synonyms.push(clean);
        }
      }
    }
  }

  let currentPos = null, defCount = 0, inSynonyms = false, lastDef = null;
  const ipaCandidates = [], audioCandidates = [];

  const lines = section.split("\n");
  for (const line of lines) {
    const heading = line.match(/^(=+)\s*(.*?)\s*=+\s*$/);
    if (heading) {
      const h = heading[2].toLowerCase().replace(/\s*\d+\s*$/, "");
      inSynonyms = h === "synonyms";
      if (POS_HEADINGS[h]) {
        currentPos = h;
        defCount = 0;
        if (!entry.grouped[h]) {
          entry.grouped[h] = [];
          entry.posOrder.push(h);
        }
      } else {
        currentPos = null;
      }
      lastDef = null;
      continue;
    }

    // Pronunciation data can appear anywhere in the section
    const ipaAt = line.search(/\{\{\s*IPA\s*\|/);
    if (ipaAt >= 0) {
      const inner = templateInner(line.slice(ipaAt));
      if (inner) {
        const parts = splitArgs(inner);
        for (const v of positionalArgs(parts)) {
          if (/^[\/\[]/.test(v)) {
            ipaCandidates.push({ text: v, accent: namedArg(parts, "a") });
          }
        }
      }
    }

    const audioAt = line.search(/\{\{\s*[Aa]udio\s*\|/);
    if (audioAt >= 0) {
      const inner = templateInner(line.slice(audioAt));
      if (inner) {
        const parts = splitArgs(inner);
        for (const v of positionalArgs(parts)) {
          const extM = v.match(/\.(\w+)$/);
          if (extM && AUDIO_EXT[extM[1].toLowerCase()]) {
            audioCandidates.push({ file: v, code: audioAccent(v, namedArg(parts, "a")) });
          }
        }
      }
    }

    if (inSynonyms) {
      const bullet = line.match(/^\*+(.*)$/);
      if (bullet && trim(bullet[1]) !== "") addSynonyms(splitArgs(bullet[1]));
    }

    const body = line.match(/^#([^#:*].*)$/);
    if (body && currentPos && defCount < MAX_DEFS_PER_POS) {
      const { label, rest } = extractLabel(body[1]);
      const text = stripWikitext(rest);
      if (hasAlpha(text)) {
        defCount++;
        lastDef = { def: text, label: label, example: "" };
        entry.grouped[currentPos].push(lastDef);
      }
    } else if (/^#:/.test(line)) {
      const sub = trim((line.match(/^#:\s*(.*)$/) || ["", ""])[1]);
      const inner = templateInner(sub);
      const tname = inner ? templateName(splitArgs(inner)) : null;
      if (tname === "syn" || tname === "synonyms") {
        addSynonyms(positionalArgs(splitArgs(inner)));
      } else if (lastDef && lastDef.example === "") {
        // {{ux|en|…}} and friends, or a bare inline example
        let text = null;
        if (tname === "ux" || tname === "usex" || tname === "uxi" || tname === "ux+") {
          text = stripWikitext(positionalArgs(splitArgs(inner))[0] || "");
        } else if (tname !== "ant" && tname !== "antonyms") {
          text = stripWikitext(sub);
        }
        if (text && hasAlpha(text)) lastDef.example = text;
      }
    }
  }

  // Prefer an IPA matching our top accent, else the first listed
  ipaCandidates.sort((a, b) =>
    accentRank(audioAccent("", a.accent)) - accentRank(audioAccent("", b.accent)));
  if (ipaCandidates[0]) entry.ipa = ipaCandidates[0].text;

  audioCandidates.sort((a, b) => accentRank(a.code) - accentRank(b.code));
  if (audioCandidates[0]) entry.audio = audioCandidates[0];

  while (entry.synonyms.length > MAX_SYNONYMS) entry.synonyms.pop();

  // An entry with headings but no definitions is not a usable result
  for (const pos of entry.posOrder) {
    if (entry.grouped[pos].length > 0) return entry;
  }
  return null;
}

// ---------------------------------------------------------------- network --

// redirects=1 matters: many idioms are redirects, e.g.
// "cost an arm and a leg" -> "an arm and a leg"
function fetchWikitext(title) {
  const url = WIKT_API + "?action=parse&page=" + encodeURIComponent(title) +
    "&prop=wikitext&format=json&formatversion=2&redirects=1";
  return httpGetJson(url).then(
    (data) => {
      if (!data || data.error || !data.parse || !data.parse.wikitext)
        return { err: "missing" };
      return { wikitext: data.parse.wikitext, title: data.parse.title };
    },
    () => ({ err: "network" })
  );
}

// Wiktionary's own search. Fuzzy enough to absorb real typos:
// "run off the mill" -> "run-of-the-mill", "kick the buckit" -> "kick the bucket".
function suggest(term, limit) {
  limit = limit || 3;
  const url = WIKT_API + "?action=opensearch&search=" +
    encodeURIComponent(term) + "&limit=" + limit + "&format=json";
  return httpGetJson(url).then(
    (data) => {
      // translate.lua read data[2] in 1-indexed Lua — the title array at
      // JS index 1
      const list = Array.isArray(data) && Array.isArray(data[1]) ? data[1] : [];
      return list.slice(0, limit);
    },
    () => []
  );
}

// Resolve a query to an entry. Tries the word as typed, then lowercased
// (page titles are case-sensitive), then Wiktionary's search for typos.
// Resolves to { entry, title, corrected } or rejects with an error kind:
// "network" | "missing".
function resolveWord(word) {
  const tried = new Set();

  // Keyed on the exact string: page titles are case-sensitive, so the
  // lowercased retry is a genuinely different fetch, not a duplicate
  function attempt(candidate) {
    if (tried.has(candidate)) return Promise.resolve(null);
    tried.add(candidate);

    return fetchWikitext(candidate).then((res) => {
      if (res.wikitext) {
        const entry = parseEntry(res.wikitext);
        if (entry) {
          const resolved = res.title || candidate;
          return {
            entry: entry,
            title: resolved,
            corrected: resolved.toLowerCase() !== word.toLowerCase(),
          };
        }
      } else if (res.err === "network") {
        throw "network";
      }
      return null;
    });
  }

  const candidates = [word];
  if (word.toLowerCase() !== word) candidates.push(word.toLowerCase());

  let chain = Promise.resolve(null);
  for (const c of candidates) {
    chain = chain.then((found) => found || attempt(c));
  }
  return chain
    .then((found) => {
      if (found) return found;
      return suggest(word, 3).then((suggestions) => {
        let sChain = Promise.resolve(null);
        for (const s of suggestions) {
          sChain = sChain.then((f) => f || attempt(s));
        }
        return sChain;
      });
    })
    .then((found) => {
      if (found) return found;
      throw "missing";
    });
}

// Structured view shaped for the results renderer.
function entryToResult(res) {
  const pos = [];
  for (const name of res.entry.posOrder) {
    const defs = [];
    for (const d of res.entry.grouped[name]) {
      defs.push({
        def: d.def,
        label: d.label || null,
        example: d.example !== "" ? d.example : null,
      });
    }
    if (defs.length > 0) pos.push({ name: name, defs: defs });
  }
  return {
    title: res.title,
    corrected: res.corrected === true,
    ipa: res.entry.ipa || null,
    audio: res.entry.audio
      ? { file: res.entry.audio.file, code: res.entry.audio.code || null }
      : null,
    pos: pos,
    synonyms: res.entry.synonyms.slice(),
  };
}
