// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Io
import "helpers.js" as Helpers
import "."

Collapsible {
  id: root
  // collapses to zero width whenever there is nothing pending
  active: root.hasUpdates
  openWidth: row.implicitWidth

  property bool hasUpdates: false
  property string countText: ""
  property string tooltipText: ""

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    BarText {
      id: label
      text: " " + root.countText
      color: Zenon.yellow
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: Quickshell.execDetached([
      "kitty", "-1", "-T", "ZENU", Helpers.home() + "/.config/scripts/ZENU.lua", "update"
    ])
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    text: root.tooltipText
    show: mouse.containsMouse && root.tooltipText !== ""
  }

  Timer {
    id: updateTimer
    interval: 3600000
    onTriggered: {
      if (!proc.running) proc.running = true;
    }
  }

  Process {
    id: proc
    command: ["waybar-updates", "-d", "-n", "-c", "3600"]
    stdout: SplitParser {
      onRead: (line) => {
        try {
          const o = JSON.parse(line);
          root.hasUpdates = o.alt === "pending-updates";
          root.countText = o.text ?? "";
          root.tooltipText = o.tooltip ?? "";
        } catch (e) {}
      }
    }
    onRunningChanged: (running) => {
      if (running) updateTimer.stop();
      else updateTimer.start();
    }
  }

  Component.onCompleted: proc.running = true
}
