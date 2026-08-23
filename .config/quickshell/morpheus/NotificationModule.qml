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

Item {
  id: root
  implicitWidth: row.implicitWidth
  implicitHeight: 32

  // arrived since the history panel was last opened
  property int unread: 0
  // everything the panel would show
  property int total: 0
  property string tooltipText: ""

  signal activated()
  signal cleared()

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule
    spacing: 4

    BarText {
      // a struck-through bell once there is nothing waiting, so the module
      // reads as "quiet" rather than just dim
      text: root.unread > 0 ? "\uF0F3" : "\uF1F6"
      color: root.unread > 0 ? Zenon.red : Zenon.muted
    }

    Collapsible {
      active: root.unread > 0
      openWidth: label.implicitWidth

      BarText {
        id: label
        anchors.centerIn: parent
        text: String(root.unread)
        color: Zenon.red
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
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
    show: mouse.containsMouse && root.tooltipText !== ""
  }
}
