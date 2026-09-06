// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import "helpers.js" as Helpers
import "../chronos/chronos.js" as Chr
import "."

Item {
  id: root
  implicitWidth: row.implicitWidth
  implicitHeight: Zenon.slot

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    // The live digits sit on top of every segment lit and dimmed. DSEG has no
    // ghosting of its own — you get it by drawing "88:88" behind, which is
    // literally what the panel of a real clock is doing: the unlit segments
    // are still there, you can just about see them.
    Item {
      width: Math.max(ghost.implicitWidth, label.implicitWidth)
      height: Zenon.slot
      anchors.verticalCenter: parent.verticalCenter

      BarText {
        id: ghost
        anchors.centerIn: parent
        text: "88:88"
        numeric: true
        // the same ink an unlit meter notch uses: it is the same idea, an
        // element of the accent that is present but not lit
        color: Zenon.trough(Zenon.cyan)
      }

      BarText {
        id: label
        anchors.centerIn: parent
        text: Helpers.pad(clock.hours) + ":" + Helpers.pad(clock.minutes)
        numeric: true
        color: Zenon.cyan
      }
    }
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    enabled: true
  }

  // What today is, in one line. The month grid that used to hang off this
  // hover is a layer now — a calendar you can page through does not belong in
  // something that vanishes when the pointer moves.
  signal activated()

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    onClicked: root.activated()
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    text: Chr.oneLine(clock.date)
    align: Text.AlignHCenter
    show: mouse.containsMouse
  }
}
