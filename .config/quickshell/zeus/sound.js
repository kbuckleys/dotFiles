// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// The sound view's pure half — naming, filtering and the one thing that has to
// be parsed out of a command's output. Everything live (volumes, mutes, peaks,
// who is linked to what) comes from the pipewire service as objects, so none of
// it is in here: this file only ever sees strings and plain rows.

// ── what a node is ────────────────────────────────────────────────────────
// media.class, not quickshell's isSink/isStream. The four classes ARE the four
// things a mixer shows, they are what pipewire itself calls them, and reading
// them directly means no guessing at which way round `isSink` points on a
// stream — an app playing audio is an OUTPUT stream feeding a SINK, and either
// word could reasonably have been the one quickshell chose.
const SINK = "Audio/Sink";
const SOURCE = "Audio/Source";
const PLAYBACK = "Stream/Output/Audio";
const RECORDING = "Stream/Input/Audio";

function mediaClass(node) {
  if (!node || !node.properties) return "";
  return String(node.properties["media.class"] || "");
}

function isSinkNode(node) { return mediaClass(node) === SINK; }
function isSourceNode(node) { return mediaClass(node) === SOURCE; }
function isPlaybackNode(node) { return mediaClass(node) === PLAYBACK; }
function isRecordingNode(node) { return mediaClass(node) === RECORDING; }

// A monitor source is the tap on a sink's own output, not an input you can
// record a person through. Pipewire publishes them alongside the real capture
// devices and pulse clients see a ".monitor" for every sink, so they are
// dropped here — wiremix does not list them either, and a mixer full of them
// buries the one microphone you actually have.
function isMonitor(node) {
  if (!node || !node.properties) return false;
  const p = node.properties;
  if (String(p["media.category"] || "") === "Monitor") return true;
  return /\.monitor$/.test(String(p["node.name"] || ""));
}

// OUR OWN peak taps, excluded by NAME rather than by category — and that
// distinction is the whole point.
//
// Every PwNodePeakMonitor opens a real capture stream, which pipewire
// publishes as a Stream/Input/Audio node called "quickshell" with
// application.name "Quickshell Peak Detect" and media.category Monitor. So
// isMonitor() above would catch it... but only AFTER the node is bound,
// because media.category lives in `properties` and properties arrive with the
// binding. In the frame before that, one of our own taps is indistinguishable
// from an app recording audio — so it landed in RECORDING, which built a row,
// which built a delegate, which opened another peak monitor. Ten live taps and
// a list full of "Quickshell Peak Detect" was the visible end of that loop.
//
// `name` comes from the registry's own props at creation time, so it can be
// asked before the node is bound, which breaks the cycle at the only point
// where breaking it is possible.
function isOwnTap(node) {
  if (!node) return false;
  return String(node.name || "") === "quickshell";
}

// ── what a row reads as ───────────────────────────────────────────────────
// A device says what it IS and a stream says who is MAKING it. Two different
// questions, so two different property orders, and each falls back through the
// ones pipewire may leave unset rather than showing a bare node id.
//
// For a device the NICK comes first, not the description. The description is
// the card's name with the PCM appended, so four outputs of one card arrive as
// "GB206 High Definition Audio Controller Digital Stereo (HDMI) [Mi Monitor]",
// "… Pro 7", "… Pro 8", "… Pro 9" — four strings identical for their first
// forty characters, which in a 260px column is four rows that read the same.
// The nick is what pipewire publishes for exactly this job: "Mi Monitor",
// "HDMI 1", "HDMI 2", "HDMI 3". Short, and different from each other where it
// counts. The description is not lost; it is the column beside it.
function nodeLabel(node) {
  if (!node) return "";
  const p = node.properties || {};
  if (isPlaybackNode(node) || isRecordingNode(node)) {
    const app = String(p["application.name"] || node.description || "").trim();
    return app !== "" ? app : String(node.name || ("node " + node.id));
  }
  const nick = String(node.nickname || "").trim();
  if (nick !== "") return nick;
  const desc = String(node.description || "").trim();
  if (desc !== "") return desc;
  return String(node.name || ("node " + node.id));
}

