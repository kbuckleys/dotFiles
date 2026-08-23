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

ShellRoot {
  id: root

  // keep popups for logic, but UI will be morphed via bar
  RunnerPopup { id: runner; statusbar: bar; screen: root.focusedScreen; morphMode: root.layerOpen && root.activeLayer === "runner" && root.focusOnPillScreen }
  FolioPopup { id: folio; statusbar: bar; screen: root.focusedScreen; morphMode: root.layerOpen && root.activeLayer === "folio" && root.focusOnPillScreen }
  ErebusPopup { id: erebus; statusbar: bar; screen: root.focusedScreen; morphMode: root.layerOpen && root.activeLayer === "erebus" && root.focusOnPillScreen }
  ScoutPopup { id: scout; statusbar: bar; screen: root.focusedScreen; morphMode: root.layerOpen && root.activeLayer === "scout" && root.focusOnPillScreen }
  LexiPopup { id: lexi; statusbar: bar; screen: root.focusedScreen; morphMode: root.layerOpen && root.activeLayer === "lexi" && root.focusOnPillScreen }
  HitmanPopup { id: hitman; statusbar: bar; screen: root.focusedScreen; morphMode: root.layerOpen && root.activeLayer === "hitman" && root.focusOnPillScreen }
  IdeoPopup { id: ideo; statusbar: bar; screen: root.focusedScreen; morphMode: root.layerOpen && root.activeLayer === "ideo" && root.focusOnPillScreen }
  VaultPopup { id: vault; statusbar: bar; screen: root.focusedScreen; morphMode: root.layerOpen && root.activeLayer === "vault" && root.focusOnPillScreen }
  AdderPopup { id: adder; statusbar: bar; screen: root.focusedScreen; morphMode: root.layerOpen && root.activeLayer === "adder" && root.focusOnPillScreen }

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
    activeLayer === "adder" ? adder : null)
  // the pill only morphs when the open layer lives on the pill's monitor;
  // layers spawned elsewhere float independently and leave the morpheus row alone
  readonly property bool pillMorphed: layerOpen && focusOnPillScreen
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
  property int audioContentWidth: audioInner.implicitWidth + Zenon.padBar * 2
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
    } catch (e) {}
    return 320
  }

  // global ipc to set activeLayer
  IpcHandler {
    target: "Morpheus"
    function showLayer(layer: string) { root.activeLayer = layer; }
    function hideLayer() { root.activeLayer = ""; }
  }

  // watch popups' shown to sync activeLayer (when they toggle via their own ipc)
  Connections { target: runner; function onShownChanged() { if (runner.shown) root.activeLayer = "runner"; else if (root.activeLayer==="runner") root.activeLayer = ""; } }
  Connections {
    target: folio
    function onShownChanged() { if (folio.shown) root.activeLayer = "folio"; else if (root.activeLayer==="folio") root.activeLayer = ""; }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (folio.collapsing && root.activeLayer==="folio") root.activeLayer = ""; }
  }
  Connections { target: erebus; function onShownChanged() { if (erebus.shown) root.activeLayer = "erebus"; else if (root.activeLayer==="erebus") root.activeLayer = ""; } }
  Connections {
    target: scout
    function onShownChanged() { if (scout.shown) root.activeLayer = "scout"; else if (root.activeLayer==="scout") root.activeLayer = ""; }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (scout.collapsing && root.activeLayer==="scout") root.activeLayer = ""; }
  }
  Connections {
    target: lexi
    function onShownChanged() { if (lexi.shown) root.activeLayer = "lexi"; else if (root.activeLayer==="lexi") root.activeLayer = ""; }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (lexi.collapsing && root.activeLayer==="lexi") root.activeLayer = ""; }
  }
  Connections {
    target: hitman
    function onShownChanged() { if (hitman.shown) root.activeLayer = "hitman"; else if (root.activeLayer==="hitman") root.activeLayer = ""; }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (hitman.collapsing && root.activeLayer==="hitman") root.activeLayer = ""; }
  }
  Connections {
    target: ideo
    function onShownChanged() { if (ideo.shown) root.activeLayer = "ideo"; else if (root.activeLayer==="ideo") root.activeLayer = ""; }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (ideo.collapsing && root.activeLayer==="ideo") root.activeLayer = ""; }
  }
  Connections {
    target: vault
    function onShownChanged() { if (vault.shown) root.activeLayer = "vault"; else if (root.activeLayer==="vault") root.activeLayer = ""; }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (vault.collapsing && root.activeLayer==="vault") root.activeLayer = ""; }
  }
  Connections {
    target: adder
    function onShownChanged() { if (adder.shown) root.activeLayer = "adder"; else if (root.activeLayer==="adder") root.activeLayer = ""; }
    // start collapsing the pill the moment the close BEGINS. Waiting for
    // `shown` means waiting for the whole close animation to finish first,
    // which left the pill sitting there expanded and empty afterwards.
    function onCollapsingChanged() { if (adder.collapsing && root.activeLayer==="adder") root.activeLayer = ""; }
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
      margins.bottom: 6
      margins.top: 6
      Behavior on margins.left { NumberAnimation { duration: Zenon.slow; easing.type: Easing.OutCubic } }
      Behavior on margins.right { NumberAnimation { duration: Zenon.slow; easing.type: Easing.OutCubic } }
      Behavior on margins.bottom { NumberAnimation { duration: Zenon.slow; easing.type: Easing.OutCubic } }

    Rectangle {
      id: bg
      width: parent.width
      height: root.pillMorphed ? root.barHeightExpanded : root.barHeightCollapsed
      color: Zenon.panelBg
      border.color: Zenon.surface
      border.width: 1
      // single uniform radius so all four corners stay even during morph
      radius: root.pillMorphed ? 12 : 18
      clip: true
      Behavior on height { NumberAnimation { duration: Zenon.slow; easing.type: Easing.OutCubic } }
      Behavior on radius { NumberAnimation { duration: Zenon.slow; easing.type: Easing.OutCubic } }

      // morpheus content - slides out only when a layer morphs ON THIS MONITOR
      // (or the audio hover swap takes over); foreign-monitor layers leave
      // the morpheus row fully intact
      Item {
        id: morpheusContent
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: (root.pillMorphed || root.audioHover) ? 0 : 1
        x: (root.pillMorphed || root.audioHover) ? -18 : 0
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Easing.OutCubic } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Easing.OutCubic } }

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
        opacity: root.audioHover ? 1 : 0
        x: root.audioHover ? 0 : 18
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Easing.OutCubic } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Easing.OutCubic } }

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

        Row {
          id: audioInner
          anchors.centerIn: parent
          // 0 like the bar row: the dividers carry their own gaps
          spacing: 0

          component AudioButton: Text {
            property string glyph
            signal clicked
            text: glyph
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 18
            color: btnArea.containsMouse ? Zenon.cyan : Zenon.white
            Behavior on color {
              ColorAnimation { duration: Zenon.fast; easing.type: Easing.OutCubic }
            }
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            MouseArea { id: btnArea; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
          }

          // transport controls
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

          Divider { implicitHeight: 32; anchors.verticalCenter: parent.verticalCenter }

          // track
          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: mprisMod.player !== null && mprisMod.title !== ""
            text: {
              if (mprisMod.artist !== "") return mprisMod.title + " — " + mprisMod.artist;
              return mprisMod.title;
            }
            color: Zenon.green
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: Font.Bold
            font.pixelSize: 15
            width: Math.min(implicitWidth, 340)
            elide: Text.ElideMiddle
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: mprisMod.player === null
            text: "nothing playing"
            color: Zenon.muted
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 14
          }

          Divider { implicitHeight: 32; anchors.verticalCenter: parent.verticalCenter }

          // volume
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: pulseMod.tooltipText
            color: Zenon.white
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: Font.Bold
            font.pixelSize: 15
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
