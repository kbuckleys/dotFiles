// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import "helpers.js" as Helpers
import "."

Item {
  id: root
  implicitWidth: row.implicitWidth
  implicitHeight: 32

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    BarText {
      id: label
      text: Helpers.pad(clock.hours) + ":" + Helpers.pad(clock.minutes)
      color: Zenon.cyan
    }
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    enabled: true
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
  }

  CalendarPopup {
    anchorItem: root
    cursorArea: mouse
    show: mouse.containsMouse
  }
}
