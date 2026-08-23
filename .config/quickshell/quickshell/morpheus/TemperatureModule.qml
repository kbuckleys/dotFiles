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

  property string tempPath: ""
  property int temp: 0

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    BarText {
      text: root.tempPath === "" ? "" : root.temp + "°"
      color: {
        if (root.temp >= 70) return Zenon.red;
        if (root.temp >= 50) return Zenon.sand;
        return Zenon.white;
      }
    }
  }

  Timer {
    id: refresh
    interval: 5000
    running: true
    repeat: true
    onTriggered: {
      if (root.tempPath !== "" && !proc.running) proc.running = true;
    }
  }

  Process {
    id: proc
    command: ["cat", root.tempPath]
    stdout: SplitParser {
      onRead: (line) => {
        const v = parseInt(line.trim(), 10);
        if (!isNaN(v)) root.temp = Math.floor(v / 1000);
      }
    }
  }

  Process {
    id: finder
    command: ["sh", "-c", "ls /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp2_input 2>/dev/null | head -n1"]
    stdout: SplitParser {
      onRead: (line) => {
        const p = line.trim();
        if (p !== "") {
          root.tempPath = p;
          proc.running = true;
        }
      }
    }
  }

  Component.onCompleted: finder.running = true
}
