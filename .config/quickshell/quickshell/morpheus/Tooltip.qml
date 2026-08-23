// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import "."
import "helpers.js" as Helpers

PanelWindow {
  id: popup

  required property Item anchorItem
  required property string text
  // the hovering MouseArea; the tooltip rides its pointer. Without one it
  // falls back to sitting centered over the anchor item.
  property MouseArea cursorArea: null
  property bool show: false
  property bool styled: false
  // pointer clearance: how far the tooltip's bottom edge sits above the cursor
  property int gap: 5
  property var history: []
  property color historyLineColor: Zenon.cyan
  property color historyFillColor: Zenon.cyan

  readonly property var _win: anchorItem ? anchorItem.QsWindow.window : null
  readonly property var barWin: _win

  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  aboveWindows: true
  screen: _win?.screen ?? null

  mask: Region {}

  implicitWidth: background.implicitWidth
  implicitHeight: background.implicitHeight

  anchors { top: true; left: true }

  // fade instead of popping; the window has to outlive the fade, so
  // visibility follows the factor rather than `show` directly
  property real showFactor: (popup.show && popup._win !== null) ? 1 : 0
  Behavior on showFactor {
    NumberAnimation { duration: Zenon.fast; easing.type: Easing.OutCubic }
  }
  visible: popup.showFactor > 0.01

  // The bar is its own layer-shell surface inset from the screen edges, so
  // item coordinates are window-relative. Its margins convert them back to
  // screen space — without that every tooltip lands one side-margin too far
  // left.
  readonly property real winOriginX: popup.barWin ? popup.barWin.margins.left : 0
  readonly property real winOriginY: !popup.barWin || !popup.screen ? 0
    : popup.screen.height - popup.barWin.margins.bottom - popup.barWin.height

  // pointer in screen coordinates, falling back to the anchor item's top centre
  readonly property point hotspot: {
    if (!popup.barWin || !popup.anchorItem) return Qt.point(0, 0);
    const src = popup.cursorArea ? popup.cursorArea : popup.anchorItem;
    const lx = popup.cursorArea ? popup.cursorArea.mouseX : popup.anchorItem.width / 2;
    const ly = popup.cursorArea ? popup.cursorArea.mouseY : 0;
    const p = popup.barWin.contentItem.mapFromItem(src, lx, ly);
    return Qt.point(popup.winOriginX + p.x, popup.winOriginY + p.y);
  }

  // bottom centre pinned to the pointer, clamped so it never leaves the screen
  margins.left: !popup.barWin || !popup.screen ? 0 :
    Math.round(Math.max(0, Math.min(popup.hotspot.x - popup.implicitWidth / 2,
      popup.screen.width - popup.implicitWidth)))
  margins.top: !popup.barWin || !popup.screen ? 0 :
    Math.round(Math.max(0, Math.min(popup.hotspot.y - popup.gap - popup.implicitHeight,
      popup.screen.height - popup.implicitHeight)))

  Rectangle {
    id: background
    implicitWidth: layout.width
    implicitHeight: layout.height
    opacity: popup.showFactor
    color: Zenon.panelBg
    border.color: Zenon.surface
    border.width: 1
    radius: 6

    Column {
      id: layout
      width: Math.max(content.implicitWidth, spark.visible ? spark.width + 40 : content.implicitWidth)
      height: content.implicitHeight + (spark.visible ? spark.height + 10 + 6 : 0)
      spacing: 0

      Text {
        id: content
        width: parent.width
        leftPadding: 20
        rightPadding: 20
        topPadding: 10
        bottomPadding: spark.visible ? 6 : 10
        text: popup.styled ? Helpers.tooltip(popup.text) : popup.text
        textFormat: popup.styled ? Text.StyledText : Text.PlainText
        color: Zenon.white
        font.family: "JetBrainsMono Nerd Font Propo"
        font.weight: Font.Bold
        font.pixelSize: 16
        horizontalAlignment: Text.AlignLeft
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.NoWrap
      }

      Sparkline {
        id: spark
        visible: popup.history && popup.history.length >= 2
        width: Math.max(160, content.implicitWidth - 20)
        height: 32
        anchors.horizontalCenter: parent.horizontalCenter
        values: popup.history
        lineColor: popup.historyLineColor
        fillColor: popup.historyFillColor
        fillOpacity: 0.18
      }

      Item { width: 1; height: spark.visible ? 10 : 0 }
    }
  }
}