// The second line's worth of a stream: what it is playing, when the app says.
// Firefox reports the tab's title here, mpv the file — it is the difference
// between four rows all called "Firefox" and four rows you can tell apart.
function nodeDetail(node) {
  if (!node) return "";
  const p = node.properties || {};
  if (isPlaybackNode(node) || isRecordingNode(node)) {
    const media = String(p["media.name"] || "").trim();
    if (media !== "" && media !== nodeLabel(node)) return media;
    return String(p["node.name"] || "");
  }
  // A device's detail is its PCM — the tail of node.name: "analog-stereo",
  // "hdmi-stereo", "pro-output-7". That is the one string that is decisive
  // about WHICH output of a card this is, and on a machine in alsa split mode,
  // where every PCM is its own node, it is the only one. The bus it used to
  // show read "alsa · pci" on all four of them, which told you nothing you
  // could act on.
  const nodeName = String(p["node.name"] || node.name || "");
  const cut = nodeName.lastIndexOf(".");
  if (cut >= 0 && cut < nodeName.length - 1) return nodeName.slice(cut + 1);
  const api = String(p["device.api"] || "").trim();
  const bus = String(p["device.bus"] || "").trim();
  if (api !== "" && bus !== "") return api + " · " + bus;
  return api;
}

// Pulse's index for a node, which is the node's object.serial and NOT its
// node id. Checked against a live stream rather than assumed: pw-play came up
// as node 63 with object.serial 27098, and `pactl list sink-inputs short`
// listed it as 27098. Getting this wrong moves the wrong stream, or nothing.
function pulseIndex(node) {
  if (!node || !node.properties) return "";
  return String(node.properties["object.serial"] || "");
}

// ── the model ─────────────────────────────────────────────────────────────
// One flat list with heading rows in it, the shape the connections view
// already uses: a ListView cannot nest sections, and these five tables are
// each usually short enough that five views would be mostly empty chrome.
//
// An empty section is dropped rather than shown with a zero beside it. In a
// stacked layout an empty heading band is just noise — four of them is most of
// the panel saying nothing — and a filter that matches nothing would otherwise
// render as five bands and no rows. The view says "no matches" once instead.
function section(title, rows) {
  if (rows.length === 0) return [];
  return [{ head: true, title: title, count: rows.length }].concat(rows);
}

// What the filter matches against — everything the row shows, so typing part
// of a card name or part of a tab title both land.
function displaySound(r) {
  if (r.head) return "";
  return [r.name, r.detail, r.route].filter((s) => !!s).join(" ");
}

function filterSound(rows, query) {
  const q = String(query).toLowerCase();
  if (!q) return rows;
  return rows.filter((r) => displaySound(r).toLowerCase().indexOf(q) >= 0);
}

// Volume as a percentage of the pipewire scale. Pipewire's own volume is
// linear 0..1 over the same range pulse calls 0..100%, so this is a scaling
// and not a cube-root conversion — wiremix shows the same number.
function percent(v) {
  return Math.round((Number(v) || 0) * 100);
}

