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
import "heimdallr"
import "sloth"
import "picasso"

ShellRoot {
  id: root

  // keep popups for logic, but UI will be morphed via bar
  // the notification daemon's on-screen half. Not a morph layer: toasts
  // arrive on their own schedule rather than being opened, so they stack
  // above the pill instead of becoming it.
  HowlerToasts { statusbar: bar; screen: root.focusedScreen }
  // the wallpaper, on its own background layer per monitor
  PicassoDaemon { }

  HeimdallrLock { id: heimdallr }
  // the idle daemon, in place of hypridle. It calls heimdallr directly rather
  // than shelling out to `qs ipc` to reach the process it is already inside.
  SlothDaemon { lockscreen: heimdallr }
  RunnerPopup { id: runner; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphSource === "runner" && root.morphOnPill; morphFade: root.layerFade; morphRadius: root.pillRadius }
  FolioPopup { id: folio; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphSource === "folio" && root.morphOnPill; morphFade: root.layerFade }
  ErebusPopup { id: erebus; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphSource === "erebus" && root.morphOnPill; morphFade: root.layerFade; morphRadius: root.pillRadius }
  ScoutPopup { id: scout; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphSource === "scout" && root.morphOnPill; morphFade: root.layerFade }
  LexiPopup { id: lexi; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphSource === "lexi" && root.morphOnPill; morphFade: root.layerFade }
  HitmanPopup { id: hitman; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphSource === "hitman" && root.morphOnPill; morphFade: root.layerFade }
  IdeoPopup { id: ideo; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphSource === "ideo" && root.morphOnPill; morphFade: root.layerFade }
  VaultPopup { id: vault; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphSource === "vault" && root.morphOnPill; morphFade: root.layerFade }
  AdderPopup { id: adder; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphSource === "adder" && root.morphOnPill; morphFade: root.layerFade }
  HowlerPopup { id: howler; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphSource === "howler" && root.morphOnPill; morphFade: root.layerFade }
  PicassoPopup { id: picasso; statusbar: bar; screen: root.focusedScreen; morphMode: root.morphSource === "picasso" && root.morphOnPill; morphFade: root.layerFade }

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
  function beginMorph(layer) {
    morphRelease.stop();
    root.morphSource = layer;
    root.morphOnPill = root.focusOnPillScreen;
    root.activeLayer = layer;
  }
  function endMorph(layer) {
    if (root.activeLayer === layer) root.activeLayer = "";
    if (root.morphSource === layer) morphRelease.restart();
  }

  // The pill's corner radius, as a root property rather than a literal buried
  // in bg: a morphed layer paints inside these corners, so it has to round to
  // the same number, and to the same number *this frame* — the radius eases,
  // and a layer that rounded to the end value cut its highlight across the
  // pill's corner for the whole animation.
  property real pillRadius: root.pillMorphed ? 12 : 18
  Behavior on pillRadius { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }

  // 0 = the pill is wearing morpheus, 1 = it is fully wearing the layer.
  // Same duration and easing as every other pill Behavior, so it is an exact
  // stand-in for the pill's own visual progress. Both halves of every
  // crossfade read this one scalar, which is what keeps them from drifting.
  property real morphFactor: root.pillMorphed ? 1 : 0
  Behavior on morphFactor { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }
  property real audioFactor: root.audioHover ? 1 : 0
  Behavior on audioFactor { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
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
    } catch (e) {}
    return 1000
  }
  property int currentBarWidth: pillMorphed ? barWidthExpanded
    : (audioHover ? audioTargetWidth : barWidthCollapsed)
  // the audio swap stays centred like every other pill state. Its width floors
  // at the collapsed width so neither edge sweeps inward on hover — the pointer
  // (which sits near the right edge, over mpris/vol) can never fall outside the
  // pill mid-animation and drop the hover latch.
  property int audioTargetWidth: Math.min(1000,
    Math.max(320, root.barWidthCollapsed, audioContentWidth))
  // audio hover swap: morpheus contents are replaced by track controls until
  // the pointer leaves the pill. Latched with hysteresis so the fade-out
  // of the morpheus row (which kills module hover instantly) can't flicker.
  property bool audioHover: false
  readonly property bool audioWanted: !layerOpen &&
    (mprisMod.hovered || pulseMod.hovered || audioMouse.containsMouse)
  onAudioWantedChanged: {
    if (root.audioWanted) {
      root.audioHover = true;
      audioUnlatch.stop();
    } else {
      audioUnlatch.restart();
    }
  }
  Timer {
    id: audioUnlatch
    interval: 250
    onTriggered: root.audioHover = root.audioWanted
  }
  property int audioContentWidth: Math.ceil(audioInner.naturalWidth) + Zenon.padBar * 2
  property int barHeightCollapsed: 32
  property int barHeightExpanded: {
    if (!layerOpen) return barHeightCollapsed;
    try {
      if (activeLayer === "runner") return 32
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
      exclusionMode: root.pillMorphed ? ExclusionMode.Ignore : ExclusionMode.Auto
      color: "transparent"
      // always centred on its screen — collapsed, morphed, or audio-swapped
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
      Behavior on height { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }

      // morpheus content - slides out only when a layer morphs ON THIS MONITOR
      // (or the audio hover swap takes over); foreign-monitor layers leave
      // the morpheus row fully intact
      Item {
        id: morpheusContent
        anchors.fill: parent
        visible: opacity > 0.01
        // read straight off the animated scalars — no Behavior of its own.
        // A Behavior here would be a second easing chasing an already-easing
        // target, which is what made the row lag the pill and overlap whatever
        // was fading in on top of it.
        opacity: root.pillRowFade * (1 - root.audioFactor)
        x: -18 * Math.max(root.morphFactor, root.audioFactor)

        RowLayout {
          id: barLayout
          anchors.fill: parent
          anchors.leftMargin: Zenon.padBar
          anchors.rightMargin: Zenon.padBar
          // spacing stays 0 on purpose: every gap is a real item, so a module
          // collapsing takes its own spacing with it instead of snapping shut
          // when the layout finally drops it.
          spacing: 0

          UpdateModule { id: updateMod; implicitHeight: 32 }
          TrayExpander { id: trayMod; implicitHeight: 32 }
          DividerSlot { active: updateMod.hasUpdates || trayMod.hasTray }
          Workspaces { implicitHeight: 32 }

          Item { Layout.fillWidth: true; implicitHeight: 1 }

          Divider { implicitHeight: 32 }
          NetworkModule { implicitHeight: 32 }
          Divider { implicitHeight: 32 }
          GpuModule { implicitHeight: 32 }
          Gap {}
          // cpu and its temperature read as one reading, so no gap between them
          CpuModule { implicitHeight: 32 }
          TemperatureModule { implicitHeight: 32 }
          Gap {}
          MemoryModule { implicitHeight: 32 }
          Divider { implicitHeight: 32 }
          ClockModule { implicitHeight: 32 }
          Gap {}
          Item {
            id: audioGroup
            implicitWidth: audioRow.implicitWidth
            implicitHeight: 32
            Layout.preferredWidth: audioRow.implicitWidth
            Layout.preferredHeight: 32
            Row {
              id: audioRow
              anchors.verticalCenter: parent.verticalCenter
              MprisModule { id: mprisMod; implicitHeight: 32 }
              PulseAudioModule { id: pulseMod; implicitHeight: 32 }
            }
          }

          Divider { implicitHeight: 32 }
          // the bell knows nothing about howler; it is handed the numbers and
          // reports the click back, like every other module in this bar
          NotificationModule {
            implicitHeight: 32
            unread: Howler.unread
            total: Howler.history.length
            tooltipText: root.notifTooltip
            onActivated: howler.toggle()
            onCleared: { Howler.dismissAll(); Howler.clearHistory(); }
          }

          // mic / screen-share / recording. Sits outside audioGroup so hovering
          // it doesn't trigger the audio swap.
          DividerSlot { active: statusMod.active }
          StatusModule { id: statusMod; implicitHeight: 32 }
        }
      }

      // audio hover content - replaces the morpheus row until pointer leaves the pill
      Item {
        id: audioContent
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: root.audioFactor * root.pillRowFade
        x: 18 * (1 - root.audioFactor)

        // latches hover while the pointer is anywhere over the pill
        MouseArea {
          id: audioMouse
          anchors.fill: parent
          hoverEnabled: true
          // scroll anywhere over the swapped pill adjusts volume, 1% per notch
          onWheel: (wheel) => {
            pulseMod.nudgeVolume(wheel.angleDelta.y > 0 ? 0.01 : -0.01);
            wheel.accepted = true;
          }
        }

        Item {
          id: audioInner
          anchors.fill: parent
          anchors.leftMargin: Zenon.padBar
          anchors.rightMargin: Zenon.padBar

          // Volume is pinned to the left edge and the transport controls to the
          // right; only the track title floats. In one centred Row every part
          // shifted whenever the title changed length or a track ended, which
          // slid the play button out from under the pointer mid-click.
          readonly property real trackNatural: mprisMod.player === null
            ? idleText.implicitWidth : Math.min(trackText.implicitWidth, 340)
          readonly property real naturalWidth:
            volGroup.implicitWidth + transportGroup.implicitWidth + audioInner.trackNatural

          component AudioButton: Text {
            property string glyph
            signal clicked
            text: glyph
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 18
            color: btnArea.containsMouse ? Zenon.cyan : Zenon.white
            Behavior on color {
              ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
            }
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            MouseArea { id: btnArea; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
          }

          // ── volume, pinned left ──
          Row {
            id: volGroup
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Text {
              id: volText
              anchors.verticalCenter: parent.verticalCenter
              text: pulseMod.tooltipText
              color: Zenon.white
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 15
            }
            Divider { implicitHeight: 32; anchors.verticalCenter: parent.verticalCenter }
          }

          // ── track, centred in whatever is left between the two ──
          Item {
            id: trackBox
            anchors.left: volGroup.right
            anchors.right: transportGroup.left
            anchors.verticalCenter: parent.verticalCenter
            height: 32
            // the pill eases to its hover width over Zenon.slow, so this gap is
            // briefly narrower than the title needs on the way open
            clip: true

            Text {
              id: trackText
              anchors.centerIn: parent
              visible: mprisMod.player !== null && mprisMod.title !== ""
              text: {
                // \u{...} form, not \uXXXX: U+F01D8 is above the BMP, so the
                // four-digit escape would read it as U+F01D followed by "8"
                if (mprisMod.artist !== "")
                  return mprisMod.title + " \u{F01D8} " + mprisMod.artist;
                return mprisMod.title;
              }
              color: Zenon.green
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 15
              width: Math.max(0, Math.min(implicitWidth, trackBox.width))
              elide: Text.ElideMiddle
              horizontalAlignment: Text.AlignHCenter
            }
            Text {
              id: idleText
              anchors.centerIn: parent
              visible: mprisMod.player === null
              text: "nothing playing"
              color: Zenon.muted
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 14
            }
          }

          // ── transport controls, pinned right ──
          Row {
            id: transportGroup
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Divider { implicitHeight: 32; anchors.verticalCenter: parent.verticalCenter }

            Row {
              spacing: Zenon.gap * 2
              anchors.verticalCenter: parent.verticalCenter

              AudioButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "\uF04A"   // previous
                onClicked: {
                  if (mprisMod.player) mprisMod.player.previous();
                  else Quickshell.execDetached(["playerctl", "previous"]);
                }
              }
              AudioButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: mprisMod.player && mprisMod.player.isPlaying ? "\uF04C" : "\uF04B"
                onClicked: {
                  if (mprisMod.player) mprisMod.player.togglePlaying();
                  else Quickshell.execDetached(["playerctl", "play-pause"]);
                }
              }
              AudioButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "\uF04E"   // next
                onClicked: {
                  if (mprisMod.player) mprisMod.player.next();
                  else Quickshell.execDetached(["playerctl", "next"]);
                }
              }
            }
          }
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
