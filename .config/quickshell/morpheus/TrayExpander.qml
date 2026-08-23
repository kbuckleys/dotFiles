// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Widgets
import "."

Collapsible {
  id: root
  // no tray icons -> the whole slot eases away, glyph included
  active: root.hasTray
  openWidth: row.implicitWidth

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
  property bool iconHovered: false
  property bool menuOpen: false
  property bool open: root.hasTray && (root.hovered || root.iconHovered || root.menuOpen)

  onHasTrayChanged: {
    if (!root.hasTray) {
      root.hovered = false;
      root.iconHovered = false;
      root.menuOpen = false;
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    onEntered: root.hovered = true
    onExited: root.hovered = false
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter

    BarText {
      text: " \uf08b "
      color: Zenon.cyan
    }

    Row {
      id: drawer
      clip: true
      anchors.verticalCenter: parent.verticalCenter
      width: root.open ? implicitWidth : 0
      opacity: root.open ? 1 : 0
      spacing: 12

      Behavior on width {
        NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease }
      }
      Behavior on opacity {
        NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease }
      }

      Repeater {
        model: root.trayItems

        delegate: Item {
          id: trayItem
          required property var modelData

          width: 14
          height: 14
          anchors.verticalCenter: parent.verticalCenter

          IconImage {
            anchors.fill: parent
            source: modelData.icon
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
            onEntered: root.iconHovered = true
            onExited: root.iconHovered = false
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
