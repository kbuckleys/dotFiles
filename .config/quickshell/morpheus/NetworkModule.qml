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

  // Log-scaled between a floor and a ceiling, rather than from zero.
  //
  // The old curve divided log10(1 + bytes) by log10(1 + max), which puts
  // idle traffic most of the way up the meter: 36 kB/s — a page loading in
  // the background — measured 62/100 and lit four of six notches, so the top
  // two were the only ones that ever moved and the meter looked stuck near
  // full while never quite reaching it.
  //
  // Normalising the log over floor..max instead spends the range where the
  // traffic actually is. Both numbers are here to be changed: raise `max` if
  // this link is faster than the meter suggests, lower it if the top notches
  // never light.
  // The ceiling is LEARNED, not guessed. Any fixed full-scale figure is a
  // guess about someone else's line: measured on this one, the uplink peaks
  // at 0.74 MB/s, so even a 4MB/s ceiling put a fully saturated upload at
  // five notches and made the sixth unreachable by construction. Tracking the
  // fastest rate actually seen means "all six lit" reads as "as fast as this
  // link goes" — correct on a 6 Mbit uplink and on a gigabit one, with
  // nothing to retune by hand.
  //
  // The peak decays slowly, so one big transfer does not desensitise the
  // meter for the rest of the session; the floors stop an idle trickle from
  // looking like saturation just because nothing faster has happened yet.
  readonly property real barFloor: 1024                     // below this is idle
  readonly property real minDownCeil: 2 * 1024 * 1024
  readonly property real minUpCeil: 512 * 1024
  // per 250ms sample — a half-life of about three minutes
  readonly property real peakDecay: 0.999
  property real downCeil: root.minDownCeil
  property real upCeil: root.minUpCeil

  function barLevel(bytes, ceil) {
    if (bytes <= root.barFloor) return 0;
    const frac = Math.log10(bytes / root.barFloor)
      / Math.log10(ceil / root.barFloor);
    return Math.max(0, Math.min(1, frac)) * 100;
  }
  readonly property real downLevel:
    root.connected ? barLevel(root.downVal, root.downCeil) : 0
  readonly property real upLevel:
    root.connected ? barLevel(root.upVal, root.upCeil) : 0

  readonly property int segCount: 6

  // The same 0..100 levels the meters read, kept as a short history so the
  // tooltip can plot them. Sparkline wants 0..100, which is what barLevel
  // already produces, so nothing has to be rescaled on the way in.
  property var downHistory: []
  property var upHistory: []

  function pushHistory(list, v) {
    const h = list.slice();
    h.push(Math.max(0, Math.min(100, v)));
    if (h.length > 30) h.shift();
    return h;
  }

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
      // read off the meters themselves rather than restated as a number, so
      // changing a meter's thickness cannot leave this behind
      width: down.width * 2 + 5
      height: down.implicitHeight
      anchors.verticalCenter: parent.verticalCenter
      visible: root.connected

      Meter {
        id: down
        x: 0
        segCount: root.segCount
        value: root.downLevel / 100
        accent: Zenon.blue
      }

      Meter {
        x: parent.width - width
        segCount: root.segCount
        value: root.upLevel / 100
        accent: Zenon.magenta
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
    onClicked: Quickshell.execDetached(["xdg-terminal-exec", "--title=bandwhich", "-e", "sudo bandwhich"])
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    // Where you are, then how fast it is moving: the address is the stable
    // fact you came to read, the throughput is the number that never sits
    // still, and a heading that changes four times a second is a poor one.
    text: {
      if (!root.connected) return "NO NETWORK SIGNAL";
      const speeds = "󱞡 " + root.downText + " ~ " + root.upText + " 󱞿";
      return root.iface !== ""
        ? root.iface + ": " + root.ipaddr + "\n" + speeds
        : speeds;
    }
    // two short standalone lines, not a list — centred reads better
    align: Text.AlignHCenter
    show: mouse.containsMouse
    // one trace per channel, in the same two inks the meter beside it uses
    series: root.connected
      ? [{ values: root.downHistory, line: Zenon.blue },
         { values: root.upHistory,   line: Zenon.magenta }]
      : []
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
        // the high-water mark each meter is scaled against
        root.downCeil = Math.max(root.downVal, root.minDownCeil,
          root.downCeil * root.peakDecay);
        root.upCeil = Math.max(root.upVal, root.minUpCeil,
          root.upCeil * root.peakDecay);
        root.downText = Helpers.powFormat(root.downVal);
        root.upText = Helpers.powFormat(root.upVal);
        root.downHistory = root.pushHistory(root.downHistory, root.downLevel);
        root.upHistory = root.pushHistory(root.upHistory, root.upLevel);
      }
    }
    root.sample = { rx: rx, tx: tx, time: now };
  }

  Component.onCompleted: infoProc.running = true
}