// ── card profiles ─────────────────────────────────────────────────────────
// `pactl list cards`, which is the only one of these facts with no QML API at
// all: quickshell's pipewire service binds devices but exposes no EnumProfile,
// so a profile switch has to go out to a command either way. The block shape:
//
//   Card #50
//   	Name: alsa_card.pci-0000_01_00.1
//   	Properties:
//   		device.description = "GB206 High Definition Audio Controller"
//   	Profiles:
//   		off: Off (sinks: 0, sources: 0, priority: 0, available: yes)
//   		output:hdmi-stereo: Digital Stereo (HDMI) Output (sinks: 1, ...)
//   	Active Profile: off
//
// A note on what this machine actually reports: all three of its cards sit in
// profile `off` while audio plays perfectly. That is not a parsing failure —
// `pw-dump` says the same thing for every device's Profile param. This box runs
// pipewire's alsa SPLIT mode (`api.alsa.split-enable = "true"`, with
// `api.acp.auto-profile = "false"`), where the sink and source nodes are made
// straight from the card's PCMs and the ACP profile is never entered. So the
// CARDS section here is honest but mostly vestigial; on a box configured the
// usual way it names the profile that is running. Switching one still works
// either way — it is the same pactl call.
//
// Only AVAILABLE profiles are kept. An unavailable one is a profile the card
// physically cannot enter right now — every HDMI port with nothing plugged in
// is one, and this machine alone lists nine of them. Offering them would be
// offering a switch that silently does nothing.
function parseCards(text) {
  const cards = [];
  let cur = null;
  let inProfiles = false;

  for (const raw of String(text).split("\n")) {
    const line = raw.replace(/\s+$/, "");
    if (/^Card #/.test(line)) {
      if (cur) cards.push(cur);
      cur = { name: "", description: "", profiles: [], active: "" };
      inProfiles = false;
      continue;
    }
    if (!cur) continue;

    let m;
    if ((m = line.match(/^\tName:\s*(.+)$/))) {
      cur.name = m[1];
      inProfiles = false;
    } else if ((m = line.match(/^\t\tdevice\.description = "(.*)"$/))) {
      cur.description = m[1];
    } else if (/^\tProfiles:$/.test(line)) {
      inProfiles = true;
    } else if ((m = line.match(/^\tActive Profile:\s*(.+)$/))) {
      cur.active = m[1];
      inProfiles = false;
    } else if (/^\t[A-Z]/.test(line)) {
      // any other top-level section of the block — Ports:, Formats:, …
      inProfiles = false;
    // The key is the whole non-space run up to the colon-space, and the label
    // is everything before the LAST parenthesised group. Both matter, and both
    // were got wrong by the obvious pattern:
    //
    //   output:analog-stereo+input:analog-stereo: Analog Stereo Duplex (…)
    //   output:hdmi-stereo: Digital Stereo (HDMI) Output (…)
    //
    // A key can hold two colons and a plus, so anything counting colons stops
    // at `output:analog-stereo` and then never matches the active profile —
    // which is why the card row showed a raw key instead of a name. And a
    // LABEL can hold parentheses, so a lazy run to the first `(` truncates
    // "Digital Stereo (HDMI) Output" to "Digital Stereo". Anchoring the tail
    // group as paren-free-to-end pins both: it can only be pactl's own
    // (sinks: …, available: …) trailer. Checked against all 34 profile lines
    // this machine's three cards report.
    } else if (inProfiles && (m = line.match(/^\t\t(\S+):\s+(.+?)\s*\(([^()]*available:\s*(\w+))\)\s*$/))) {
      if (m[4] === "yes") cur.profiles.push({ key: m[1], label: m[2] });
    }
  }
  if (cur) cards.push(cur);
  return cards;
}

// A card's own name for the row. device.description is the readable one;
// the alsa_card.… name is the fallback and also what pactl is addressed by.
function cardLabel(card) {
  const d = String(card.description || "").trim();
  return d !== "" ? d : String(card.name || "");
}

// What the active profile is called, rather than its key. `off` and a key
// with no matching entry both happen — a card can be sitting in a profile
// that has since become unavailable — so the key is shown as-is then.
function activeProfileLabel(card) {
  const key = String(card.active || "");
  for (const p of card.profiles) {
    if (p.key === key) return p.label;
  }
  return key;
}

// The next profile round the ring, so left and right walk a card's options
// the same way they walk a volume. Wraps, and returns null when there is
// nothing to move to — a card with one available profile is not a choice.
function nextProfile(card, delta) {
  const n = card.profiles.length;
  if (n < 2) return null;
  let i = -1;
  for (let k = 0; k < n; ++k) {
    if (card.profiles[k].key === card.active) { i = k; break; }
  }
  if (i < 0) i = 0;
  return card.profiles[((i + delta) % n + n) % n];
}

// The next device a stream could be sent to. Same ring, over whichever list of
// devices matches the stream's direction.
function nextDevice(devices, current, delta) {
  const n = devices.length;
  if (n === 0) return null;
  let i = -1;
  for (let k = 0; k < n; ++k) {
    if (current && devices[k].id === current.id) { i = k; break; }
  }
  if (i < 0) return devices[delta > 0 ? 0 : n - 1];
  if (n < 2) return null;
  return devices[((i + delta) % n + n) % n];
}
