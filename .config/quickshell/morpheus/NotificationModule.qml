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
  implicitHeight: Zenon.slot

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
    // the segment digits sit tight against their own box, so the bell needs
    // more room beside them than it did against proportional type
    spacing: 8

    BarText {
      // Two states. A filled bell with a count while something is unread, and
      // an open one the rest of the time — whether the history is empty or
      // merely all read, the answer to "is anything waiting for me" is no,
      // and one icon says it. The struck-through bell that used to cover the
      // read-but-kept case read as "notifications are switched off".
      //
      // U+F009C as a literal character: it is above the BMP, and QML's string
      // lexer takes neither "\u{...}" (valid ES6, rejected here) nor a
      // four-digit escape that could reach it.
      text: root.unread > 0 ? "\uF0F3" : "󰂜"
      // the same orange waybar-updates rings in — one "this is the
      // notification module" colour, whether it is holding anything or not
      color: Zenon.yellow
    }

    Collapsible {
      active: root.unread > 0
      openWidth: label.implicitWidth

      BarText {
        id: label
        anchors.centerIn: parent
        text: String(root.unread)
        numeric: true
        color: Zenon.yellow
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
