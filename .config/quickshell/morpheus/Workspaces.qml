// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.SystemTray
import "helpers.js" as Helpers
import "."

Item {
  id: root
  // autofit: interpolate between workspace width and tray width driven by cross;
  // no Behavior here — width follows wsLayer (which animates via Collapsible) or
  // cross (which animates via its own Behavior) directly, so the special wash
  // at bg level (bound to workspacesMod.width) stays in lock-step with the
  // collapsing workspace instead of chasing it with a second easing.
  implicitWidth: root.hasTray ? (wsLayer.implicitWidth * (1 - root.cross) + trayLayer.implicitWidth * root.cross) : wsLayer.implicitWidth
  implicitHeight: Zenon.slot
  clip: true

  property string specialName: "special"

  readonly property var specialWorkspace: {
    var values = Hyprland.workspaces.values;
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].name).startsWith("special:")) return values[i];
    }
    return null;
  }

  // monitor-agnostic: any special focused on any monitor counts
  property string _activeSpecialName: ""
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "activespecial") {
        const parts = String(event.data).split(",");
        root._activeSpecialName = parts[0] ? parts[0].trim() : "";
      }
    }
  }
  readonly property bool specialFocused: {
    if (root.specialWorkspace === null) return false;
    if (root._activeSpecialName !== "") return true;
    try {
      const fw = Hyprland.focusedWorkspace;
      if (fw && String(fw.name).startsWith("special:")) return true;
    } catch (e) {}
    const sw = root.specialWorkspace;
    return sw.focused === true;
  }

  // ── tray ────────────────────────────────────────────────────────────────
  readonly property var trayItems: {
    const vals = SystemTray.items.values;
    const out = [];
    for (let i = 0; i < vals.length; ++i) {
      const it = vals[i];
      if (it && it.status !== Status.Passive && it.icon !== "") out.push(it);
    }
    return out;
  }
  property bool hasTray: trayItems.length > 0
  property bool hovered: false
  property bool menuOpen: false

  // 500ms grace between transitions — keeps tray visible for half a second
  // after hover/menu leave to avoid flicker when crossing the gap or briefly
  // leaving the module. Immediate on enter, delayed on leave.
  property bool _latchedShow: false
  readonly property bool _intendShow: root.hovered || root.menuOpen
  Timer {
    id: graceTimer
    interval: 500
    onTriggered: {
      if (!root._intendShow) root._latchedShow = false
    }
  }
  on_IntendShowChanged: {
    if (root._intendShow) {
      graceTimer.stop()
      root._latchedShow = true
    } else {
      graceTimer.restart()
    }
  }
  onHasTrayChanged: {
    if (!root.hasTray) {
      graceTimer.stop()
      root._latchedShow = false
      root.hovered = false
      root.menuOpen = false
    }
  }

  readonly property bool showTray: root.hasTray && root._latchedShow
  // 0 = workspaces, 1 = tray — single scalar drives both opacity and width
  property real cross: root.showTray ? 1 : 0
  Behavior on cross { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

  // hover detection without stealing clicks from workspace/tray delegates
  HoverHandler {
    id: hoverHandler
    onHoveredChanged: root.hovered = hovered
  }

  // special toggle — disabled while tray is shown so tray clicks aren't hijacked
  MouseArea {
    anchors.fill: parent
    visible: root.specialWorkspace !== null && !root.showTray
    enabled: visible
    cursorShape: Qt.PointingHandCursor
    z: 2
    onClicked: {
      var sp = root.specialWorkspace !== null
          ? root.specialWorkspace.name.replace(/^special:/, "")
          : root.specialName;
      Hyprland.dispatch('hl.dsp.workspace.toggle_special("' + sp + '")');
    }
  }

  // ── workspaces layer ──────────────────────────────────────────────────
  Item {
    id: wsLayer
    anchors.centerIn: parent
    implicitWidth: wsRow.implicitWidth
    implicitHeight: Zenon.slot
    opacity: 1 - root.cross
    visible: opacity > 0.01

    Row {
      id: wsRow
      anchors.verticalCenter: parent.verticalCenter
      leftPadding: Zenon.padModule
      rightPadding: Zenon.padModule

      Repeater {
        model: Hyprland.workspaces

        delegate: Collapsible {
          id: btn
          required property var modelData

          property bool isActive: modelData.focused

          // workspaces appear and vanish as they are used; ease the gap shut
          active: !String(modelData.name).startsWith("special:")
          openWidth: wsBox.implicitWidth + Zenon.padModule * 2

          Item {
            id: wsBox
            anchors.centerIn: parent
            implicitWidth: Math.max(wsGhost.implicitWidth, wsLabel.implicitWidth)
            implicitHeight: Zenon.slot

            BarText {
              id: wsGhost
              anchors.centerIn: parent
              text: "8"
              numeric: true
              color: Zenon.trough(Zenon.cyan)
            }

            BarText {
              id: wsLabel
              anchors.centerIn: parent
              text: {
                return ["1", "2", "3", "4", "5"].includes(String(modelData.id)) ? String(modelData.id) : " ";
              }
              numeric: true
              color: {
                if (root.specialWorkspace !== null && root.specialFocused)
                  return btn.isActive ? Zenon.pink : Zenon.trough(Zenon.pink)
                return btn.isActive ? Zenon.cyan : Zenon.dim
              }
              font.weight: {
                if (root.specialWorkspace !== null && btn.isActive)
                  return Font.Black
                return btn.isActive ? Font.ExtraBold : Font.Bold
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            enabled: !root.showTray
            onClicked: {
              Hyprland.dispatch('hl.dsp.focus({ workspace = "' + modelData.name + '" })');
            }
          }
        }
      }
    }
  }

  // ── tray layer ────────────────────────────────────────────────────────
  Item {
    id: trayLayer
    anchors.centerIn: parent
    implicitWidth: trayRow.implicitWidth
    implicitHeight: Zenon.slot
    opacity: root.cross
    visible: opacity > 0.01

    Row {
      id: trayRow
      anchors.verticalCenter: parent.verticalCenter
      leftPadding: Zenon.padModule
      rightPadding: Zenon.padModule
      spacing: 10

      Repeater {
        model: root.trayItems

        delegate: Item {
          id: trayItem
          required property var modelData

          // match the bar's own glyphs — BarText is Zenon.textSize, so tray
          // icons sit on the same visual line as the workspaces they replace
          width: Zenon.textSize
          height: Zenon.textSize
          anchors.verticalCenter: parent.verticalCenter

          Image {
            id: trayIcon
            anchors.fill: parent
            source: modelData.icon
            fillMode: Image.PreserveAspectFit
            sourceSize.width: Zenon.textSize
            sourceSize.height: Zenon.textSize
            smooth: true
            mipmap: true
            onStatusChanged: {
              if (trayIcon.status === Image.Error && trayIcon.source !== "") {
                trayIcon.source = ""
              }
            }
          }

          TrayMenu {
            id: trayMenu
            menuHandle: modelData.menu
            anchorItem: trayItem
            onMenuClosed: root.menuOpen = false
          }

          MouseArea {
            id: iconMouse
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            hoverEnabled: true
            onClicked: (mouse) => {
              if (mouse.button === Qt.LeftButton) modelData.activate()
              else if (modelData.hasMenu) {
                root.menuOpen = true
                trayMenu.open()
              }
              else modelData.secondaryActivate()
            }
          }

          Tooltip {
            anchorItem: trayItem
            cursorArea: iconMouse
            text: (modelData.tooltipTitle || modelData.title || "")
                + (modelData.tooltipDescription ? "\n" + modelData.tooltipDescription : "")
            show: iconMouse.containsMouse && text !== ""
          }
        }
      }
    }
  }
}
