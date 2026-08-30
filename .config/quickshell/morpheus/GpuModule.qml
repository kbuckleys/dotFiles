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
  // `present` rather than a non-empty label: the module hides when there is no
  // GPU to report on, which is a fact about the machine, not about the text.
  visible: root.present

  // Display only — the reading and its history live in Sysmon.
  readonly property bool present: Sysmon.gpuPresent
  readonly property int temp: Sysmon.gpuTemp
  readonly property string tooltipText: Sysmon.gpuTip
  readonly property int usage: Sysmon.gpuUsage
  readonly property var history: Sysmon.gpuHistory
  readonly property color accent: Sysmon.gpuInk

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
