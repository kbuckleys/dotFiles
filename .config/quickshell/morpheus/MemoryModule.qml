// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell.Io
import "helpers.js" as Helpers
import "."

Item {
  id: root
  implicitWidth: row.implicitWidth
  implicitHeight: Zenon.slot

  property real total: 0
  property real avail: 0
  property real swapTotal: 0
  property real swapFree: 0
  property string tooltipText: ""
  property var history: []
  property int usage: 0

  function pushHistory(v) {
    const h = root.history.slice();
    h.push(Math.max(0, Math.min(100, v)));
    if (h.length > 30) h.shift();
    root.history = h;
  }

  // One colour for this module: the meter in the bar and its trace in the
  // tooltip are the same reading, and they say so.
  readonly property color accent: Zenon.sand

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

  property real used: Helpers.giB(root.total - root.avail)
  property real swapUsed: Helpers.giB(root.swapTotal - root.swapFree)

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    text: root.tooltipText
    show: mouse.containsMouse && root.total > 0
    series: [{ values: root.history, line: root.accent }]
  }

  Timer {
    id: refresh
    interval: 1000
    running: true
    repeat: true
    onTriggered: {
      if (!proc.running) proc.running = true;
    }
  }

  Process {
    id: proc
    command: ["cat", "/proc/meminfo"]
    stdout: SplitParser {
      onRead: (line) => root.parseMem(line)
    }
  }

  Component.onCompleted: proc.running = true

  function parseMem(line) {
    if (line.startsWith("MemTotal:")) root.total = parseInt(line.split(/\s+/)[1], 10) || 0;
    else if (line.startsWith("MemAvailable:")) root.avail = parseInt(line.split(/\s+/)[1], 10) || 0;
    else if (line.startsWith("SwapTotal:")) root.swapTotal = parseInt(line.split(/\s+/)[1], 10) || 0;
    else if (line.startsWith("SwapFree:")) {
      root.swapFree = parseInt(line.split(/\s+/)[1], 10) || 0;
      root.tooltipText =
          "RAM Total: " + Helpers.format1f(Helpers.giB(root.total)) + "GiB\n" +
          "RAM Used: " + Helpers.format1f(root.used) + "GiB\n" +
          "RAM Available: " + Helpers.format1f(Helpers.giB(root.avail)) + "GiB\n\n" +
          "SWAP Total: " + Helpers.format1f(Helpers.giB(root.swapTotal)) + "GiB\n" +
          "SWAP Used: " + Helpers.format1f(root.swapUsed) + "GiB\n" +
          "SWAP Available: " + Helpers.format1f(Helpers.giB(root.swapFree)) + "GiB";
      const pct = root.total > 0 ? Math.round((root.total - root.avail) / root.total * 100) : 0;
      root.usage = pct;
      root.pushHistory(pct);
    }
  }
}
