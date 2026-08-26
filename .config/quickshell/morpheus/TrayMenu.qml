// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Hyprland
import "."

// A PopupWindow here self-closed roughly 60ms after opening: `grabFocus: true`
// on an xdg popup parented to the bar never holds. It also meant the menu was
// not a layer surface, so hyprland's `layer_rule(namespace=".*", blur=true)`
// never matched it and it rendered unblurred next to the tooltips. Both go away
// as a PanelWindow dismissed by HyprlandFocusGrab — the same pattern every
// working overlay in this config already uses.
PanelWindow {
  id: root

  required property var menuHandle
  required property Item anchorItem
  property bool isSubMenu: false

  property var childMenu: null
  signal menuClosed

  color: "transparent"
  visible: false
  focusable: true
  aboveWindows: true
  exclusionMode: ExclusionMode.Ignore
  mask: Region { item: background }
  anchors { top: true; left: true }

  implicitWidth: 220
  implicitHeight: Math.min(720, content.implicitHeight + 12)

  readonly property var srcWin: root.anchorItem ? root.anchorItem.QsWindow.window : null
  screen: root.srcWin?.screen ?? null

  // The anchor item lives inside another layer surface — the bar for a root
  // menu, the parent menu for a submenu — so its coordinates are window-local.
  // Convert them to screen space via that window's own anchors and margins.
  readonly property point srcPos: {
    if (!root.srcWin || !root.anchorItem || !root.screen) return Qt.point(0, 0);
    const w = root.srcWin;
    const o = Zenon.winOrigin(w, root.screen);
    const p = w.contentItem.mapFromItem(root.anchorItem, 0, 0);
    return Qt.point(o.x + p.x, o.y + p.y);
  }

  // root menu opens upward off the bar; a submenu opens to the right of its row
  margins.left: !root.screen ? 0 : Math.round(Math.max(0, Math.min(
    root.srcPos.x + (root.isSubMenu ? root.anchorItem.width + 6 : 0),
    root.screen.width - root.implicitWidth)))
  margins.top: !root.screen ? 0 : Math.round(Math.max(0, Math.min(
    root.isSubMenu ? root.srcPos.y : root.srcPos.y - root.implicitHeight - 6,
    root.screen.height - root.implicitHeight)))

  // only the root menu owns the grab; it covers the whole open submenu chain
  readonly property var grabWindows: {
    const out = [root];
    let m = root.childMenu;
    while (m) { out.push(m); m = m.childMenu; }
    return out;
  }

  HyprlandFocusGrab {
    windows: root.grabWindows
    active: root.visible && !root.isSubMenu
    onCleared: root.closeMenu()
  }

  onVisibleChanged: {
    if (!root.visible) root.menuClosed();
  }

  QsMenuOpener {
    id: opener
    menu: root.menuHandle
  }

  Rectangle {
    id: background
    anchors.fill: parent
    color: Zenon.panelBg
    border.color: Zenon.surface
    border.width: 1
    radius: 6

    Column {
      id: content
      anchors.fill: parent
      anchors.margins: 4
      spacing: 2

      Repeater {
        id: repeater
        model: opener.children

        delegate: Item {
          id: entry
          required property var modelData

          width: content.width
          height: modelData.isSeparator ? 8 : Math.max(28, label.implicitHeight + 12)

          Rectangle {
            id: highlight
            anchors.fill: parent
            radius: 3
            color: hover.containsMouse && !modelData.isSeparator ? Zenon.hoverTint : "transparent"
            Behavior on color {
              ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
            }
          }

          Rectangle {
            id: separatorLine
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Zenon.surface
            visible: modelData.isSeparator
          }

          Item {
            id: row
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8

            Image {
              id: icon
              anchors.verticalCenter: parent.verticalCenter
              width: 16
              height: 16
              source: modelData.icon
              sourceSize.width: 16
              sourceSize.height: 16
              visible: modelData.icon !== ""
            }

            Text {
              id: label
              anchors.left: icon.visible ? icon.right : parent.left
              anchors.leftMargin: 8
              anchors.right: rightArea.left
              anchors.rightMargin: 8
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignHCenter
              text: modelData.text
              elide: Text.ElideRight
              color: modelData.enabled ? Zenon.white : Zenon.muted
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Medium
              font.pixelSize: 15
            }

            Item {
              id: rightArea
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: 16
              height: 16

              Text {
                id: check
                anchors.centerIn: parent
                visible: modelData.checkState === 2 && !modelData.hasChildren
                text: "✓"
                color: Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: Font.Medium
                font.pixelSize: 13
              }

              Text {
                id: arrow
                anchors.centerIn: parent
                visible: modelData.hasChildren
                text: "▶"
                color: Zenon.muted
                font.pixelSize: 10
              }
            }
          }

          MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            enabled: modelData.enabled && !modelData.isSeparator
            onEntered: {
              if (modelData.hasChildren) root.openChild(entry);
            }
            onClicked: (mouse) => {
              if (modelData.hasChildren) {
                root.openChild(entry);
                return;
              }
              modelData.triggered();
              root.closeMenu();
            }
          }
        }
      }
    }
  }

  function open() {
    root.visible = true;
  }

  function openChild(entry) {
    if (root.childMenu && root.childMenu.menuHandle === entry.modelData) return;
    if (root.childMenu) root.childMenu.closeMenu();
    const comp = Qt.createComponent("TrayMenu.qml");
    root.childMenu = comp.createObject(root, {
      menuHandle: entry.modelData,
      anchorItem: entry,
      isSubMenu: true
    });
    root.childMenu.open();
  }

  function closeMenu() {
    if (root.childMenu) {
      root.childMenu.closeMenu();
      root.childMenu.destroy();
      root.childMenu = null;
    }
    root.visible = false;
  }
}
