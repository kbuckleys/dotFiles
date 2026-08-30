// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "zeus.js" as Zeus
import "../morpheus"
import "../morpheus/helpers.js" as Helpers

PanelWindow {
  id: popup

  WlrLayershell.layer: WlrLayer.Overlay

  property bool shown: false
  property bool morphMode: false
  // 0..1, driven by shell.qml, which owns the crossfade schedule: 0 until the
  // pill's own row has finished clearing, then rising to 1 as the pill
  // finishes taking this layer's shape
  property real morphFade: 1
  property real showFactor: 0
  property bool collapsing: false
  // Morphed, the panel IS the pill: derive the scale from the pill's own live
  // animated size so the two are locked frame-for-frame, instead of each
  // running its own entrance animation against the other. Standalone there is
  // no pill to carry the motion, so the scale-up entrance stays.
  readonly property real morphScaleX: (popup.morphMode && popup.statusbar && panel.width > 0)
    ? popup.statusbar.width / panel.width : 1
  readonly property real morphScaleY: (popup.morphMode && popup.statusbar && panel.height > 0)
    ? popup.statusbar.height / panel.height : 1
  readonly property real panelX: popup.morphMode ? popup.morphScaleX
    : (popup.collapsing ? 0.985 + 0.015 * popup.showFactor
                        : 0.94 + 0.06 * popup.showFactor)
  readonly property real panelY: popup.morphMode ? popup.morphScaleY
    : (popup.collapsing ? 0.82 + 0.18 * popup.showFactor
                        : 0.90 + 0.10 * popup.showFactor)
  // Morphed, the handover is timed off the PILL's progress, not this popup's
  // own showFactor: showFactor is OutCubic and front-loaded, so it crossed the
  // threshold ~25ms in and this layer's content faded up on top of a morpheus
  // row that was still 80% opaque.
  // Math.min, not morphFade alone. Handing the pill straight to another
  // layer leaves morphFade pinned at 1 — the pill never un-morphs, so there
  // is nothing to ease it down — and this layer stayed fully opaque until its
  // window simply blinked out. Its own closeAnim is already easing
  // showFactor to 0, so taking the lower of the two fades it out on the way
  // between layers while leaving the normal open schedule untouched.
  readonly property real contentFade: popup.morphMode
    ? Math.min(popup.morphFade, popup.showFactor) : popup.showFactor

  property var statusbar: null

  readonly property color bgColor: "#cc000000"
  readonly property color borderColor: "#20242a"
  readonly property color fgColor: "#DFDFDD"
  readonly property color headColor: "#9bbfbf"
  readonly property color keyColor: "#a2a8bc"
  readonly property color dimColor: "#6a707f"
  readonly property color entryColor: "#eebebe"
  readonly property color errColor: "#e78284"
  readonly property color selColor: "#4d45505c"

  // mode: graphs · list · confirm · error — one seamless surface, no separate
  // menus. Graphs is what opens: most of the time the question is "what is this
  // machine doing", and only sometimes "what do I have to kill". Tab is the way
  // between the two.
  property string mode: "graphs"

  function setMode(m) {
    if (popup.mode === m) return;
    popup.mode = m;
    // the list is only worth refreshing while it is the thing on screen
    if (m === "list") popup.loadProcs();
    popup.syncFocus();
  }

  function toggleView() {
    popup.setMode(popup.mode === "graphs" ? "list" : "graphs");
  }

  // ── the graphs ────────────────────────────────────────────────────────
  // Every reading comes from Sysmon, which is the same source the bar's meters
  // read — so a spike here is the same spike the pill just showed, not a second
  // measurement of it taken half a second later.
  readonly property int graphRowH: 76
  readonly property int headerH: 44
  // The footer is the hints and nothing else now, so it is sized for one row
  // instead of two — 58px of strip under a 28px row read as a mistake.
  readonly property int hintH: 40

  // What the machine is, in one line. Both views show it, so it is written
  // once: in the graphs' header beside the title, and in the kill list's input
  // bar on the right.
  readonly property string statusLine:
    popup.rows.length + " processes · up " + popup.uptime

  // A CONSTANT list of keys, and the live numbers fetched per key beside it.
  //
  // The first pass built one big array of {label, ink, value, series, facts} and
  // handed it straight to a Repeater. That array is rebuilt every time any
  // Sysmon property changes — four times a second, because the network samples
  // at 4Hz — and a Repeater handed a new model DESTROYS AND RECREATES every
  // delegate. Five rows and seven Canvases were being torn down and rebuilt
  // continuously, which is what made the traces flicker. Tooltip.qml already
  // carries this scar; this is the same one.
  //
  // Modelled on keys that never change, the delegates are created once and only
  // their leaf bindings update.
  readonly property var statKeys: ["cpu", "gpu", "ram", "net", "disk"]

  function statLabel(key) {
    return { cpu: "CPU", gpu: "GPU", ram: "RAM", net: "NET", disk: "DISK" }[key] ?? key;
  }

  function statInk(key) {
    if (key === "cpu") return Sysmon.cpuInk;
    if (key === "gpu") return Sysmon.gpuInk;
    if (key === "ram") return Sysmon.memInk;
    if (key === "net") return Sysmon.netDownInk;
    return Sysmon.diskReadInk;
  }

  // the big reading, split so the digits can be set in the segment face and the
  // unit beside them in the text face
  function statValue(key) {
    if (key === "cpu") return String(Sysmon.cpuUsage);
    if (key === "gpu") return Sysmon.gpuPresent ? String(Sysmon.gpuUsage) : "--";
    if (key === "ram") return String(Sysmon.memUsage);
    if (key === "net") return Helpers.splitRate(Sysmon.netDownText).num;
    return Helpers.splitRate(Sysmon.diskReadText).num;
  }

  function statUnit(key) {
    if (key === "net") return Helpers.splitRate(Sysmon.netDownText).unit;
    if (key === "disk") return Helpers.splitRate(Sysmon.diskReadText).unit;
    return "%";
  }

  // the first channel every reading has, and the second that only the two
  // two-directional ones do
  function statValuesA(key) {
    if (key === "cpu") return Sysmon.cpuHistory;
    if (key === "gpu") return Sysmon.gpuHistory;
    if (key === "ram") return Sysmon.memHistory;
    if (key === "net") return Sysmon.netDownHistory;
    return Sysmon.diskReadHistory;
  }

  function statValuesB(key) {
    if (key === "net") return Sysmon.netUpHistory;
    if (key === "disk") return Sysmon.diskWriteHistory;
    return null;
  }

  function statInkB(key) {
    if (key === "net") return Sysmon.netUpInk;
    return Sysmon.diskWriteInk;
  }

  function statFacts(key) {
    if (key === "cpu") return [
      { label: "clock", value: Sysmon.cpuFreq === null ? "--"
          : (Sysmon.cpuFreq / 1000).toFixed(2) + " GHz" },
      { label: "temp", value: Sysmon.cpuTemp === null ? "--" : Sysmon.cpuTemp + "°C" },
      { label: "load", value: Sysmon.cpuLoad === null ? "--" : Sysmon.cpuLoad.toFixed(2) }
    ];
    if (key === "gpu") return [
      { label: Sysmon.gpuPresent ? "temp" : "", value: Sysmon.gpuPresent
          ? (Sysmon.gpuTemp > 0 ? Sysmon.gpuTemp + "°C" : "--") : "no gpu" }
    ];
    if (key === "ram") return [
      { label: "used", value: Helpers.format1f(Sysmon.memUsed) + " GiB" },
      { label: "total", value: Helpers.format1f(Helpers.giB(Sysmon.memTotal)) + " GiB" },
      { label: "swap", value: Helpers.format1f(Sysmon.swapUsed) + " GiB" }
    ];
    if (key === "net") return [
      { label: "up", value: Sysmon.netUpText, ink: Sysmon.netUpInk },
      { label: "link", value: Sysmon.netConnected
          ? (Sysmon.netIface !== "" ? Sysmon.netIface : "up") : "down" },
      { label: "address", value: Sysmon.netIp !== "" ? Sysmon.netIp : "--" }
    ];
    return [
      { label: "write", value: Sysmon.diskWriteText, ink: Sysmon.diskWriteInk },
      { label: "used", value: Sysmon.diskUsedPct + "%" },
      { label: "capacity",
        value: Helpers.format1f(Sysmon.diskTotal / 1073741824) + " GiB" }
    ];
  }

  // Fixed per reading, so the facts Repeater gets a model that never moves.
  function statFactCount(key) {
    return key === "gpu" ? 1 : 3;
  }

  property string query: ""
  property var rows: []
  property var filtered: []
  property int sel: 0
  property var selected: ({})          // pid -> true
  property string uptime: "unknown uptime"
  property var killPids: []
  property string killLabel: ""
  property bool confirmKill: true      // confirm strip button focus
  property var failList: []

  readonly property int cols: 1
  readonly property int visibleRows: 10
  readonly property int cellH: 30

  // ── the order of the list ────────────────────────────────────────────
  // Defaults to cpu/descending, which is byte-for-byte what `ps --sort=-pcpu`
  // was already handing back — so the view that opens is the view that always
  // opened, and sorting is something you reach for rather than something that
  // happened to you.
  //
  // Ordered client-side rather than by re-running ps with a different --sort:
  // the rows are already in hand, a re-run costs a process and 2.5s of latency,
  // and `ps` cannot sort by the command's basename at all.
  readonly property var sortKeys: ["cpu", "mem", "pid", "user", "name"]
  property string sortKey: "cpu"
  property bool sortDesc: true

  // Numbers read large-first, names read A-first. Picking the direction per
  // column means one click on any header gives the order you meant.
  function sortDefaultDesc(key) {
    return key === "cpu" || key === "mem";
  }

  function sortBy(key) {
    if (popup.sortKey === key) popup.sortDesc = !popup.sortDesc;
    else { popup.sortKey = key; popup.sortDesc = popup.sortDefaultDesc(key); }
    // The row under the cursor is meaningless once the order changes, so the
    // caret goes home rather than following its pid somewhere off-screen.
    popup.sel = 0;
    popup.applyFilter();
  }

  function cycleSort() {
    const i = popup.sortKeys.indexOf(popup.sortKey);
    popup.sortBy(popup.sortKeys[(i + 1) % popup.sortKeys.length]);
  }

  readonly property bool wide: true

  visible: popup.showFactor > 0.01
  color: "transparent"

  anchors { left: true; right: true; top: true; bottom: true }
  focusable: true
  exclusionMode: ExclusionMode.Ignore

  NumberAnimation {
    id: openAnim
    target: popup; property: "showFactor"
    to: 1; duration: Zenon.slow; easing.type: Zenon.ease
  }

  NumberAnimation {
    id: closeAnim
    target: popup; property: "showFactor"
    to: 0; duration: Zenon.slow; easing.type: Zenon.ease
    onFinished: popup.shown = false
  }

  HyprlandFocusGrab {
    id: grab
    windows: [ popup ]
    active: popup.shown
    onCleared: popup.closePopup()
  }

  IpcHandler {
    target: "Zeus"
    function toggle() { popup.toggle(); }
  }

  // ------------------------------------------------------------- procs --

  Process {
    id: psProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: popup.onProcesses(text)
    }
  }

  Process {
    id: upProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: popup.uptime = Zeus.uptimeClean(text)
    }
  }

  Process {
    id: killProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: popup.onKilled(text)
    }
  }

  property string pinnedPid: ""      // keep the caret on the same process

  function loadProcs() {
    const row = popup.filtered[popup.sel];
    popup.pinnedPid = row ? row.pid : "";
    psProc.command = ["sh", "-c",
      "ps -eo pid=,user=,pcpu=,rss=,args= --sort=-pcpu"];
    psProc.running = true;
  }

  function onProcesses(text) {
    popup.rows = Zeus.parseProcesses(text);
    applyFilter();
    if (popup.pinnedPid !== "") {
      for (let i = 0; i < popup.filtered.length; ++i) {
        if (popup.filtered[i].pid === popup.pinnedPid) {
          popup.sel = i;
          break;
        }
      }
      popup.pinnedPid = "";
    }
    Qt.callLater(() => grid.positionViewAtIndex(popup.sel, ListView.Contain));
  }

  Timer {
    id: refreshTimer
    interval: 2500
    repeat: true
    running: false
    onTriggered: {
      if (popup.shown && popup.mode === "list" && !killProc.running) popup.loadProcs();
    }
  }

  // ---------------------------------------------------------- helpers --

  component HintBar: Item {
    id: hintBarRoot
    height: 28
    property var rows: popup.hints()
    Row {
      anchors.centerIn: parent
      spacing: 22
      Repeater {
        model: hintBarRoot.rows
        Text {
          required property var modelData
          text: "<b><span style=\"color:" + popup.keyColor + ";\">" +
            Zeus.escapeHtml(modelData[0]) + "</span></b> <b><span style=\"color:" +
            popup.dimColor + ";\">" + Zeus.escapeHtml(modelData[1]) + "</span></b>"
          textFormat: Text.RichText
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 13
        }
      }
    }
  }

  function hints() {
    if (popup.mode === "graphs")
      return [["tab", "kill list"], ["esc", "close"]];
    if (popup.mode === "confirm")
      return [["return", popup.confirmKill ? "kill" : "abort"],
              ["left/right", "choose"], ["esc", "back"]];
    if (popup.mode === "error")
      return [["esc", "back"]];
    const n = Object.keys(popup.selected).length;
    return [["tab", "graphs"], ["type", "filter"],
            ["shift return", "multi-select"],
            ["esc", "clear · close"],
            ["return", n > 0 ? "confirm (" + n + ")" : "select + confirm"]];
  }

  // ------------------------------------------------------------- open --

  function openPopup() {
    popup.shown = true;
    popup.collapsing = false;
    popup.mode = "graphs";
    popup.query = "";
    filterInput.text = "";
    popup.selected = {};
    popup.sel = 0;
    popup.failList = [];
    popup.uptime = "unknown uptime";

    loadProcs();
    upProc.command = ["uptime", "-p"];
    upProc.running = true;
    refreshTimer.restart();

    focusRetry.counter = 0;
    focusRetry.restart();
    closeAnim.stop();
    popup.showFactor = 0;
    openAnim.restart();
    popup.syncFocus();
  }

  function closePopup() {
    refreshTimer.stop();
    popup.collapsing = true;
    openAnim.stop();
    closeAnim.restart();
  }

  function toggle() {
    if (popup.shown) popup.closePopup();
    else popup.openPopup();
  }

  function syncFocus() {
    Qt.callLater(() => {
      if (!popup.shown) return;
      if (popup.mode === "list") filterInput.forceActiveFocus();
      else bgRoot.forceActiveFocus();
    });
  }

  // ------------------------------------------------------ list logic --

  function applyFilter() {
    popup.filtered = Zeus.sortRows(
      Zeus.filterRows(popup.rows, popup.query), popup.sortKey, popup.sortDesc);
    if (popup.sel >= popup.filtered.length) popup.sel = popup.filtered.length - 1;
    if (popup.sel < 0) popup.sel = 0;
    grid.positionViewAtIndex(popup.sel, ListView.Contain);
  }

  function currentRow() {
    return popup.filtered[popup.sel] || null;
  }

  function toggleBallot() {
    const row = currentRow();
    if (!row) return;
    if (popup.selected[row.pid]) delete popup.selected[row.pid];
    else popup.selected[row.pid] = true;
    popup.selected = Object.assign({}, popup.selected);   // retrigger bindings
  }

  function selectedCount() {
    return Object.keys(popup.selected).length;
  }

  // plain return with nothing marked: mark current row and move on
  function goToConfirm() {
    if (popup.filtered.length === 0) return;
    if (popup.selectedCount() === 0) toggleBallot();

    const pids = Object.keys(popup.selected)
      .map((p) => parseInt(p, 10)).sort((a, b) => a - b);
    popup.killPids = pids.map((p) => String(p));

    if (pids.length === 1) {
      let cmd = "Process";
      for (const r of popup.rows) {
        if (String(r.pid) === popup.killPids[0]) { cmd = r.args; break; }
      }
      popup.killLabel = "Kill " + cmd;
    } else {
      popup.killLabel = "Kill " + pids.length + " Processes";
    }
    popup.confirmKill = true;
    popup.mode = "confirm";
    popup.syncFocus();
  }

  function executeKills() {
    const script = "for p in " + popup.killPids.map(Zeus.shellQuote).join(" ") +
      '; do kill "$p" 2>/dev/null || echo "FAIL $p"; done';
    killProc.command = ["bash", "-c", script];
    killProc.running = true;
  }

  function onKilled(text) {
    const fails = [];
    for (const line of String(text).split("\n")) {
      const m = line.match(/^FAIL (\d+)$/);
      if (m) fails.push(m[1]);
    }
    if (fails.length === 0) {
      popup.selected = {};
      popup.openPopup();          // fresh list, seamless continuation
    } else {
      popup.failList = fails;
      popup.mode = "error";
      popup.syncFocus();
    }
  }

  // ----------------------------------------------------------- keys --

  function goBack() {
    popup.mode = "list";
    popup.applyFilter();
    popup.syncFocus();
  }

  function moveSel(delta) {
    const len = popup.filtered.length;
    if (len === 0) return;
    popup.sel = ((popup.sel + delta) % len + len) % len;
    Qt.callLater(() => grid.positionViewAtIndex(popup.sel, ListView.Contain));
  }

  function moveVert(delta) {
    const len = popup.filtered.length;
    if (len === 0) return;
    const rows = Math.ceil(len / popup.cols);
    const row = Math.floor(popup.sel / popup.cols);
    const col = popup.sel % popup.cols;
    let newRow = ((row + delta) % rows + rows) % rows;
    const rowLen = (newRow === rows - 1) ? (len - newRow * popup.cols) : popup.cols;
    popup.sel = newRow * popup.cols + Math.min(col, rowLen - 1);
    Qt.callLater(() => grid.positionViewAtIndex(popup.sel, ListView.Contain));
  }

  function moveHoriz(delta) {
    const len = popup.filtered.length;
    if (len < 2) return;
    const col = popup.sel % popup.cols;
    const base = popup.sel - col;
    const rowLen = Math.min(popup.cols, len - base);
    popup.sel = base + (((col + delta) % rowLen) + rowLen) % rowLen;
    Qt.callLater(() => grid.positionViewAtIndex(popup.sel, ListView.Contain));
  }

  // ---------------------------------------------------------- panel --

  MouseArea {
    anchors.fill: parent
    z: 0
    onClicked: popup.closePopup()
  }

  Item {
    id: panel
    width: 1000
    height: popup.calcHeight()
    // Zenon.slow is the pill's own height easing in shell.qml
    Behavior on height { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }
    anchors {
      horizontalCenter: parent.horizontalCenter
      bottom: parent.bottom
      bottomMargin: Zenon.bottomLift(popup.morphMode, popup.screen, popup.statusbar)
    }
    z: 1
    opacity: popup.contentFade
    transform: Scale {
      origin.x: panel.width / 2
      origin.y: panel.height
      xScale: popup.panelX
      yScale: popup.panelY
    }

    MouseArea { anchors.fill: parent }

    LayerShadow {
      panel: bgRoot
      cornerRadius: Zenon.pillRadius
      morphed: popup.morphMode
    }

    // ClippingRectangle, not Rectangle + clip: true. Qt's own clip is
    // RECTANGULAR — it clips to the bounding box and knows nothing about the
    // radius — so every square child painted to the panel's edge (the bottom
    // strip most visibly) filled in the rounded corners behind it. This one
    // clips to the rounded shape itself.
    ClippingRectangle {
      id: bgRoot
      anchors.fill: parent
      // Grown by its own border: a ClippingRectangle insets its children by
      // border.width on every side, so the content box came out 2px smaller
      // than the panel and any layout measured against the panel's size fell
      // one row or one column short. This hands the content its full box back.
      anchors.margins: -bgRoot.border.width
      color: popup.morphMode ? "transparent" : popup.bgColor
      radius: Zenon.pillRadius
      topLeftRadius: Zenon.pillRadius
      topRightRadius: Zenon.pillRadius
      bottomLeftRadius: Zenon.pillRadius
      bottomRightRadius: Zenon.pillRadius
      border.color: popup.morphMode ? "transparent" : popup.borderColor
      border.width: 1
      focus: true
      // Same cascade as every other layer, with the kill list's one extra piece of
      // state folded in where alt c used to hold it: unwind what you have
      // built up, innermost first, and only close once there is nothing left.
      Keys.onEscapePressed: (event) => {
        event.accepted = true;
        if (popup.mode === "confirm" || popup.mode === "error") {
          popup.goBack();
        } else if (popup.mode === "graphs") {
          popup.closePopup();
        } else if (filterInput.text !== "") {
          filterInput.clear();
        } else if (Object.keys(popup.selected).length > 0) {
          popup.selected = {};
        } else {
          popup.closePopup();
        }
      }

      Keys.onPressed: (event) => {
        // Tab is the seam between the two views, and it works from both of
        // them. Handled before the per-mode branches so neither has to know.
        if (event.key === Qt.Key_Tab &&
            (popup.mode === "graphs" || popup.mode === "list")) {
          event.accepted = true;
          popup.toggleView();
          return;
        }
        if (popup.mode === "list") {
          // Alt+S cycles the column, same chord picasso's picker uses. A bare
          // letter is not available here: the filter field has it.
          if (event.key === Qt.Key_S && (event.modifiers & Qt.AltModifier)) {
            event.accepted = true;
            popup.cycleSort();
            return;
          }
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            event.accepted = true;
            if (event.modifiers & Qt.ShiftModifier) popup.toggleBallot();
            else popup.goToConfirm();
          } else if (event.key === Qt.Key_Up) {
            event.accepted = true; popup.moveVert(-1);
          } else if (event.key === Qt.Key_Down) {
            event.accepted = true; popup.moveVert(1);
          } else if (event.key === Qt.Key_Left) {
            event.accepted = true; popup.moveHoriz(-1);
          } else if (event.key === Qt.Key_Right) {
            event.accepted = true; popup.moveHoriz(1);
          } else if (event.key === Qt.Key_PageUp) {
            event.accepted = true; popup.moveVert(-6);
          } else if (event.key === Qt.Key_PageDown) {
            event.accepted = true; popup.moveVert(6);
          }
        } else if (popup.mode === "confirm") {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter ||
              event.key === Qt.Key_Space) {
            event.accepted = true;
            if (popup.confirmKill) popup.executeKills();
            else popup.goBack();
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            event.accepted = true;
            popup.confirmKill = !popup.confirmKill;
          } else if (event.key === Qt.Key_Tab) {
            event.accepted = true;
            popup.confirmKill = !popup.confirmKill;
          }
        } else { // error
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter ||
              event.key === Qt.Key_Escape) {
            event.accepted = true;
            popup.goBack();
          }
        }
      }

      // -------------------------------------------------- list view --

      Item {
        id: listView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "list" ? 1 : 0
        // slides in from the right when it arrives from the graphs, and from
        // the left on the way back out to confirm — the direction says which
        // way through the panel you are moving
        x: popup.mode === "list" ? 0 : (popup.mode === "graphs" ? 24 : -24)
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          // input bar — only takes room while there's something typed
          Item {
            id: inputBar
            width: parent.width
            height: 50
            clip: true

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: popup.borderColor
            }

            Text {
              id: filterGlyph
              anchors.left: parent.left
              anchors.leftMargin: 16
              anchors.verticalCenter: parent.verticalCenter
              text: "\uF071"
              color: popup.errColor
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 500
              font.pixelSize: 19
            }

            // The same line the graphs' header carries, in the same ink and the
            // same size — it is one reading about the machine, and it should not
            // change character depending on which half of the panel you are in.
            Text {
              id: listStatus
              anchors.right: parent.right
              anchors.rightMargin: 20
              anchors.verticalCenter: parent.verticalCenter
              text: popup.statusLine
              color: popup.dimColor
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 13
            }

            // A Row would have had to be told the field's width as a number;
            // anchored between its two neighbours instead, the field gives back
            // exactly the room the status line needs however long it gets.
            Item {
              anchors.left: filterGlyph.right
              anchors.leftMargin: 10
              anchors.right: listStatus.left
              anchors.rightMargin: 16
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              visible: inputBar.height > 2

                TextInput {
                  id: filterInput
                  anchors.fill: parent
                  verticalAlignment: TextInput.AlignVCenter
                  color: popup.entryColor
                  selectionColor: popup.errColor
                  selectedTextColor: "#000000"
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.weight: 500
                  font.pixelSize: 17
                  cursorVisible: activeFocus
                  cursorDelegate: Item {}
                  clip: true
                  Keys.forwardTo: bgRoot

                  // Focus navigation consumes Tab before Keys.forwardTo ever
                  // sees it, so the seam has to be claimed here as well.
                  Keys.onTabPressed: (event) => {
                    event.accepted = true;
                    popup.toggleView();
                  }

                  Rectangle {
                    id: pulseCursor
                    anchors.left: parent.left
                    anchors.leftMargin: Math.min(filterInput.contentWidth + 2,
                                                 filterInput.width - 5)
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3
                    height: 20
                    radius: 1
                    color: popup.entryColor
                    opacity: 0.25
                    visible: filterInput.activeFocus
                    SequentialAnimation on opacity {
                      running: filterInput.activeFocus
                      loops: Animation.Infinite
                      NumberAnimation { to: 1; duration: 550; easing.type: Easing.InOutSine }
                      NumberAnimation { to: 0.25; duration: 550; easing.type: Easing.InOutSine }
                    }
                  }

                  onTextChanged: {
                    popup.query = filterInput.text;
                    popup.sel = 0;
                    popup.applyFilter();
                  }
                }
            }
          }

          // column headers
          Item {
            width: parent.width
            height: 26

            Row {
              anchors.fill: parent
              leftPadding: 10
              spacing: 0

              Item { width: 22; height: 26 }

              SortHeader {
                width: parent.width * 0.12
                sortKey: "pid"; label: "PID"
              }
              SortHeader {
                width: parent.width * 0.09
                sortKey: "user"; label: "USER"
              }
              SortHeader {
                width: parent.width * 0.54
                sortKey: "name"; label: "COMMAND"
              }
              Item { width: parent.width * 0.02; height: 26 }
              SortHeader {
                width: parent.width * 0.075
                sortKey: "mem"; label: "RAM"; rightAlign: true
              }
              SortHeader {
                width: parent.width * 0.095
                sortKey: "cpu"; label: "CPU"; rightAlign: true
              }
              Item { width: parent.width * 0.03; height: 1 }
            }

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: popup.borderColor
            }
          }

          // process grid
          Item {
            width: parent.width
            height: popup.filtered.length === 0 ? 40 : 0

            Text {
              anchors.centerIn: parent
              visible: popup.filtered.length === 0
              text: "No matches found"
              color: popup.dimColor
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 600
              font.pixelSize: 15
            }
          }

          GridView {
            id: grid
            width: parent.width
            height: popup.gridHeight()
            clip: true
            flow: GridView.FlowLeftToRight
            cellWidth: width / popup.cols
            cellHeight: popup.cellH
            model: popup.filtered
            highlightMoveDuration: 120

            delegate: Item {
              required property var modelData
              required property int index
              width: grid.cellWidth
              height: grid.cellHeight

              Rectangle {
                anchors.fill: parent
                color: index === popup.sel ? popup.selColor : "transparent"
              }

              Row {
                anchors.fill: parent
                leftPadding: 8
                spacing: 0

                Item {
                  width: 22
                  height: parent.height
                  Text {
                    visible: !!popup.selected[modelData.pid]
                    text: Zeus.BALLOT
                    color: popup.errColor
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 16
                  }
                }

                // A column header that sorts. Click to order by this column, click again to
  // flip. The caret on the active column is the ONLY place the current order
  // is shown: the status line beside it is shared with the graphs view, and
  // graphs has no sort to report — one reading about the machine should not
  // change character depending on which half of the panel you are in.
  component SortHeader: Item {
    id: head
    property string sortKey: ""
    property string label: ""
    property bool rightAlign: false
    readonly property bool active: popup.sortKey === head.sortKey

    height: 26

    Text {
      anchors.fill: parent
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: head.rightAlign ? Text.AlignRight : Text.AlignLeft
      // \u25BE / \u25B4 — down for descending, up for ascending
      text: head.active
        ? head.label + (popup.sortDesc ? " \u25BE" : " \u25B4")
        : head.label
      color: head.active ? popup.headColor
        : (headMa.containsMouse ? popup.keyColor : popup.dimColor)
      font.family: "JetBrainsMono Nerd Font"
      font.pixelSize: 12

      Behavior on color {
        ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
      }
    }

    MouseArea {
      id: headMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: popup.sortBy(head.sortKey)
    }
  }

  component DataCell: Text {
                  height: parent.height
                  verticalAlignment: Text.AlignVCenter
                  color: index === popup.sel ? popup.errColor : popup.fgColor
                  textFormat: Text.RichText
                  clip: true
                  font.family: "JetBrainsMono Nerd Font"
                  font.weight: Font.Medium
                  font.pixelSize: 16
                }

                DataCell {
                  width: parent.width * 0.12
                  text: Zeus.highlight(modelData.pid, popup.query)
                }
                DataCell {
                  width: parent.width * 0.09
                  elide: Text.ElideRight
                  text: Zeus.highlight(modelData.user, popup.query)
                }
                DataCell {
                  width: parent.width * 0.54
                  elide: Text.ElideRight
                  text: Zeus.highlight(modelData.args, popup.query)
                }
                Item { width: parent.width * 0.02; height: 1 }
                DataCell {
                  width: parent.width * 0.075
                  horizontalAlignment: Text.AlignRight
                  text: Zeus.highlight(modelData.mem, popup.query)
                  color: index === popup.sel ? popup.errColor : popup.fgColor
                }
                DataCell {
                  width: parent.width * 0.095
                  horizontalAlignment: Text.AlignRight
                  text: Zeus.highlight(modelData.cpu + "%", popup.query)
                  color: index === popup.sel ? popup.errColor
                    : (parseFloat(modelData.cpu) >= 50 ? popup.errColor : popup.dimColor)
                }
                Item { width: parent.width * 0.03; height: 1 }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  popup.sel = index;
                  popup.toggleBallot();
                }
              }
            }
          }

          // hint strip — bottom, per the rasi mainbox order. The count and the
          // uptime moved up into the input bar, so this is the hints alone.
          Rectangle {
            width: parent.width
            height: popup.hintH
            color: "#66282f36"

            Rectangle {
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: "#4d45505c"
            }

            HintBar {
              width: parent.width
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }

      // ------------------------------------------------- graphs view --
      // Five readings, one row each, full width. A time series is only readable
      // if it is wide, so the rows stack rather than tiling into a grid of
      // postage stamps.

      Item {
        id: graphsView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "graphs" ? 1 : 0
        x: popup.mode === "graphs" ? 0 : -24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Item {
            width: parent.width
            height: popup.headerH

            Text {
              anchors.left: parent.left
              anchors.leftMargin: 20
              anchors.verticalCenter: parent.verticalCenter
              text: "SYSTEM"
              color: popup.headColor
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 600
              font.pixelSize: 18
            }

            Text {
              anchors.right: parent.right
              anchors.rightMargin: 20
              anchors.verticalCenter: parent.verticalCenter
              text: popup.statusLine
              color: popup.dimColor
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 13
            }

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: popup.borderColor
            }
          }

          Repeater {
            model: popup.statKeys

            delegate: StatRow {
              required property string modelData
              width: graphsView.width
              statKey: modelData
            }
          }

          Rectangle {
            width: parent.width
            height: popup.hintH
            color: "#66282f36"

            Rectangle {
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: "#4d45505c"
            }

            HintBar {
              width: parent.width
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }

      // ------------------------------------------------ confirm view --

      Item {
        id: confirmView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "confirm" ? 1 : 0
        x: popup.mode === "confirm" ? 0 : 24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Rectangle {
            width: parent.width
            height: 52
            color: popup.errColor
            topLeftRadius: 10
            topRightRadius: 10

            Text {
              anchors.centerIn: parent
              text: popup.killLabel
              color: "#000000"
              font.bold: true
              elide: Text.ElideMiddle
              width: Math.min(implicitWidth + 8, parent.width - 60)
              horizontalAlignment: Text.AlignHCenter
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 700
              font.pixelSize: 17
            }
          }

          Row {
            id: confirmButtons
            width: parent.width

            Repeater {
              model: [{ label: "Confirm", action: true },
                      { label: "Abort", action: false }]

              delegate: Item {
                required property var modelData
                width: confirmButtons.width / 2
                height: 42

                Rectangle {
                  anchors.fill: parent
                  color: popup.confirmKill === modelData.action
                    ? "#4de78284" : "transparent"
                }

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: popup.confirmKill === modelData.action
                    ? (modelData.action ? popup.errColor : popup.fgColor)
                    : popup.dimColor
                  font.bold: popup.confirmKill === modelData.action
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.weight: 700
                  font.pixelSize: 15
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                    onClicked: {
                    popup.confirmKill = modelData.action;
                    if (modelData.action) popup.executeKills();
                    else popup.goBack();
                  }
                }
              }
            }
          }

        }
      }

      // -------------------------------------------------- error view --

      Item {
        id: errorView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "error" ? 1 : 0
        x: popup.mode === "error" ? 0 : -24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Item { width: 1; height: 20 }

          Rectangle {
            width: parent.width
            height: 64
            color: popup.errColor

            Text {
              anchors.centerIn: parent
              text: "Failed to kill PID(s): " + popup.failList.join(", ")
              color: "#000000"
              font.bold: true
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 700
              font.pixelSize: 17
            }
          }

          Item { width: 1; height: 10 }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "press esc to go back"
            color: popup.dimColor
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 13
          }
        }
      }
    }
  }

  // -------------------------------------------------------- helpers --

  function gridHeight() {
    if (popup.filtered.length === 0) return 0;
    const needed = Math.ceil(popup.filtered.length / popup.cols);
    return Math.max(1, Math.min(needed, popup.visibleRows)) * popup.cellH;
  }

  function calcHeight() {
    if (popup.mode === "graphs")
      return popup.headerH + popup.statKeys.length * popup.graphRowH + popup.hintH;
    if (popup.mode === "list")
      return 50 + 26 + (popup.filtered.length === 0 ? 40 : popup.gridHeight())
        + popup.hintH;
    if (popup.mode === "confirm")
      return 52 + 42;
    return 122;
  }

  Timer {
    id: focusRetry
    interval: 60
    repeat: true
    onTriggered: {
      if (!popup.shown) {
        stop();
        return;
      }
      popup.syncFocus();
      if ((popup.mode === "list" && filterInput.activeFocus) ||
          (popup.mode !== "list" && bgRoot.activeFocus)) stop();
      if (focusRetry.counter++ > 12) stop();
    }
    property int counter: 0
  }

  Component.onCompleted: {}

  // One reading: its name and current value on the left, its last two minutes
  // across the middle, and the numbers that give it context on the right.
  //
  // Takes a KEY, not a bundle of values. Every live number is a binding through
  // popup.stat*(key), so this delegate is built once and then only updates —
  // handing it a rebuilt object would recreate it, Canvas and all, several times
  // a second.
  component StatRow: Item {
    id: statRow
    required property string statKey
    height: popup.graphRowH

    readonly property color ink: popup.statInk(statRow.statKey)
    readonly property var valuesB: popup.statValuesB(statRow.statKey)

    Rectangle {
      anchors.fill: parent
      anchors.margins: 4
      anchors.leftMargin: 12
      anchors.rightMargin: 12
      radius: 6
      color: rowHover.hovered ? Zenon.hoverTint : "transparent"
      Behavior on color { ColorAnimation { duration: Zenon.fast } }
    }
    HoverHandler { id: rowHover }

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.leftMargin: 12
      anchors.right: parent.right
      anchors.rightMargin: 12
      height: 1
      color: popup.borderColor
    }

    // ── name and current value ──────────────────────────────────────
    Item {
      id: readingBox
      anchors.left: parent.left
      anchors.leftMargin: 22
      anchors.verticalCenter: parent.verticalCenter
      width: 132
      height: 56

      Text {
        id: rowLabel
        anchors.top: parent.top
        anchors.left: parent.left
        text: popup.statLabel(statRow.statKey)
        color: statRow.ink
        font.family: "JetBrainsMono Nerd Font Propo"
        font.weight: Font.Bold
        font.pixelSize: 13
      }

      Row {
        anchors.left: parent.left
        anchors.top: rowLabel.bottom
        anchors.topMargin: 2
        height: 30
        spacing: 4

        // the reading over its own unlit face, the way every other number in
        // this shell is drawn
        Item {
          anchors.verticalCenter: parent.verticalCenter
          width: liveValue.implicitWidth
          height: liveValue.implicitHeight

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: Helpers.ghostText(popup.statValue(statRow.statKey))
            color: Zenon.trough(statRow.ink)
            font.family: Zenon.clockFamily
            font.weight: Font.Bold
            font.pixelSize: 24
          }
          Text {
            id: liveValue
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: popup.statValue(statRow.statKey)
            color: statRow.ink
            font.family: Zenon.clockFamily
            font.weight: Font.Bold
            font.pixelSize: 24
          }
        }

        Text {
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 4
          text: popup.statUnit(statRow.statKey)
          color: popup.keyColor
          font.family: "JetBrainsMono Nerd Font Propo"
          font.weight: Font.Bold
          font.pixelSize: 13
        }
      }
    }

    // ── the trace ───────────────────────────────────────────────────
    Item {
      id: graphBox
      anchors.left: readingBox.right
      anchors.leftMargin: 8
      anchors.right: factsBox.left
      anchors.rightMargin: 18
      anchors.verticalCenter: parent.verticalCenter
      height: 48

      // a floor and a midline, so the trace has something to be read against
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: popup.borderColor
      }
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: 1
        color: Qt.rgba(1, 1, 1, 0.04)
      }

      // Two Sparklines declared outright rather than a Repeater over a channel
      // list: the second is only used by the two readings that have a direction
      // each way, and a Repeater here would be one more model rebuilt at 4Hz.
      // Overlaying them in one frame is what makes "mostly reading" or "mostly
      // uploading" legible at a glance.
      Sparkline {
        anchors.fill: parent
        values: popup.statValuesA(statRow.statKey)
        lineColor: statRow.ink
        fillColor: statRow.ink
        fillOpacity: 0.16
        maxPoints: Sysmon.span
        lineWidth: 1.6
      }

      Sparkline {
        anchors.fill: parent
        visible: statRow.valuesB !== null
        values: statRow.valuesB ?? []
        lineColor: popup.statInkB(statRow.statKey)
        fillColor: popup.statInkB(statRow.statKey)
        // lighter, so the first channel stays the one you read
        fillOpacity: 0.10
        maxPoints: Sysmon.span
        lineWidth: 1.6
      }
    }

    // ── the numbers around it ───────────────────────────────────────
    Row {
      id: factsBox
      anchors.right: parent.right
      anchors.rightMargin: 24
      anchors.verticalCenter: parent.verticalCenter
      height: 40
      spacing: 20

      // the COUNT, which is fixed per reading — the facts themselves are looked
      // up per index so the delegates are never recreated
      Repeater {
        model: popup.statFactCount(statRow.statKey)

        delegate: Column {
          required property int index
          readonly property var fact: popup.statFacts(statRow.statKey)[index] ?? null
          visible: fact !== null && fact.value !== ""
          spacing: 1

          Text {
            anchors.right: parent.right
            text: parent.fact ? parent.fact.value : ""
            color: (parent.fact && parent.fact.ink) ? parent.fact.ink : popup.fgColor
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: Font.Bold
            font.pixelSize: 14
          }
          Text {
            anchors.right: parent.right
            text: parent.fact ? parent.fact.label : ""
            color: popup.dimColor
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 11
          }
        }
      }
    }
  }

}
