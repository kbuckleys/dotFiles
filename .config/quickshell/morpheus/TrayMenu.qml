// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Widgets
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

  // autofit to content but cap to available screen space
  implicitWidth: 220 + Zenon.shadowPad * 2
  implicitHeight: {
    if (!root.screen) return 220 + Zenon.shadowPad * 2;
    const maxBgH = root.screen.height - Zenon.shadowPad * 2;
    return Math.min(content.implicitHeight + 12, maxBgH) + Zenon.shadowPad * 2;
  }

  // background position, window is background - pad (so shadow has room)
  readonly property int bgW: 220
  readonly property int bgH: {
    if (!root.screen) return Math.min(720, content.implicitHeight + 12);
    const maxBgH = root.screen.height - Zenon.shadowPad * 2;
    return Math.min(content.implicitHeight + 12, maxBgH);
  }
  // root menu opens upward if enough space below? Actually bar is at bottom, so upward is default.
  // submenu tries right, else left; both try to stay on screen vertically
  margins.left: {
    if (!root.screen) return 0;
    const pad = Zenon.shadowPad;
    if (root.isSubMenu) {
      const rightBgX = root.srcPos.x + root.anchorItem.width + 0;
      const leftBgX = root.srcPos.x - bgW - 0;
      let bgX;
      if (rightBgX + bgW <= root.screen.width - pad) bgX = rightBgX;
      else if (leftBgX >= pad) bgX = leftBgX;
      else bgX = Math.max(pad, Math.min(rightBgX, root.screen.width - bgW - pad));
      return Math.round(bgX - pad);
    } else {
      // root: try to keep left aligned, but if off-screen right, shift left
      const bgX = Math.max(pad, Math.min(root.srcPos.x, root.screen.width - bgW - pad));
      return Math.round(bgX - pad);
    }
  }
  margins.top: {
    if (!root.screen) return 0;
    const pad = Zenon.shadowPad;
    if (root.isSubMenu) {
      let bgY = root.srcPos.y;
      if (bgY + bgH > root.screen.height - pad) bgY = root.screen.height - bgH - pad;
      if (bgY < pad) bgY = pad;
      return Math.round(bgY - pad);
    } else {
      // root opens upward from bar
      let bgY = root.srcPos.y - bgH - 0;
      if (bgY < pad) {
        // not enough space above, try below (should not happen for bar at bottom, but handle)
        const belowY = root.srcPos.y + root.anchorItem.height + 0;
        if (belowY + bgH <= root.screen.height - pad) bgY = belowY;
        else bgY = Math.max(pad, root.screen.height - bgH - pad);
      }
      return Math.round(bgY - pad);
    }
  }

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

  LayerShadow {
    panel: background
    cornerRadius: 6
    morphed: false
  }

  ClippingRectangle {
    id: background
    anchors.fill: parent
    anchors.margins: Zenon.shadowPad
    color: Zenon.panelBg
    border.color: Zenon.surface
    border.width: 1
    radius: 6
    topLeftRadius: isSubMenu ? 0 : 6
    topRightRadius: childMenu ? 0 : 6
    bottomLeftRadius: isSubMenu ? 0 : 6
    bottomRightRadius: childMenu ? 0 : 6

    Column {
      id: content
      anchors.fill: parent
      anchors.margins: 4
      spacing: 1

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
            radius: 0
            color: hover.containsMouse && !modelData.isSeparator ? Zenon.headBg : "transparent"
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
                text: ""
                color: Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 13
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
