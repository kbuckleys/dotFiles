// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
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
    onClicked: Quickshell.execDetached(["xdg-terminal-exec", "--title=sysmon", "-e", "btop"])
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
