// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import "."

Item {
  id: root
  implicitWidth: row.implicitWidth
  implicitHeight: Zenon.slot

  // Display only. The reading, its history and its ink all come from Sysmon,
  // which zeus reads too — so the meter here and the graph there cannot drift.
  readonly property int usage: Sysmon.cpuUsage
  readonly property string tooltipText: Sysmon.cpuTip
  readonly property var history: Sysmon.cpuHistory
  readonly property color accent: Sysmon.cpuInk

  // Clicking the meter reports the click and nothing else — what opens is
  // shell.qml's business, the same way the bell reports to howler and the
  // clock to chronos. It used to launch btop in a terminal, which is a second
  // process reading the same /proc this module already reads; zeus is that
  // reading, and it shares Sysmon with the meter so the two cannot disagree.
  signal activated()

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    Meter {
      anchors.verticalCenter: parent.verticalCenter
      value: root.usage / 100
      accent: root.accent
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    onClicked: root.activated()
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    text: root.tooltipText
    styled: true
    show: mouse.containsMouse && root.tooltipText !== ""
    series: [{ values: root.history, line: root.accent }]
  }

}
