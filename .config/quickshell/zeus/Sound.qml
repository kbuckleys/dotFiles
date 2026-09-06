// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// SOUND — the mixer's live half: what pipewire currently has, and the handful
// of things that change it. No markup in here; zeus' sound view draws this.
//
// It exists as a file of its own because it is the only part of zeus that is
// not a reading. The graphs, the kill list and the connections all watch; this
// one writes — volumes, mutes, defaults, where a stream goes and what profile
// a card is in — and those five verbs are worth having in one place rather
// than scattered through a view's delegates.
//
// Three of the five are native. Volume, mute and the default device are
// properties on the objects quickshell already hands over, so they are set
// directly and the change comes back through the same bindings that drew it.
// The other two have no QML API at any version — quickshell binds pipewire
// DEVICES but exposes no profile enumeration, and nothing exposes a stream's
// target — so they go out through pactl. That is not a wiremix dependency:
// pactl ships with pipewire-pulse, which is already running here.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "sound.js" as Sound

Item {
  id: root

  // Set while the view is on screen. Gates the two things that cost something
  // to keep running — the peak meters (in the delegates, off this) and the
  // card list, which is a process — so a closed panel is not paying for a
  // mixer nobody is looking at.
  property bool active: false

  property string query: ""

  // ── what there is ───────────────────────────────────────────────────────
  // Every audio node, chosen by whether it HAS an audio interface rather than
  // by class: quickshell creates that interface from the registry's own props
  // at creation time, so it can be asked before a node is bound, and the class
  // cannot — properties only fill in once something is tracking the node.
  // Our own peak taps are dropped HERE, before anything else sees them: they
  // are audio nodes by every test that matters, and leaving them in fed a loop
  // that opened a fresh tap for every tap it listed. See Sound.isOwnTap.
  readonly property var audioNodes: {
    const out = [];
    const all = Pipewire.nodes.values;
    for (let i = 0; i < all.length; ++i) {
      const n = all[i];
      if (n && n.audio && !Sound.isOwnTap(n)) out.push(n);
    }
    return out;
  }

  // Tracked unconditionally, not just while the view is open. A mixer needs
  // every node's volume, mute and props, and `properties` is exactly what
  // binding delivers — so gating this on `active` would open the view onto
  // rows that could not yet be sorted into sections. The count is small (this
  // machine runs seven to twelve) and the shell already tracks every link
  // group permanently for socordia's sake.
  PwObjectTracker { objects: root.audioNodes }

  function ofClass(pick) {
    const out = [];
    for (let i = 0; i < root.audioNodes.length; ++i) {
      const n = root.audioNodes[i];
      if (pick(n) && !Sound.isMonitor(n) && !Sound.isOwnTap(n)) out.push(n);
    }
    return out;
  }

  readonly property var sinks: root.ofClass(Sound.isSinkNode)
  readonly property var sources: root.ofClass(Sound.isSourceNode)
  readonly property var playback: root.ofClass(Sound.isPlaybackNode)
  readonly property var recording: root.ofClass(Sound.isRecordingNode)

  readonly property var defaultSink: Pipewire.defaultAudioSink
  readonly property var defaultSource: Pipewire.defaultAudioSource

  function isDefault(node) {
    if (!node) return false;
    return (root.defaultSink && node.id === root.defaultSink.id)
      || (root.defaultSource && node.id === root.defaultSource.id);
  }

  // ── the cards ───────────────────────────────────────────────────────────
  property var cards: []

  Process {
    id: cardProc
    command: ["pactl", "list", "cards"]
    stdout: StdioCollector {
      id: cardOut
      waitForEnd: true
      onStreamFinished: root.cards = Sound.parseCards(cardOut.text)
    }
  }

  function refreshCards() {
    if (!cardProc.running) cardProc.running = true;
  }

  // A card appears and disappears with its device, so the list is re-read when
  // the set of devices changes as well as when the view opens. Cheap: it is
  // one pactl call, and the alternative is a poll that is either too slow to
  // notice a plugged headset or a process every second for nothing.
  onActiveChanged: if (root.active) root.refreshCards()
  onSinksChanged: if (root.active) root.refreshCards()
  onSourcesChanged: if (root.active) root.refreshCards()

  // ── the model ───────────────────────────────────────────────────────────
  // Wiremix's own order — what is playing, what is listening, then the things
  // they are playing to and listening through, then the cards underneath them
  // all. Flattened into one list with heading rows, the shape the connections
  // view already uses, because a ListView cannot nest sections and five of
  // these are each usually short enough that five views would be mostly
  // chrome.
  function nodeRow(node, kind) {
    return {
      head: false,
      kind: kind,
      node: node,
      card: null,
      name: Sound.nodeLabel(node),
      detail: Sound.nodeDetail(node),
      route: ""
    };
  }

  function nodeRows(nodes, kind) {
    const out = [];
    for (let i = 0; i < nodes.length; ++i) out.push(root.nodeRow(nodes[i], kind));
    return out;
  }

  function cardRows() {
    const out = [];
    for (let i = 0; i < root.cards.length; ++i) {
      const c = root.cards[i];
      out.push({
        head: false,
        kind: "card",
        node: null,
        card: c,
        name: Sound.cardLabel(c),
        detail: Sound.activeProfileLabel(c),
        route: ""
      });
    }
    return out;
  }

  // Filtered per section and only then given its heading, so a heading's count
  // is the number of rows actually under it rather than the number there would
  // have been — the same way the connections view counts its three tables.
  readonly property var model: {
    const f = (rows) => Sound.filterSound(rows, root.query);
    return Sound.section("PLAYBACK", f(root.nodeRows(root.playback, "playback")))
      .concat(Sound.section("RECORDING", f(root.nodeRows(root.recording, "recording"))))
      .concat(Sound.section("OUTPUT DEVICES", f(root.nodeRows(root.sinks, "sink"))))
      .concat(Sound.section("INPUT DEVICES", f(root.nodeRows(root.sources, "source"))))
      .concat(Sound.section("CARDS", f(root.cardRows())));
  }

  readonly property string statusLine: {
    const d = root.defaultSink ? Sound.nodeLabel(root.defaultSink) : "no default sink";
    return root.playback.length + "▸ · " + root.recording.length + "◂ · "
      + root.sinks.length + " out · " + root.sources.length + " in · " + d;
  }

  // ── the five verbs ──────────────────────────────────────────────────────

  // How loud a row is allowed to be.
  //
  // A DEVICE stops at 100%. Past that pipewire is applying digital gain to
  // everything the machine plays at once, and the clipping that follows is not
  // attributable to any of it — you would be hunting the distortion in each
  // app in turn while the ceiling was the cause.
  //
  // A STREAM is one app, so it goes to 150%. That is the useful case and the
  // reason to have the distinction at all: the video recorded too quiet, the
  // podcast mastered ten dB down. It is a real pipewire setting, not a trick —
  // the node's volume is simply allowed above unity — and 150% is the ceiling
  // pavucontrol has used for this for years, which makes the number one people
  // already have a feel for.
  readonly property real streamCeiling: 1.5

  function ceilingFor(node) {
    return (Sound.isPlaybackNode(node) || Sound.isRecordingNode(node))
      ? root.streamCeiling : 1.0;
  }

  function setVolume(node, v) {
    if (!node || !node.audio) return;
    node.audio.volume = Math.max(0, Math.min(root.ceilingFor(node), v));
  }

  function nudge(node, delta) {
    if (!node || !node.audio) return;
    root.setVolume(node, node.audio.volume + delta);
  }

  function toggleMute(node) {
    if (!node || !node.audio) return;
    node.audio.muted = !node.audio.muted;
  }

  // preferredDefault*, not a wpctl call: quickshell writes the same pipewire
  // metadata wpctl would, and setting it here means the change is already in
  // the property the bar's own meter is bound to before any process could have
  // started. Which of the two it is comes off the node's class, so one key
  // does both lists.
  function setDefault(node) {
    if (!node) return;
    if (Sound.isSinkNode(node)) Pipewire.preferredDefaultAudioSink = node;
    else if (Sound.isSourceNode(node)) Pipewire.preferredDefaultAudioSource = node;
  }

  // ── the two that have to shell out ──────────────────────────────────────
  // Queued through one process rather than fired off with execDetached: both
  // of these change state that has to be re-read afterwards, and two profile
  // switches racing each other on the same card leave it in whichever one
  // finished last for reasons nobody can see.
  property var queue: []

  Process {
    id: actProc
    onExited: {
      root.refreshCards();
      root.drain();
    }
  }

  function run(cmd) {
    root.queue.push(cmd);
    root.drain();
  }

  function drain() {
    if (root.queue.length === 0 || actProc.running) return;
    actProc.command = root.queue.shift();
    actProc.running = true;
  }

  // Addressed by object.serial, which is what pipewire-pulse uses as a pulse
  // index — NOT the node id. Verified against a live stream rather than
  // assumed: pw-play arrived as node 63 with object.serial 27098, and pactl
  // listed that sink-input as 27098.
  function moveStream(node, target) {
    if (!node || !target) return;
    const idx = Sound.pulseIndex(node);
    if (idx === "") return;
    const verb = Sound.isPlaybackNode(node) ? "move-sink-input" : "move-source-output";
    root.run(["pactl", verb, idx, String(target.name)]);
  }

  function setProfile(card, profile) {
    if (!card || !profile) return;
    root.run(["pactl", "set-card-profile", String(card.name), String(profile.key)]);
  }

  // Where a stream could go next. The devices that match its direction, so a
  // microphone's capture never offers to move to a pair of speakers.
  function devicesFor(node) {
    return Sound.isPlaybackNode(node) ? root.sinks : root.sources;
  }

  function cycleRoute(node, current, delta) {
    const next = Sound.nextDevice(root.devicesFor(node), current, delta);
    if (next) root.moveStream(node, next);
  }

  function cycleProfile(card, delta) {
    const next = Sound.nextProfile(card, delta);
    if (next) root.setProfile(card, next);
  }
}
