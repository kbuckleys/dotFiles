// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// Base for every popout that hangs off a bar module: tooltips and the
// calendar. It owns one thing — where the window lands — so the two cannot
// drift apart the way they had. Derived components supply only their own
// content and its implicit size.

import QtQuick
import Quickshell
import "."

PanelWindow {
  id: anchorRoot

  // the bar item this popout belongs to; its window is the coordinate system
  // everything below converts out of
  required property Item anchorItem
  // the hovering MouseArea; the popout rides its pointer. Without one it
  // falls back to sitting centred over the anchor item.
  property MouseArea cursorArea: null
  property bool show: false
  // pointer clearance: how far the popout's bottom edge sits above the cursor
  property int gap: 5

  readonly property var srcWin: anchorRoot.anchorItem
    ? anchorRoot.anchorItem.QsWindow.window : null

  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  aboveWindows: true
  screen: anchorRoot.srcWin?.screen ?? null

  mask: Region {}

  anchors { top: true; left: true }

  // fade instead of popping; the window has to outlive the fade, so
  // visibility follows the factor rather than `show` directly
  property real showFactor: (anchorRoot.show && anchorRoot.srcWin !== null) ? 1 : 0
  Behavior on showFactor {
    NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
  }
  visible: anchorRoot.showFactor > 0.01

  // Pointer in screen coordinates, falling back to the anchor item's top
  // centre. The bar is its own layer-shell surface inset from the screen
  // edges, so item coordinates are window-relative; Zenon.winOrigin converts
  // them back — without it every popout lands one side-margin too far left.
  readonly property point hotspot: {
    if (!anchorRoot.srcWin || !anchorRoot.anchorItem || !anchorRoot.screen)
      return Qt.point(0, 0);
    const src = anchorRoot.cursorArea ? anchorRoot.cursorArea : anchorRoot.anchorItem;
    const lx = anchorRoot.cursorArea ? anchorRoot.cursorArea.mouseX
                                     : anchorRoot.anchorItem.width / 2;
    const ly = anchorRoot.cursorArea ? anchorRoot.cursorArea.mouseY : 0;
    const o = Zenon.winOrigin(anchorRoot.srcWin, anchorRoot.screen);
    const p = anchorRoot.srcWin.contentItem.mapFromItem(src, lx, ly);
    return Qt.point(o.x + p.x, o.y + p.y);
  }

  // bottom centre pinned to the pointer, clamped so it never leaves the screen
  margins.left: !anchorRoot.srcWin || !anchorRoot.screen ? 0 :
    Math.round(Math.max(0, Math.min(anchorRoot.hotspot.x - anchorRoot.implicitWidth / 2,
      anchorRoot.screen.width - anchorRoot.implicitWidth)))
  margins.top: !anchorRoot.srcWin || !anchorRoot.screen ? 0 :
    Math.round(Math.max(0, Math.min(anchorRoot.hotspot.y - anchorRoot.gap - anchorRoot.implicitHeight,
      anchorRoot.screen.height - anchorRoot.implicitHeight)))
}
