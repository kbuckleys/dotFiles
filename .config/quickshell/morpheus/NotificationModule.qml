// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// The bell. Deliberately knows nothing about howler: shell.qml feeds it the
// numbers and handles the click, exactly like every other module here, so the
// bar and the notification daemon stay separable.

import QtQuick
import "."

Collapsible {
  id: root
  active: root.unread > 0
  openWidth: row.implicitWidth

  // arrived since the history panel was last opened
  property int unread: 0
  // everything the panel would show
  property int total: 0
  property string tooltipText: ""
  property bool hovered: false

  signal activated()
  signal cleared()

  Row {
    id: row
    anchors.centerIn: parent
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule
    spacing: 0

    Item {
      id: iconBox
      width: (root.hovered && root.unread > 0 ? countBox.implicitWidth : iconGlyph.implicitWidth) + Zenon.padModule * 2
      Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
      height: Zenon.slot
      anchors.verticalCenter: parent.verticalCenter

      BarText {
        id: iconGlyph
        anchors.centerIn: parent
        text: "󰂜"
        color: Zenon.yellow
        numeric: true
        font.pixelSize: Zenon.clockSize
        opacity: !root.hovered ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
      }

      Item {
        id: countBox
        anchors.centerIn: parent
        implicitWidth: Math.max(countGhost.implicitWidth, countLabel.implicitWidth)
        implicitHeight: Zenon.slot

        BarText {
          id: countGhost
          anchors.centerIn: parent
          text: "8".repeat(Math.max(1, String(root.unread).length))
          numeric: true
          color: Zenon.trough(Zenon.yellow)
          opacity: root.hovered && root.unread > 0 ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
        }

        BarText {
          id: countLabel
          anchors.centerIn: parent
          text: String(root.unread)
          numeric: true
          color: Zenon.yellow
          opacity: root.hovered && root.unread > 0 ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
        }
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onEntered: root.hovered = true
    onExited: root.hovered = false
    onClicked: (e) => {
      if (e.button === Qt.MiddleButton) root.cleared();
      else root.activated();
    }
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    styled: true
    text: root.tooltipText
    show: mouse.containsMouse && root.unread > 0 && root.tooltipText !== ""
  }
}
