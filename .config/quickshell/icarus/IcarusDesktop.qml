// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
// ICARUS desktop catcher — per-monitor Bottom layer that captures right-click
// on empty desktop. Mirrors PicassoDaemon Variants pattern.

import QtQuick
import Quickshell
import Quickshell.Wayland

Variants {
  id: root
  model: Quickshell.screens

  // reference to the popup that should be opened
  property var popup: null

  PanelWindow {
    id: surface
    required property var modelData

    screen: surface.modelData
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.namespace: "icarus-desktop"
    exclusionMode: ExclusionMode.Ignore
    anchors { left: true; right: true; top: true; bottom: true }
    color: "transparent"
    // take input everywhere; PicassoDaemon uses Region{} (click-through) —
    // this one must be the opposite so desktop clicks land here
    mask: Region { item: catcher }

    Item {
      id: catcher
      anchors.fill: parent

      MouseArea {
        id: mouse
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: (event) => {
          if (event.button !== Qt.RightButton) return;
          if (!root.popup) return;
          // Hyprland will have already focused this monitor on click;
          // the popup itself is pinned to root.focusedScreen per spec,
          // but we pass the clicked screen's point — the popup clamps
          // to its own screen's bounds (same coordinate space since
          // focusedScreen is the monitor that was just clicked)
          root.popup.openAt(Qt.point(mouse.mouseX, mouse.mouseY), surface.modelData);
        }
      }
    }
  }
}
