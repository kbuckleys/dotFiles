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
  implicitHeight: Zenon.slot
  // `present` rather than a non-empty label: the module hides when there is no
  // GPU to report on, which is a fact about the machine, not about the text.
  visible: root.present

  property bool present: false
  property int temp: 0
  property string tooltipText: ""
  property int usage: 0
  property var history: []

  function pushHistory(v) {
    const h = root.history.slice();
    h.push(Math.max(0, Math.min(100, v)));
    if (h.length > 30) h.shift();
    root.history = h;
  }

  // One colour for this module: the meter in the bar and its trace in the
  // tooltip are the same reading, and they say so.
  readonly property color accent: Zenon.pink

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
    command: [Helpers.script("gpu.sh")]
    stdout: SplitParser {
      onRead: (line) => {
        try {
          const o = JSON.parse(line);
          root.present = o.present ?? false;
          root.temp = o.temp ?? 0;
          root.tooltipText = o.tooltip ?? "";
          root.usage = o.util ?? 0;
          root.pushHistory(o.util ?? 0);
        } catch (e) {}
      }
    }
  }

  Component.onCompleted: proc.running = true
}
