// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
// MORPH PILL BAR - dynamic width max 1000, slide, all layers morph, reserves space

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "morpheus"
import "runner"
import "folio"
import "erebus"
import "scout"
import "lexi"
import "hitman"
import "ideo"
import "vault"
import "adder"
import "howler"
import "cerberus"
import "sloth"
import "picasso"
import "chronos"
import "icarus"

ShellRoot {
  id: root

  // keep popups for logic, but UI will be morphed via bar
  // the notification daemon's on-screen half. Not a morph layer: toasts
  // arrive on their own schedule rather than being opened, so they stack
  // above the pill instead of becoming it.
  HowlerToasts { statusbar: bar; screen: root.focusedScreen }
  // the wallpaper, on its own background layer per monitor
  PicassoDaemon { }
  IcarusPopup { id: icarus; screen: root.focusedScreen }
  IcarusDesktop { id: icarusDesktop; popup: icarus }

  CerberusLock { id: cerberus }
  // the idle daemon, in place of hypridle. It calls cerberus directly rather
  // than shelling out to `qs ipc` to reach the process it is already inside.
  SlothDaemon { lockscreen: cerberus }
  RunnerPopup { id: runner; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphedFor("runner") && root.morphOnPill; morphFade: root.layerFade; morphRadius: root.pillRadius }
  FolioPopup { id: folio; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphedFor("folio") && root.morphOnPill; morphFade: root.layerFade }
  ErebusPopup { id: erebus; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphedFor("erebus") && root.morphOnPill; morphFade: root.layerFade; morphRadius: root.pillRadius }
  ScoutPopup { id: scout; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphedFor("scout") && root.morphOnPill; morphFade: root.layerFade }
  LexiPopup { id: lexi; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphedFor("lexi") && root.morphOnPill; morphFade: root.layerFade }
  HitmanPopup { id: hitman; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphedFor("hitman") && root.morphOnPill; morphFade: root.layerFade }
  IdeoPopup { id: ideo; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphedFor("ideo") && root.morphOnPill; morphFade: root.layerFade }
  VaultPopup { id: vault; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphedFor("vault") && root.morphOnPill; morphFade: root.layerFade }
  AdderPopup { id: adder; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphedFor("adder") && root.morphOnPill; morphFade: root.layerFade }
  HowlerPopup { id: howler; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphedFor("howler") && root.morphOnPill; morphFade: root.layerFade }
  PicassoPopup { id: picasso; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphedFor("picasso") && root.morphOnPill; morphFade: root.layerFade }
  ChronosPopup { id: chronos; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphedFor("chronos") && root.morphOnPill; morphFade: root.layerFade }

  property var statusScreen: (function() {
    const target = Quickshell.env("QS_STATUS_SCREEN") || "HDMI-A-1";
    const screens = Quickshell.screens;
    for (let i = 0; i < screens.length; ++i) {
      if (screens[i].name === target) return screens[i];
    }
    return screens.length ? screens[0] : null;
  })()

  property string activeLayer: ""
  property bool layerOpen: activeLayer !== ""

  // ── morph state ───────────────────────────────────────────────────────────
  // Two different questions, deliberately answered by two different properties:
  //
  //   activeLayer  — "how big should the pill be". Cleared the instant a close
  //                  BEGINS so the pill starts collapsing on frame one.
  //   morphSource  — "which layer is the pill currently wearing". Held until
  //                  that layer has finished animating out. Without it the
  //                  layer's morphMode dropped at close-start along with
  //                  activeLayer, so it snapped back to its full standalone
  //                  size and background for the whole close — the "grows
  //                  larger before morphing back" jump.
  property string morphSource: ""
  //   morphFading  — the layer that WAS wearing the pill and is still
  //                  animating out while a new one takes over. morphSource is
  //                  a single string, so opening B while A was up overwrote
  //                  it, A's morphMode dropped mid-close, and A snapped to
  //                  its full standalone size for the rest of the animation.
  //                  That snap is the "brief expand" you see going straight
  //                  from one layer to another.
  property string morphFading: ""
  // A layer is wearing the pill if it is the current one OR still leaving.
  function morphedFor(layer) {
    return layer === root.morphSource || layer === root.morphFading;
  }
  // latched at open: did the layer that owns the pill spawn on the pill's own
  // monitor. Latched rather than read live so moving focus to another monitor
  // mid-session can't un-morph a layer halfway through.
  property bool morphOnPill: false
  Timer {
    id: morphRelease
    // one pill-collapse worth of grace plus a couple of frames, so the
    // release can never land before the layer's own close animation ends
    interval: Zenon.slow + 60
    onTriggered: { root.morphSource = ""; root.morphOnPill = false; }
  }
  Timer {
    id: fadeRelease
    interval: Zenon.slow + 60
    onTriggered: root.morphFading = ""
  }
  // A close does NOT collapse the pill on the spot. The very next thing to
  // happen may be another layer opening — the two arrive from one keypress and
  // in either order — and clearing activeLayer in between sends the pill all
  // the way back to morpheus' width before it expands again. Two frames of
  // grace, cancelled by beginMorph, is the difference between a handover and
  // a bounce. A real close is delayed by those two frames and nothing else.
  Timer {
    id: layerRelease
    interval: 40
    property string pending: ""
    onTriggered: {
      if (root.activeLayer === layerRelease.pending) root.activeLayer = "";
      layerRelease.pending = "";
    }
  }
  function beginMorph(layer) {
    morphRelease.stop();
    layerRelease.stop();
    layerRelease.pending = "";
    // hand the pill over rather than yanking it: whatever was wearing it
    // keeps wearing it until its own close animation has finished, so it
    // shrinks and fades into the new layer's shape instead of snapping out
    if (root.morphSource !== "" && root.morphSource !== layer) {
      root.morphFading = root.morphSource;
      fadeRelease.restart();
    }
    root.morphSource = layer;
    root.morphOnPill = root.focusOnPillScreen;
    root.activeLayer = layer;
  }
  function endMorph(layer) {
    if (root.activeLayer === layer) {
      layerRelease.pending = layer;
      layerRelease.restart();
    }
    if (root.morphSource === layer) morphRelease.restart();
  }

  // Single token in Zenon — 8:8 uniform, no morph. Kept as a root
  // property so bg and any morphed layer can still bind to the same value
  // without each importing Zenon directly (and so a future 12:8 is one line).
  property real pillRadius: Zenon.pillRadius

  // 0 = the pill is wearing morpheus, 1 = it is fully wearing the layer.
  // Same duration and easing as every other pill Behavior, so it is an exact
  // stand-in for the pill's own visual progress. Both halves of every
  // crossfade read this one scalar, which is what keeps them from drifting.
  property real morphFactor: root.pillMorphed ? 1 : 0
  Behavior on morphFactor { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }
  // The crossfade schedule, defined once here rather than re-derived in each
  // layer: the pill's own row has finished clearing by 0.45 and a layer only
  // starts appearing at 0.55, so the two can never be on screen together.
  // Both halves are handed the finished number, so they cannot drift apart.
  readonly property real pillRowFade: 1 - Math.min(1, root.morphFactor / 0.45)
  readonly property real layerFade: Math.max(0, Math.min(1, (root.morphFactor - 0.55) / 0.45))
  // monitor awareness: layers spawn on the focused monitor; they only
  // morph out of the pill when that monitor is the pill's own
  readonly property var focusedScreen: {
    const m = Hyprland.focusedMonitor;
    if (!m || !m.name) return statusScreen;
    const screens = Quickshell.screens;
    for (let i = 0; i < screens.length; ++i)
      if (screens[i].name === m.name) return screens[i];
    return statusScreen;
  }
  // the pill only morphs when Hyprland's focused monitor IS the pill's
  // monitor; decided purely from focus (not popup.window.screen, which lags
  // attachment and would let a foreign-monitor spawn morph the morpheus row first)
  readonly property string pillScreenName: bar.screen ? bar.screen.name : ""
  readonly property bool focusOnPillScreen: {
    const m = Hyprland.focusedMonitor;
    return m !== null && m !== undefined && m.name === root.pillScreenName;
  }
  readonly property var activePopup: !layerOpen ? null : (
    activeLayer === "runner" ? runner :
    activeLayer === "folio" ? folio :
    activeLayer === "erebus" ? erebus :
    activeLayer === "scout" ? scout :
    activeLayer === "lexi" ? lexi :
    activeLayer === "hitman" ? hitman :
    activeLayer === "ideo" ? ideo :
    activeLayer === "vault" ? vault :
    activeLayer === "adder" ? adder :
    activeLayer === "howler" ? howler :
    activeLayer === "picasso" ? picasso : null)
  // the pill only morphs when the open layer lives on the pill's monitor;
  // layers spawned elsewhere float independently and leave the morpheus row alone
  readonly property bool pillMorphed: layerOpen && morphOnPill

  // ── startup slide + fade ─────────────────────────────────────────────
  // The pill rises from just below its rested position while fading in, so
  // the shell's first paint reads as an arrival rather than a pop-in.
  // Slightly slower than before for a calmer arrival.
  property real barIntro: 0
  property bool _barIntroInstant: false
  Behavior on barIntro {
    enabled: !root._barIntroInstant
    NumberAnimation { duration: 750; easing.type: Easing.OutQuint }
  }
  Timer { id: barIntroTimer; interval: 60; onTriggered: root.barIntro = 1 }
  Component.onCompleted: barIntroTimer.restart()

  // replay wallpaper zoom + pill slide on unlock — the pill/wallpaper
  // sit at 0 while the lock is up (so no static frame shows through
  // the fade), then animate 0→1 once on unlock. No 1→0 reset on
  // unlock itself — that was the static-then-animate double.
  property double _lastUnlock: 0
  function parkIntro() {
    barIntroTimer.stop();
    root._barIntroInstant = true;
    root.barIntro = 0;
    root._barIntroInstant = false;
    Picasso.holdIntro();
  }
  Connections {
    target: cerberus
    function onLockedChanged() {
      if (cerberus.locked) parkIntro();
      else {
        const now = Date.now();
        if (now - root._lastUnlock < 1500) return;
        root._lastUnlock = now;
        barIntroTimer.restart();
        Picasso.replayIntro();
      }
    }
    function onCoveringChanged() {
      if (cerberus.covering) parkIntro();
    }
  }

  // dynamic pill width, max 1000, each layer retains own width
  property int morpheusContentWidth: barLayout ? barLayout.implicitWidth + 24 : 800
  property int barWidthCollapsed: Math.min(1000, morpheusContentWidth)
  property int barWidthExpanded: {
    if (!layerOpen) return barWidthCollapsed;
    try {
      // follow the runner's shrink-wrapped width exactly rather than freezing
      // the pill at the collapsed morpheus width; the 8px floor is only a guard
      // against a degenerate zero-width pill, never visible padding
      if (activeLayer === "runner" && runner && runner.contentWidth)
        return Math.min(1000, Math.max(8, runner.contentWidth))
      if (activeLayer === "folio") return 1000
      if (activeLayer === "erebus") return 250
      if (activeLayer === "scout") return 1000
      if (activeLayer === "lexi") return (lexi && lexi.wide) ? 1000 : 800
      if (activeLayer === "hitman") return 1000
      if (activeLayer === "ideo") return 1000
      if (activeLayer === "vault") return 1000
      if (activeLayer === "adder") return 600
      if (activeLayer === "howler") return 800
      if (activeLayer === "picasso") return 1000
      // chronos is sized by its calendar grid, not stretched to the usual max
      if (activeLayer === "chronos" && chronos && chronos.panelWidth)
        return Math.min(1000, chronos.panelWidth)
    } catch (e) {}
    return 1000
  }
  property int currentBarWidth: pillMorphed ? barWidthExpanded : barWidthCollapsed
  // the pill is exactly one slot tall
  property int barHeightCollapsed: Zenon.slot
  property int barHeightExpanded: {
    if (!layerOpen) return barHeightCollapsed;
    try {
      if (activeLayer === "runner") return Zenon.slot
      if (activeLayer === "folio" && folio && folio.calcHeight) return folio.calcHeight()
      if (activeLayer === "erebus" && erebus && erebus.calcHeight) return erebus.calcHeight()
      if (activeLayer === "scout" && scout && scout.calcHeight) return scout.calcHeight()
      if (activeLayer === "lexi" && lexi && lexi.calcHeight) return lexi.calcHeight()
      if (activeLayer === "hitman" && hitman && hitman.calcHeight) return hitman.calcHeight()
      if (activeLayer === "ideo" && ideo && ideo.calcHeight) return ideo.calcHeight()
      if (activeLayer === "vault" && vault && vault.calcHeight) return vault.calcHeight()
      if (activeLayer === "adder" && adder && adder.calcHeight) return adder.calcHeight()
      if (activeLayer === "howler" && howler && howler.calcHeight) return howler.calcHeight()
      if (activeLayer === "picasso" && picasso && picasso.calcHeight) return picasso.calcHeight()
      if (activeLayer === "chronos" && chronos && chronos.calcHeight) return chronos.calcHeight()
    } catch (e) {}
    return 320
  }

  // The bell's hover text: the most recent few, newest first. Built here
  // rather than in the module so the module stays a pure display.
  readonly property string notifTooltip: {
    const h = Howler.history;
    if (h.length === 0) return "No notifications";
    const lines = h.slice(0, 6).map((n) => {
      const app = (n.appName && n.appName !== "") ? n.appName : "unknown";
      return "<b>" + app + "</b>  " + (n.summary ?? "");
    });
    let tip = lines.join("\n");
    if (h.length > 6) tip += "\n… and " + (h.length - 6) + " more";
    return tip;
  }

  // global ipc to set activeLayer
  IpcHandler {
    target: "Morpheus"
    function showLayer(layer: string) { root.beginMorph(layer); }
    function hideLayer() { root.endMorph(root.activeLayer !== "" ? root.activeLayer : root.morphSource); }
  }

  // watch popups' shown to sync activeLayer (when they toggle via their own ipc)
  Connections { target: runner; function onShownChanged() { if (runner.shown) root.beginMorph("runner"); else root.endMorph("runner"); } }
  Connections {
    target: folio
    function onShownChanged() { if (folio.shown) root.beginMorph("folio"); else root.endMorph("folio"); }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (folio.collapsing) root.endMorph("folio"); }
  }
  Connections { target: erebus; function onShownChanged() { if (erebus.shown) root.beginMorph("erebus"); else root.endMorph("erebus"); } }
  Connections {
    target: scout
    function onShownChanged() { if (scout.shown) root.beginMorph("scout"); else root.endMorph("scout"); }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (scout.collapsing) root.endMorph("scout"); }
  }
  Connections {
    target: picasso
    function onShownChanged() { if (picasso.shown) root.beginMorph("picasso"); else root.endMorph("picasso"); }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (picasso.collapsing) root.endMorph("picasso"); }
  }

  Connections {
    target: chronos
    function onShownChanged() { if (chronos.shown) root.beginMorph("chronos"); else root.endMorph("chronos"); }
  }
  Connections {
    target: chronos
    function onCollapsingChanged() { if (chronos.collapsing) root.endMorph("chronos"); }
  }
  Connections {
    target: howler
    function onShownChanged() { if (howler.shown) root.beginMorph("howler"); else root.endMorph("howler"); }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (howler.collapsing) root.endMorph("howler"); }
  }
  Connections {
    target: lexi
    function onShownChanged() { if (lexi.shown) root.beginMorph("lexi"); else root.endMorph("lexi"); }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (lexi.collapsing) root.endMorph("lexi"); }
  }
  Connections {
    target: hitman
    function onShownChanged() { if (hitman.shown) root.beginMorph("hitman"); else root.endMorph("hitman"); }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (hitman.collapsing) root.endMorph("hitman"); }
  }
  Connections {
    target: ideo
    function onShownChanged() { if (ideo.shown) root.beginMorph("ideo"); else root.endMorph("ideo"); }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (ideo.collapsing) root.endMorph("ideo"); }
  }
  Connections {
    target: vault
    function onShownChanged() { if (vault.shown) root.beginMorph("vault"); else root.endMorph("vault"); }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (vault.collapsing) root.endMorph("vault"); }
  }
  Connections {
    target: adder
    function onShownChanged() { if (adder.shown) root.beginMorph("adder"); else root.endMorph("adder"); }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (adder.collapsing) root.endMorph("adder"); }
  }

  PanelWindow {
      id: bar
      anchors { left: true; right: true; bottom: true }
      implicitHeight: bg.height
      screen: root.statusScreen
      // The reserved strip never changes size. Auto followed the pill's live
      // height, and Ignore released the reservation altogether while morphed
      // — either way every tiled window on this monitor resized the moment a
      // layer opened. Pinned to the collapsed pill instead, so the desktop
      // underneath stays exactly where it is whatever the pill is doing.
      exclusionMode: ExclusionMode.Normal
      exclusiveZone: root.barHeightCollapsed + Zenon.padScreen
      color: "transparent"
      // always centred on its screen — collapsed or morphed
      readonly property int sideMargin: Math.max(0,
        ((bar.screen ? bar.screen.width : 1920) - root.currentBarWidth) / 2)
      margins.left: bar.sideMargin
      margins.right: bar.sideMargin
      margins.bottom: Zenon.padScreen
      margins.top: Zenon.padScreen
      Behavior on margins.left { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }
      Behavior on margins.right { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }
      Behavior on margins.bottom { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }

    Rectangle {
      id: bg
      width: parent.width
      height: root.pillMorphed ? root.barHeightExpanded : root.barHeightCollapsed
      color: Zenon.panelBg
      border.color: Zenon.surface
      border.width: 1
      // single uniform radius so all four corners stay even during morph
      radius: root.pillRadius
      clip: true
      opacity: root.barIntro
      transform: Translate { y: (1 - root.barIntro) * 22 }
      Behavior on height { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }

      // The now-playing takeover. Drawn at pill level and not inside the
      // module, for two reasons: it has to reach past the bar's own right
      // padding to the pill's edge, and it has to round off with the pill's
      // corner rather than ending in a square one just short of it.
      //
      // Its left edge is summed down the layout chain rather than mapped,
      // because mapFromItem is a function call and would not re-run when a
      // module beside it changes width.
      // Starts just past the divider's rule, not at the module's own left
      // edge. A Divider carries a gap on EACH side, so the module begins a
      // full Zenon.gap right of the 1px line — measuring from there left a
      // strip of bare pill between the divider and the green.
      readonly property real takeoverX:
        Zenon.padBar + audioGroup.x + nowMod.x - Zenon.gap
      // It runs to the pill's edge only when nothing follows it. With the
      // status icons up it stops at the module's own right edge and stays
      // square: taking over the END of the bar is one thing, painting across
      // the mic and recording indicators is another.
      readonly property bool takeoverToEdge: !statusMod.active
      readonly property real takeoverW: bg.takeoverToEdge
        ? Math.max(0, bg.width - bg.takeoverX - bg.border.width)
        // gap on both sides of now playing, plus 1px to sit 0.5px beyond
        // the divider line on the right — otherwise a blank strip shows
        // between the green wash and the status divider when status is up
        : Math.max(0, nowMod.width + Zenon.gap * 2 + 1)
      Rectangle {
        id: takeover
        // Faded rather than switched. BarText already eases its colour, so
        // without this the green vanished in one frame while the text was
        // still crossfading from black — half a beat of black on black.
        visible: nowMod.active && opacity > 0.01
        opacity: root.pillRowFade * (NowPlaying.playing ? 1 : 0)
        Behavior on opacity {
          NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease }
        }
        // A wash the pill takes on, not a block sitting on it — dim enough
        // that the green text keeps its own weight against it. The alpha
        // lives in the colour, not in `opacity`, which is already carrying
        // the fade in and out.
        color: Qt.rgba(Zenon.green.r, Zenon.green.g, Zenon.green.b, 0.18)
        // Inset by the pill's own stroke, and rounded to the INNER curve.
        // Sitting flush to bg's bounds put the green on top of the 1px border
        // with a corner struck at the outer radius, so the two arcs did not
        // nest and the join showed as a sliver.
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: bg.border.width
        anchors.bottomMargin: bg.border.width
        // placed from the left rather than anchored right, because it no
        // longer always ends at the right edge
        x: bg.takeoverX
        width: bg.takeoverW
        topRightRadius: bg.takeoverToEdge
          ? Math.max(0, bg.radius - bg.border.width) : 0
        bottomRightRadius: bg.takeoverToEdge
          ? Math.max(0, bg.radius - bg.border.width) : 0
        Behavior on width {
          NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease }
        }
      }

      // special workspace wash — gap-to-gap, but when update+notifications are
      // collapsed the left gap would leave a 4px strip before the pill's
      // rounded edge. Extend to the pill's edge with inner radius in that case.
      readonly property bool leftHasContent: notifMod.active || updateMod.active
      readonly property real specialX: bg.leftHasContent ? Zenon.padBar + workspacesMod.x - Zenon.gap : bg.border.width
      readonly property real specialW: bg.leftHasContent ? workspacesMod.width + Zenon.gap * 2 : Zenon.padBar + workspacesMod.x + workspacesMod.width + Zenon.gap - bg.border.width
      Rectangle {
        id: specialTakeover
        visible: workspacesMod.specialWorkspace !== null && opacity > 0.01
        opacity: root.pillRowFade * (workspacesMod.specialWorkspace !== null ? 1 : 0)
        Behavior on opacity { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }
        color: workspacesMod.specialFocused
          ? Qt.rgba(Zenon.red.r, Zenon.red.g, Zenon.red.b, 0.22)
          : Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.18)
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: bg.border.width
        anchors.bottomMargin: bg.border.width
        x: bg.specialX
        // 1px extra on the right so tray mode with special never shows a black strip next to the divider
        width: bg.specialW + 1
        radius: 0
        topLeftRadius: bg.leftHasContent ? 0 : Math.max(0, bg.radius - bg.border.width)
        bottomLeftRadius: bg.leftHasContent ? 0 : Math.max(0, bg.radius - bg.border.width)
      }

      // tray sunrise wash — gap-to-gap like special, but warm and at bg level
      // so it fills the 1px strip on the right that the inner Workspaces wash
      // (clipped to the module) cannot reach in tray mode
      readonly property real trayGlowX: bg.leftHasContent ? Zenon.padBar + workspacesMod.x - Zenon.gap : bg.border.width
      readonly property real trayGlowW: bg.leftHasContent ? workspacesMod.width + Zenon.gap * 2 : Zenon.padBar + workspacesMod.x + workspacesMod.width + Zenon.gap - bg.border.width
      Rectangle {
        id: trayGlow
        visible: workspacesMod.hasTray && opacity > 0.01
        opacity: root.pillRowFade * (workspacesMod.hasTray ? 1 : 0)
        Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: bg.border.width
        anchors.bottomMargin: bg.border.width
        x: bg.trayGlowX
        // 1px extra on the right so tray mode never shows a black strip right next to the divider
        width: bg.trayGlowW + 1
        radius: 0
        topLeftRadius: bg.leftHasContent ? 0 : Math.max(0, bg.radius - bg.border.width)
        bottomLeftRadius: bg.leftHasContent ? 0 : Math.max(0, bg.radius - bg.border.width)
        topRightRadius: 0
        bottomRightRadius: 0
        // bottom half yellow, seamlessly blending into the darker upper half — no hard line
        gradient: Gradient {
          orientation: Gradient.Vertical
          GradientStop { position: 0.0; color: "transparent" }
          GradientStop { position: 0.52; color: "transparent" }
          GradientStop { position: 1.0; color: Qt.rgba(Zenon.yellow.r, Zenon.yellow.g, Zenon.yellow.b, 0.22) }
        }
      }

      // morpheus content - slides out only when a layer morphs ON THIS MONITOR;
      // foreign-monitor layers leave the morpheus row fully intact
      Item {
        id: morpheusContent
        anchors.fill: parent
        visible: opacity > 0.01
        // read straight off the animated scalars — no Behavior of its own.
        // A Behavior here would be a second easing chasing an already-easing
        // target, which is what made the row lag the pill and overlap whatever
        // was fading in on top of it.
        opacity: root.pillRowFade
        x: -18 * root.morphFactor

        RowLayout {
          id: barLayout
          anchors.fill: parent
          anchors.leftMargin: Zenon.padBar
          anchors.rightMargin: Zenon.padBar
          // spacing stays 0 on purpose: every gap is a real item, so a module
          // collapsing takes its own spacing with it instead of snapping shut
          // when the layout finally drops it.
          spacing: 0

          // The updates count leads, then the bell, then the tray: the same
          // kind of thing three times over — a count of something waiting for
          // you — and the first two now wear the same orange. The bell knows
          // nothing about howler; it is handed the numbers and reports the
          // click back, like every other module in this bar.
          UpdateModule { id: updateMod; implicitHeight: Zenon.slot }
          NotificationModule {
            id: notifMod
            implicitHeight: Zenon.slot
            unread: Howler.unread
            total: Howler.history.length
            tooltipText: root.notifTooltip
            onActivated: howler.toggle()
            onCleared: { Howler.dismissAll(); Howler.clearHistory(); }
          }
          // tray lives inside workspaces now — hover to reveal, crossfades and autofits
          Collapsible {
            active: notifMod.active || updateMod.active
            openWidth: Zenon.gap * 2 + 1
            Divider { implicitHeight: Zenon.slot }
          }
          Workspaces { id: workspacesMod; implicitHeight: Zenon.slot }

          Item { Layout.fillWidth: true; implicitHeight: 1 }

          Divider { implicitHeight: Zenon.slot }
          ClockModule {
            implicitHeight: Zenon.slot
            // the clock opens the calendar, the same way the bell opens howler
            onActivated: chronos.toggle()
          }

          // The meters, in one run. No titles and no temperatures between
          // them: they are told apart by colour — magenta/blue throughput,
          // pink gpu, red cpu, yellow ram, green volume — and a label between two
          // of them would break the row of notches that makes them read as one
          // instrument. The exact numbers are all still in the tooltips.
          Divider { implicitHeight: Zenon.slot }
          NetworkModule { implicitHeight: Zenon.slot }
          Gap {}
          GpuModule { implicitHeight: Zenon.slot }
          Gap {}
          CpuModule { implicitHeight: Zenon.slot }
          Gap {}
          MemoryModule { implicitHeight: Zenon.slot }
          Gap {}

          // Volume and the track name are one group with one panel between
          // them. They show the SAME panel, so hovering across from one to the
          // other used to close it and reopen it somewhere else; anchored to
          // the group instead it stays put and simply follows whichever half
          // the pointer is on. The divider keeps them visually apart and eases
          // away with the track name when nothing is playing.
          //
          // No transport glyph in here: the track name glows while something
          // is playing, which is the state that glyph reported, and the
          // controls themselves live in the panel.
          Item {
            id: audioGroup
            implicitWidth: audioRow.implicitWidth
            implicitHeight: Zenon.slot
            Layout.preferredWidth: audioRow.implicitWidth
            Layout.preferredHeight: Zenon.slot

            Row {
              id: audioRow
              anchors.verticalCenter: parent.verticalCenter
              PulseAudioModule { id: volMod; implicitHeight: Zenon.slot }
              DividerSlot { active: nowMod.active }
              NowPlayingModule { id: nowMod; implicitHeight: Zenon.slot }
            }

            NowPlayingPanel {
              anchorItem: audioGroup
              sourceHovered: volMod.hovered || nowMod.hovered
            }
          }

          // mic / screen-share / recording
          DividerSlot { active: statusMod.active }
          StatusModule { id: statusMod; implicitHeight: Zenon.slot }
        }
      }

      // layer content area kept empty – actual layer UI lives in its own
      // PanelWindow (now transparent when morphMode) positioned over this bg,
      // so the bar's bg appears to morph into the layer.
      Item {
        id: layerContent
        anchors.fill: parent
        visible: false
      }
    }
  }
}
