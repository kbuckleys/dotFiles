// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// SYSMON — every system reading this shell takes, in one place.
//
// It used to be four copies of the same shape: each bar module ran its own
// Timer, its own Process and its own thirty-sample pushHistory. That was
// tolerable while the bar was the only reader. Zeus wants the same five
// readings as graphs, and a second set of pollers would have meant cpu.sh
// running twice a second for two views that then disagreed about what the last
// minute looked like.
//
// So the polling and the history live here, and the modules and zeus are both
// pure display. One reading, one history, and the bar's meter and zeus' graph
// can never tell you two different things.
//
// The inks live here too, for the same reason: a reading's colour IS part of
// the reading in this shell — red is cpu wherever you see it.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "helpers.js" as Helpers
import "."

Singleton {
  id: root

  // Two minutes at 1Hz. The bar's tooltip sparklines only ever drew the last
  // thirty, and still do — a Sparkline trims to its own maxPoints — but zeus'
  // graphs are four times as wide and want the room.
  readonly property int span: 120

  function push(list, v) {
    const h = list.slice();
    h.push(Math.max(0, Math.min(100, v)));
    while (h.length > root.span) h.shift();
    return h;
  }

  // ── cpu ───────────────────────────────────────────────────────────────
  readonly property color cpuInk: Zenon.red
  property int cpuUsage: 0
  property string cpuTip: ""
  property var cpuHistory: []
  // null until the machine has answered, so a pane can tell "not known" from
  // "zero" and print a dash instead of a wrong number
  property var cpuFreq: null      // MHz
  property var cpuTemp: null      // °C
  property var cpuLoad: null      // 1-minute load average

  Process {
    id: cpuProc
    command: [Helpers.script("cpu.sh")]
    stdout: SplitParser {
      onRead: (line) => {
        try {
          const o = JSON.parse(line);
          root.cpuUsage = o.usage ?? 0;
          root.cpuTip = o.tooltip ?? "";
          root.cpuFreq = o.freq ?? null;
          root.cpuTemp = o.temp ?? null;
          root.cpuLoad = o.load ?? null;
          root.cpuHistory = root.push(root.cpuHistory, o.usage ?? 0);
        } catch (e) {}
      }
    }
  }

  // ── gpu ───────────────────────────────────────────────────────────────
  readonly property color gpuInk: Zenon.pink
  // a fact about the machine, not about the text: the bar's module hides on it
  property bool gpuPresent: false
  property int gpuUsage: 0
  property int gpuTemp: 0
  property string gpuTip: ""
  property var gpuHistory: []

  Process {
    id: gpuProc
    command: [Helpers.script("gpu.sh")]
    stdout: SplitParser {
      onRead: (line) => {
        try {
          const o = JSON.parse(line);
          root.gpuPresent = o.present ?? false;
          root.gpuUsage = o.util ?? 0;
          root.gpuTemp = o.temp ?? 0;
          root.gpuTip = o.tooltip ?? "";
          root.gpuHistory = root.push(root.gpuHistory, o.util ?? 0);
        } catch (e) {}
      }
    }
  }

  // ── memory ────────────────────────────────────────────────────────────
  readonly property color memInk: Zenon.sand
  property real memTotal: 0        // KiB, as /proc/meminfo reports it
  property real memAvail: 0
  property real swapTotal: 0
  property real swapFree: 0
  property int memUsage: 0
  property string memTip: ""
  property var memHistory: []

  readonly property real memUsed: Helpers.giB(root.memTotal - root.memAvail)
  readonly property real swapUsed: Helpers.giB(root.swapTotal - root.swapFree)

  Process {
    id: memProc
    command: ["cat", "/proc/meminfo"]
    stdout: SplitParser {
      onRead: (line) => root.parseMem(line)
    }
  }

  // /proc/meminfo arrives a line at a time and the four fields that matter are
  // in a fixed order, so SwapFree — the last of them — is where the reading is
  // complete enough to publish.
  function parseMem(line) {
    if (line.startsWith("MemTotal:")) root.memTotal = parseInt(line.split(/\s+/)[1], 10) || 0;
    else if (line.startsWith("MemAvailable:")) root.memAvail = parseInt(line.split(/\s+/)[1], 10) || 0;
    else if (line.startsWith("SwapTotal:")) root.swapTotal = parseInt(line.split(/\s+/)[1], 10) || 0;
    else if (line.startsWith("SwapFree:")) {
      root.swapFree = parseInt(line.split(/\s+/)[1], 10) || 0;
      root.memTip =
          "RAM Total: " + Helpers.format1f(Helpers.giB(root.memTotal)) + "GiB\n" +
          "RAM Used: " + Helpers.format1f(root.memUsed) + "GiB\n" +
          "RAM Available: " + Helpers.format1f(Helpers.giB(root.memAvail)) + "GiB\n\n" +
          "SWAP Total: " + Helpers.format1f(Helpers.giB(root.swapTotal)) + "GiB\n" +
          "SWAP Used: " + Helpers.format1f(root.swapUsed) + "GiB\n" +
          "SWAP Available: " + Helpers.format1f(Helpers.giB(root.swapFree)) + "GiB";
      const pct = root.memTotal > 0
        ? Math.round((root.memTotal - root.memAvail) / root.memTotal * 100) : 0;
      root.memUsage = pct;
      root.memHistory = root.push(root.memHistory, pct);
    }
  }

  // ── disk ──────────────────────────────────────────────────────────────
  // Two inks, like the network's, because it is the same kind of reading: two
  // directions through one pipe.
  readonly property color diskReadInk: Zenon.cyan
  readonly property color diskWriteInk: Zenon.green
  property real diskRead: 0        // bytes/sec
  property real diskWrite: 0
  property int diskUsedPct: 0
  property real diskTotal: 0       // bytes
  property real diskUsedBytes: 0
  property string diskTip: ""
  property var diskReadHistory: []
  property var diskWriteHistory: []

  readonly property string diskReadText: Helpers.powFormat(root.diskRead)
  readonly property string diskWriteText: Helpers.powFormat(root.diskWrite)

  Process {
    id: diskProc
    command: [Helpers.script("disk.sh")]
    stdout: SplitParser {
      onRead: (line) => {
        try {
          const o = JSON.parse(line);
          root.diskRead = o.read ?? 0;
          root.diskWrite = o.write ?? 0;
          root.diskUsedPct = o.used ?? 0;
          root.diskTotal = o.total ?? 0;
          root.diskUsedBytes = o.usedBytes ?? 0;
          root.diskTip = o.tooltip ?? "";
          // Scaled the same way the network's throughput is, and against the
          // same kind of learned ceiling: an NVMe and a spinning disk are two
          // orders of magnitude apart and no fixed full-scale figure is right
          // for both.
          root.diskReadCeil = Math.max(root.diskRead, root.minDiskCeil,
            root.diskReadCeil * root.slowDecay);
          root.diskWriteCeil = Math.max(root.diskWrite, root.minDiskCeil,
            root.diskWriteCeil * root.slowDecay);
          root.diskReadHistory = root.push(root.diskReadHistory,
            root.logLevel(root.diskRead, root.diskReadCeil));
          root.diskWriteHistory = root.push(root.diskWriteHistory,
            root.logLevel(root.diskWrite, root.diskWriteCeil));
        } catch (e) {}
      }
    }
  }

  readonly property real minDiskCeil: 32 * 1024 * 1024
  // per 1s sample — about a three minute half-life, same feel as the network's
  readonly property real slowDecay: 0.996
  property real diskReadCeil: root.minDiskCeil
  property real diskWriteCeil: root.minDiskCeil

  // ── network ───────────────────────────────────────────────────────────
  readonly property color netDownInk: Zenon.blue
  readonly property color netUpInk: Zenon.magenta

  property string netIface: ""
  property string netIp: ""
  property bool netConnected: false
  property real netDown: 0            // smoothed bytes/sec
  property real netUp: 0
  property string netDownText: "0.0B/s"
  property string netUpText: "0.0B/s"
  property var netDownHistory: []
  property var netUpHistory: []
  property var netSample: null

  // exponential smoothing: 4Hz sampling without twitchy segments
  function smoothed(oldV, newV) {
    if (oldV <= 0) return newV;
    return oldV * 0.6 + newV * 0.4;
  }

  // Log-scaled between a floor and a ceiling, rather than from zero.
  //
  // Dividing log10(1 + bytes) by log10(1 + max) puts idle traffic most of the
  // way up: 36 kB/s — a page loading in the background — measured 62/100, so
  // the top two notches were the only ones that ever moved and the meter looked
  // permanently near full without ever reaching it. Normalising the log over
  // floor..max instead spends the range where the traffic actually is.
  //
  // The ceiling is LEARNED, not guessed. Any fixed full-scale figure is a guess
  // about someone else's line: measured on this one the uplink peaks at
  // 0.74 MB/s, so even a 4MB/s ceiling put a saturated upload at five notches
  // and made the sixth unreachable by construction. Tracking the fastest rate
  // actually seen means "all six lit" reads as "as fast as this link goes" —
  // correct on a 6 Mbit uplink and on a gigabit one, with nothing to retune.
  //
  // The peak decays slowly, so one big transfer does not desensitise the meter
  // for the rest of the session; the floor stops an idle trickle from looking
  // like saturation just because nothing faster has happened yet.
  readonly property real barFloor: 1024
  readonly property real minDownCeil: 2 * 1024 * 1024
  readonly property real minUpCeil: 512 * 1024
  // per 250ms sample — a half-life of about three minutes
  readonly property real peakDecay: 0.999
  property real downCeil: root.minDownCeil
  property real upCeil: root.minUpCeil

  function logLevel(bytes, ceil) {
    if (bytes <= root.barFloor) return 0;
    const frac = Math.log10(bytes / root.barFloor)
      / Math.log10(ceil / root.barFloor);
    return Math.max(0, Math.min(1, frac)) * 100;
  }

  readonly property real netDownLevel:
    root.netConnected ? root.logLevel(root.netDown, root.downCeil) : 0
  readonly property real netUpLevel:
    root.netConnected ? root.logLevel(root.netUp, root.upCeil) : 0

  onNetIfaceChanged: {
    root.netSample = null;
    root.netDownText = "0.0B/s";
    root.netUpText = "0.0B/s";
    root.netDown = 0;
    root.netUp = 0;
  }

  Process {
    id: netInfoProc
    command: ["sh", Helpers.script("netinfo.sh")]
    stdout: SplitParser {
      onRead: (line) => {
        const parts = line.split("|");
        if (parts.length === 3) {
          root.netIface = parts[0];
          root.netIp = parts[1];
          root.netConnected = parts[0] !== "" && parts[2].trim() === "1";
        }
      }
    }
  }

  // The one poller that is a long-running loop rather than a one-shot: at 4Hz
  // the cost of spawning a shell per sample is more than the sample.
  Process {
    id: netDevProc
    command: ["sh", "-c",
      "while true; do cat /proc/net/dev; echo __END__; sleep 0.25; done"]
    running: true
    stdout: SplitParser {
      onRead: (line) => root.netDevLine(line)
    }
  }

  property var netDevLines: []

  function netDevLine(line) {
    if (line === "__END__") {
      root.finalizeNetSample();
      return;
    }
    root.netDevLines.push(line);
  }

  function finalizeNetSample() {
    let rx = 0;
    let tx = 0;
    for (const l of root.netDevLines) {
      const idx = l.indexOf(":");
      if (idx <= 0) continue;
      const name = l.slice(0, idx).trim();
      if (name === "lo") continue;
      if (root.netIface !== "" && name !== root.netIface) continue;
      const nums = l.slice(idx + 1).trim().split(/\s+/).map(Number);
      if (nums.length >= 16) {
        rx += nums[0];
        tx += nums[8];
      }
    }
    root.netDevLines = [];
    const now = Date.now();
    if (root.netSample) {
      const elapsed = (now - root.netSample.time) / 1000;
      if (elapsed > 0) {
        const down = Math.max(0, (rx - root.netSample.rx) / elapsed);
        const up = Math.max(0, (tx - root.netSample.tx) / elapsed);
        root.netDown = root.smoothed(root.netDown, down);
        root.netUp = root.smoothed(root.netUp, up);
        // the high-water mark each meter is scaled against
        root.downCeil = Math.max(root.netDown, root.minDownCeil,
          root.downCeil * root.peakDecay);
        root.upCeil = Math.max(root.netUp, root.minUpCeil,
          root.upCeil * root.peakDecay);
        root.netDownText = Helpers.powFormat(root.netDown);
        root.netUpText = Helpers.powFormat(root.netUp);
        root.netDownHistory = root.push(root.netDownHistory, root.netDownLevel);
        root.netUpHistory = root.push(root.netUpHistory, root.netUpLevel);
      }
    }
    root.netSample = { rx: rx, tx: tx, time: now };
  }

  // ── the tick ──────────────────────────────────────────────────────────
  // One timer for the four one-shot pollers rather than four of them on their
  // own phase. `if (!running)` on each: a poller that is somehow taking longer
  // than a second must not be asked again on top of itself.
  Timer {
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      if (!cpuProc.running) cpuProc.running = true;
      if (!gpuProc.running) gpuProc.running = true;
      if (!memProc.running) memProc.running = true;
      if (!diskProc.running) diskProc.running = true;
    }
  }

  // the interface and address change far more rarely than the throughput does
  Timer {
    interval: 3000
    repeat: true
    running: true
    onTriggered: {
      if (!netInfoProc.running) netInfoProc.running = true;
    }
  }

  Component.onCompleted: {
    cpuProc.running = true;
    gpuProc.running = true;
    memProc.running = true;
    diskProc.running = true;
    netInfoProc.running = true;
  }
}
