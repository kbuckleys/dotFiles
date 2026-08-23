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

  property string iface: ""
  property string ipaddr: ""
  property bool connected: false
  property string downText: "0.0B/s"
  property string upText: "0.0B/s"
  property real downVal: 0            // smoothed bytes/sec
  property real upVal: 0              // smoothed bytes/sec
  property var sample: null

  // exponential smoothing: 4Hz sampling without twitchy segments
  function smoothed(oldV, newV) {
    if (oldV <= 0) return newV;
    return oldV * 0.6 + newV * 0.4;
  }

  // full-scale at ~20MB/s, log-scaled below that
  function barLevel(bytes) {
    const max = 20 * 1024 * 1024;
    if (bytes <= 1) return 0;
    const frac = Math.log10(1 + bytes) / Math.log10(1 + max);
    return Math.max(0, Math.min(1, frac)) * 100;
  }
  readonly property real downLevel: root.connected ? barLevel(root.downVal) : 0
  readonly property real upLevel: root.connected ? barLevel(root.upVal) : 0

  // segmented meter: how many of the 6 notches are lit
  readonly property int segCount: 6
  function litSegs(level) {
    if (level <= 2) return 0;
    return Math.max(1, Math.min(root.segCount,
      Math.round(level / 100 * root.segCount)));
  }
  readonly property int downSegs: litSegs(root.downLevel)
  readonly property int upSegs: litSegs(root.upLevel)

  onIfaceChanged: {
    root.sample = null;
    root.downText = "0.0B/s";
    root.upText = "0.0B/s";
    root.downVal = 0;
    root.upVal = 0;
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    // segmented stereo meter: blue download · magenta upload
    Item {
      width: 13                    // 4px bar + 5px notch gap + 4px bar
      height: root.segCount * 3 - 1   // 2px segments, 1px gaps → 17px
      anchors.verticalCenter: parent.verticalCenter
      visible: root.connected

      // download (blue)
      Column {
        x: 0
        anchors.bottom: parent.bottom
        spacing: 1
        Repeater {
          model: root.segCount
          Rectangle {
            required property int index
            width: 4
            height: 2
            radius: 1
            color: root.segCount - 1 - index < root.downSegs ? Zenon.blue : Zenon.trough(Zenon.blue)
            Behavior on color { ColorAnimation { duration: Zenon.fast } }
          }
        }
      }

      // upload (magenta)
      Column {
        x: parent.width - 4
        anchors.bottom: parent.bottom
        spacing: 1
        Repeater {
          model: root.segCount
          Rectangle {
            required property int index
            width: 4
            height: 2
            radius: 1
            color: root.segCount - 1 - index < root.upSegs ? Zenon.magenta : Zenon.trough(Zenon.magenta)
            Behavior on color { ColorAnimation { duration: Zenon.fast } }
          }
        }
      }
    }

    BarText {
      visible: !root.connected
      src: "󰱟 "
      styled: true
      textColor: Zenon.red
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: Quickshell.execDetached(["kitty", "-1", "-T", "bandwhich", "sudo", "bandwhich"])
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    text: {
      if (!root.connected) return "NO NETWORK SIGNAL";
      const speeds = "󱞡 " + root.downText + " ~ " + root.upText + " 󱞿";
      return root.iface !== "" ? speeds + "\n" + root.iface + ": " + root.ipaddr : speeds;
    }
    show: mouse.containsMouse
  }

  Timer {
    id: infoTimer
    interval: 3000
    running: true
    repeat: true
    onTriggered: {
      if (!infoProc.running) infoProc.running = true;
    }
  }

  Process {
    id: infoProc
    command: ["sh", Helpers.script("netinfo.sh")]
    stdout: SplitParser {
      onRead: (line) => {
        const parts = line.split("|");
        if (parts.length === 3) {
          root.iface = parts[0];
          root.ipaddr = parts[1];
          root.connected = parts[0] !== "" && parts[2].trim() === "1";
        }
      }
    }
  }

  Process {
    id: devProc
    command: ["sh", "-c", "while true; do cat /proc/net/dev; echo __END__; sleep 0.25; done"]
    running: true
    stdout: SplitParser {
      onRead: (line) => root.devLine(line)
    }
  }

  property var devLines: []

  function devLine(line) {
    if (line === "__END__") {
      root.finalizeSample();
      return;
    }
    root.devLines.push(line);
  }

  function finalizeSample() {
    let rx = 0;
    let tx = 0;
    for (const l of root.devLines) {
      const idx = l.indexOf(":");
      if (idx <= 0) continue;
      const name = l.slice(0, idx).trim();
      if (name === "lo") continue;
      if (root.iface !== "" && name !== root.iface) continue;
      const nums = l.slice(idx + 1).trim().split(/\s+/).map(Number);
      if (nums.length >= 16) {
        rx += nums[0];
        tx += nums[8];
      }
    }
    root.devLines = [];
    const now = Date.now();
    if (root.sample) {
      const elapsed = (now - root.sample.time) / 1000;
      if (elapsed > 0) {
        const down = Math.max(0, (rx - root.sample.rx) / elapsed);
        const up = Math.max(0, (tx - root.sample.tx) / elapsed);
        root.downVal = root.smoothed(root.downVal, down);
        root.upVal = root.smoothed(root.upVal, up);
        root.downText = Helpers.powFormat(root.downVal);
        root.upText = Helpers.powFormat(root.upVal);
      }
    }
    root.sample = { rx: rx, tx: tx, time: now };
  }

  Component.onCompleted: infoProc.running = true
}
