// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Io
import "helpers.js" as Helpers
import "."

Item {
  id: root
  implicitWidth: row.implicitWidth
  implicitHeight: 32

  property int usage: 0
  property string text: ""
  property string tooltipText: ""
  property var history: []

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
      id: label
      src: root.text
      styled: true
      color: {
        if (root.usage >= 90) return Zenon.red;
        if (root.usage >= 50) return Zenon.sand;
        return Zenon.white;
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: Quickshell.execDetached(["kitty", "-1", "-T", "sysmon", "btop"])
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    text: root.tooltipText
    styled: true
    show: mouse.containsMouse && root.tooltipText !== ""
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
    command: [Helpers.script("cpu.sh")]
    stdout: SplitParser {
      onRead: (line) => {
        try {
          const o = JSON.parse(line);
          root.usage = o.usage ?? 0;
          root.text = o.text ?? "";
          root.tooltipText = o.tooltip ?? "";
          root.pushHistory(o.usage ?? 0);
        } catch (e) {}
      }
    }
  }

  Component.onCompleted: proc.running = true
}
