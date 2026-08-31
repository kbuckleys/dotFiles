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

  // Display only — /proc/meminfo is read once, in Sysmon.
  readonly property real total: Sysmon.memTotal
  readonly property real avail: Sysmon.memAvail
  readonly property string tooltipText: Sysmon.memTip
  readonly property var history: Sysmon.memHistory
  readonly property int usage: Sysmon.memUsage
  readonly property color accent: Sysmon.memInk

  // Clicking the meter reports the click and nothing else — what opens is
  // shell.qml's business, the same way the bell reports to howler and the
  // clock to chronos.
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
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    text: root.tooltipText
    show: mouse.containsMouse && root.total > 0
    series: [{ values: root.history, line: root.accent }]
  }

}
