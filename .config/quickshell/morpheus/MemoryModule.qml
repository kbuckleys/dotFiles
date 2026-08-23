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
  implicitHeight: 32

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

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    BarText {
      src: " <span foreground='" + Zenon.hex(Zenon.cyan) + "'>RAM</span> " + Helpers.format1f(root.used)
      styled: true
      color: Zenon.white
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
    history: root.history
    historyLineColor: {
      if (root.usage >= 90) return Zenon.red;
      if (root.usage >= 50) return Zenon.sand;
      return Zenon.cyan;
    }
    historyFillColor: {
      if (root.usage >= 90) return Zenon.red;
      if (root.usage >= 50) return Zenon.sand;
      return Zenon.cyan;
    }
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
