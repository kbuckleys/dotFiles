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

  // mode: graphs · list · net · confirm · error — one seamless surface, no
  // separate menus. Graphs is what opens: most of the time the question is
  // "what is this machine doing", and only sometimes "what do I have to kill"
  // or "what is talking to the network". Tab walks the three views in a ring.
  property string mode: "graphs"

  // The ring Tab walks, in the order the panel reads: the whole machine, then
  // its processes, then its connections. Written once so the key handler, the
  // hints and the crossfade cannot disagree about what comes next.
  readonly property var views: ["graphs", "list", "net"]

  function nextView(m) {
    const i = popup.views.indexOf(m);
    return popup.views[(i + 1) % popup.views.length];
  }

  function setMode(m) {
    if (popup.mode === m) return;
    popup.mode = m;
    // each list is only worth feeding while it is the thing on screen, and
    // bandwhich is capturing packets — it must not run behind a closed panel
    if (m === "list") popup.loadProcs();
    popup.netRunning = (m === "net");
    popup.syncFocus();
  }

  function toggleView() {
    popup.setMode(popup.nextView(popup.mode));
  }

  // Open on the view a caller names — the bar's meters do, so that clicking a
  // meter lands on what that meter is about rather than wherever the panel was
  // last left. Clicking the same meter again closes it.
  function toggleAt(m) {
    if (popup.shown && popup.mode === m) { popup.closePopup(); return; }
    if (!popup.shown) popup.openPopup();   // lands on graphs
    popup.setMode(m);
  }

  // ── what is on the wire ───────────────────────────────────────────────
  // bandwhich's three tables, all of them, in the order its own screen puts
  // them: what is talking, where it is talking to, and each conversation. They
  // are the same bytes counted three ways, and leaving two of them out made
  // this view quietly smaller than the tool it is showing.
  //
  // The rows are normalised in zeus.js on the way in — a thing, what it is
  // bound to, and its two rates — so all three tables share one delegate and
  // one sort.
  readonly property var netTableOrder: ["process", "remote", "connection"]
  readonly property var netTableTitle: ({
    process: "PROCESSES", remote: "REMOTE ADDRESSES", connection: "CONNECTIONS"
  })
  property var netTables: ({ process: [], remote: [], connection: [] })
  property string netQuery: ""
  property string netSortKey: "down"
  property bool netSortDesc: true
  // The permissions story, in bandwhich's own words. Empty while it is working.
  property string netError: ""

  // bandwhich needs four capabilities and this shell cannot grant them — that
  // takes root, and counting bytes on a wire is privileged with no way around
  // it. So when it will not run, the view says exactly what to run rather than
  // sitting there empty looking broken: one script, once per machine, which
  // also installs the pacman hook that keeps it applied across upgrades.
  //
  // Through Helpers.script rather than written out, so it is right on whatever
  // machine this checkout is sitting on — the same reason vault finds its
  // pinentry that way.
  readonly property string netFixHint:
    "sudo " + Helpers.script("bandwhich-grant.sh")

  // ...or just click it. polkit is what asks for the password, so this is the
  // same one-time root action with a dialog in front of it instead of a
  // terminal — which is the difference between "set this up on the new
  // machine" and "open the view and say yes once".
  property bool netGranting: false

  function netGrant() {
    if (popup.netGranting) return;
    popup.netGranting = true;
    popup.netError = "Waiting for authorisation\u2026";
    grantProc.running = true;
  }

  Process {
    id: grantProc
    command: ["pkexec", Helpers.script("bandwhich-grant.sh")]
    stderr: StdioCollector { }
    onExited: (code) => {
      popup.netGranting = false;
      if (code === 0) {
        // capabilities are on the binary now; the next run of bandwhich picks
        // them up, so simply start it again
        popup.netError = "";
        popup.netWarned = false;
        netProc.running = true;
        return;
      }
      // pkexec's two own codes, which are not faults in this code and must not
      // read like them. 126 is a dialog dismissed or an authorisation refused.
      // 127 is pkexec unable to ASK — no polkit agent registered for the
      // session, which happens when the agent lost its race with the display
      // at boot; there is nothing to click through then, so the command beside
      // the button is the way in.
      if (code === 126) popup.netError = "Not authorised \u2014 the grant was dismissed.";
      else if (code === 127) popup.netError = "No polkit agent answered \u2014 run it in a terminal:";
      else popup.netError = Zeus.firstProblem(String(grantProc.stderr.text || ""))
        || ("The grant failed (" + code + ").");
    }
  }

  // What the empty strip costs. One line for "nothing on the wire", two when
  // it is carrying the error and the command that fixes it — and calcHeight
  // has to agree with the strip itself, or the hint bar is pushed off the
  // bottom of the panel and the message reads as bottom-heavy.
  readonly property int netEmptyH: popup.netError !== "" ? 58 : 40
  // Sized so the LABEL lands symmetric, which is a pixel-counting question and
  // was got wrong twice by reasoning about it instead of measuring it.
  //
  // A heading band carries a 1px separator along its bottom edge, so the space
  // the label sits in is one shorter than the band. The label's ink — cap
  // height plus the antialiased row above it, which the eye counts — measures
  // 9px at this size and weight. An even split therefore needs an inside of
  // 9 + 2n: 25. The band is that plus its separator.
  //
  // The font metrics are not the problem and were checked: centring the cap
  // box exactly rather than the ascent/descent box moves it 0.06px. This is
  // rounding, and the only honest fix is a height the rounding divides.
  readonly property int netHeadH: 26
  // How much table the panel will show before it starts scrolling instead of
  // growing. Three tables of everything on a busy machine is taller than the
  // screen; past this the list scrolls and nothing is lost.
  readonly property int netMaxH: 14 * popup.cellH

  property bool netRunning: false
  onNetRunningChanged: {
    if (popup.netRunning) {
      popup.netTables = { process: [], remote: [], connection: [] };
      popup.netBuf = { process: [], remote: [], connection: [] };
      popup.netError = "";
      netProc.running = true;
    } else {
      netProc.running = false;
    }
  }

  // Rows accumulate here as they arrive and land in netTables as a block, so
  // the tables never repaint half-updated.
  property var netBuf: ({ process: [], remote: [], connection: [] })
  // Said once per run, not once per line: a format that changed under us would
  // otherwise show as a table that is quietly short for no stated reason.
  property bool netWarned: false

  function onNetLine(line) {
    // bandwhich prints "Refreshing:" ahead of every block, so the frame is its
    // own to declare and there is nothing to infer from the timing of the
    // lines. The block that just finished lands whole — the tables never
    // repaint half-updated — and a second with nothing on the wire commits an
    // empty buffer, which is the correct answer rather than a stale one.
    if (Zeus.isNetFrame(line)) {
      popup.netTables = popup.netBuf;
      popup.netBuf = { process: [], remote: [], connection: [] };
      return;
    }
    const row = Zeus.parseNetLine(line);
    if (row) popup.netBuf[row.table].push(row);
    else if (!popup.netWarned && Zeus.isNetRow(line)) {
      popup.netWarned = true;
      console.log("zeus: bandwhich row not understood:", line);
    }
  }

  function netSortBy(key) {
    if (popup.netSortKey === key) popup.netSortDesc = !popup.netSortDesc;
    else {
      popup.netSortKey = key;
      // rates read biggest-first, names read A-first
      popup.netSortDesc = (key === "up" || key === "down");
    }
  }

  // One flat list: a heading, then its rows, then the next heading. A sectioned
  // ListView rather than three stacked ones, so the whole thing scrolls as a
  // single surface and one delegate draws every row.
  readonly property var netModel: {
    const out = [];
    for (const key of popup.netTableOrder) {
      const rows = Zeus.sortNet(
        Zeus.filterNet(popup.netTables[key] || [], popup.netQuery),
        popup.netSortKey, popup.netSortDesc);
      if (rows.length === 0) continue;
      out.push({ head: true, title: popup.netTableTitle[key], count: rows.length });
      for (const r of rows) out.push(r);
    }
    return out;
  }

  readonly property bool netEmpty: popup.netModel.length === 0

  // Totals for the line beside the filter — the same two numbers the bar's own
  // meter is showing, arrived at from the other end. Summed over CONNECTIONS
  // alone: the three tables are the same bytes grouped three ways, so adding
  // them all would report three times the traffic. Read off the unfiltered
  // rows too — a filter narrows what you are looking at, not what the machine
  // is doing.
  readonly property string netStatusLine: {
    const conns = popup.netTables.connection || [];
    let up = 0, down = 0;
    for (let i = 0; i < conns.length; ++i) { up += conns[i].up; down += conns[i].down; }
    return (popup.netTables.process || []).length + "p · "
      + (popup.netTables.remote || []).length + "r · " + conns.length + "c · \u2193 "
      + Zeus.formatBps(down) + "/s · \u2191 " + Zeus.formatBps(up) + "/s";
  }

  function netHeight() {
    let h = 0;
    const m = popup.netModel;
    for (let i = 0; i < m.length; ++i) h += m[i].head ? popup.netHeadH : popup.cellH;
    return Math.min(h, popup.netMaxH);
  }

  Process {
    id: netProc
    // No table flag: all three, which is the point — the view is meant to be
    // what bandwhich shows.
    // -n: no DNS resolution — a slow resolver must not be able to stall the
    //     stream, and the bar's tooltip names addresses the same way.
    command: ["bandwhich", "--raw", "-n"]
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: (line) => popup.onNetLine(line)
    }
    stderr: StdioCollector {
      onStreamFinished: {
        const t = String(text).trim();
        if (t !== "") popup.netError = t;
      }
    }
    // Streaming, so it only exits when it fails or when we stop it. Exiting on
    // its own while the view is up is the failure — almost always the missing
    // capabilities, which is what its own stderr will have said.
    onExited: (code) => {
      if (!popup.netRunning) return;
      if (popup.netError === "")
        popup.netError = "bandwhich exited (" + code + ") with nothing to say.";
      popup.netTables = { process: [], remote: [], connection: [] };
    }
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

  // ── pinned ────────────────────────────────────────────────────────────
  // Zeus is a monitor as much as it is a menu, and a monitor you cannot look
  // at while doing the thing you are monitoring is not much of one. Dragging
  // it tears it off the pill: it stops being a menu that closes when you look
  // away and becomes a window that stays where you put it.
  //
  // Nothing here changes until the drag actually happens — the gesture is what
  // asks for it, so opening, using and escaping zeus is exactly as it was.
  property bool pinned: false
  property real pinX: 0
  property real pinY: 0

  // The monitor this panel belongs to, latched for as long as it is open — the
  // same trick shell.qml's morphOnPill uses, and for the same reason.
  //
  // Every layer is bound to the focused monitor, which is right for a menu:
  // it opens where you are looking. It is wrong for zeus. With focus following
  // the mouse, glancing at the other screen dragged the whole panel across
  // with it, pinned or not. So the screen is decided once, when it opens, and
  // held until it closes.
  //
  // It has to be held rather than re-read for a second reason: pinX/pinY are
  // in this window's own coordinates and the window is the size of its screen,
  // so a swap between a 1080x1920 and a 2560x1440 output would reinterpret
  // them against the wrong size and land the panel somewhere arbitrary.
  //
  // `liveScreen` is the focused monitor, handed in unlatched, so open can read
  // where you actually are without going through the latched value it is about
  // to set.
  property var liveScreen: null
  property var homeScreen: null

  // Pinned AND clicked into. Measured, not assumed: setting the surface to
  // OnDemand keyboard focus is NOT enough on its own — hyprland leaves the
  // focused window focused, so `esc` aimed at this panel went to whatever was
  // behind it and closed THAT instead. A grab is what actually moves the
  // keyboard, so the panel takes one when you click it and gives it straight
  // back when you click away.
  property bool holding: false

  // Tear it off where it currently sits, so it does not jump on the first
  // pixel of the drag.
  function pinAt(x, y) {
    popup.pinX = x;
    popup.pinY = y;
    popup.pinned = true;
  }

  // ROUNDED, and that is not tidiness. A drag accumulates float deltas, so the
  // panel comes to rest on a fractional pixel — and every glyph in it is then
  // rasterised half a pixel off its grid, which reads as the whole panel going
  // slightly soft the moment you tear it off. Landing on whole pixels is what
  // keeps the text as sharp pinned as it is on the pill.
  function clampPin() {
    if (!popup.pinned) return;
    popup.pinX = Math.round(
      Math.max(0, Math.min(popup.width - panel.width, popup.pinX)));
    popup.pinY = Math.round(
      Math.max(0, Math.min(popup.height - panel.height, popup.pinY)));
  }

  visible: popup.showFactor > 0.01
  color: "transparent"

  anchors { left: true; right: true; top: true; bottom: true }
  // Unpinned it takes the keyboard outright, the way every other layer does.
  // Pinned it must not: the whole point is that the window you are actually
  // working in keeps its keys, and this one takes them back when clicked —
  // which is what OnDemand means, and what makes `esc` reachable again.
  WlrLayershell.keyboardFocus: popup.pinned
    ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  // Pinned, the surface is still fullscreen but only the panel may be clicked
  // — without this the invisible rest of it would swallow every click on the
  // desktop underneath. Unpinned there is no mask, because catching the click
  // that lands outside is exactly how a menu closes.
  Region { id: panelRegion; item: panel }
  mask: popup.pinned ? panelRegion : null

  NumberAnimation {
    id: openAnim
    target: popup; property: "showFactor"
    to: 1; duration: Zenon.slow; easing.type: Zenon.ease
  }

  NumberAnimation {
    id: closeAnim
    target: popup; property: "showFactor"
    to: 0; duration: Zenon.slow; easing.type: Zenon.ease
    onFinished: {
      popup.shown = false;
      // A pin lasts as long as the panel does. Next time it opens it is a menu
      // again, on the pill, on whichever monitor you are looking at then.
      popup.pinned = false;
      popup.holding = false;
      popup.homeScreen = null;
    }
  }

  HyprlandFocusGrab {
    id: grab
    windows: [ popup ]
    // Unpinned, the grab is what closes the menu when you look away. Pinned,
    // it is only held while the panel has been clicked into — that is what
    // makes it answer the keyboard — and losing it means the click went
    // somewhere else, which is a release rather than a close.
    active: popup.shown && (!popup.pinned || popup.holding)
    onCleared: {
      if (popup.pinned) popup.holding = false;
      else popup.closePopup();
    }
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

  // What Tab reaches next, named rather than restated — the ring is in
  // `views`, so a hint cannot promise a view Tab does not actually go to.
  function nextLabel() {
    return { graphs: "graphs", list: "kill list", net: "connections" }[
      popup.nextView(popup.mode)];
  }

  function hints() {
    // \uF08D is a pin. Prepended rather than replacing anything, so the keys
    // that still work go on saying so.
    if (popup.pinned)
      return [[popup.holding ? "\uF08D" : "click", popup.holding ? "pinned" : "to focus"]]
        .concat(popup.modeHints());
    return popup.modeHints();
  }

  function modeHints() {
    if (popup.mode === "graphs")
      return [["tab", popup.nextLabel()], ["alt 1/2/3", "views"],
              ["drag", "pin"], ["esc", "close"]];
    if (popup.mode === "confirm")
      return [["return", popup.confirmKill ? "kill" : "abort"],
              ["left/right", "choose"], ["esc", "back"]];
    if (popup.mode === "error")
      return [["esc", "back"]];
    if (popup.mode === "net")
      return [["tab", popup.nextLabel()], ["type", "filter"],
              ["click", "sort column"], ["esc", "clear · close"]];
    const n = Object.keys(popup.selected).length;
    return [["tab", popup.nextLabel()], ["type", "filter"],
            ["shift return", "multi-select"],
            ["esc", "clear · close"],
            ["return", n > 0 ? "confirm (" + n + ")" : "select + confirm"]];
  }

  // ------------------------------------------------------------- open --

  function openPopup() {
    popup.shown = true;
    popup.collapsing = false;
    // where you are looking, once — read from the unlatched value so a close
    // that has not finished animating cannot hand back a stale screen
    popup.homeScreen = popup.liveScreen;
    popup.mode = "graphs";
    popup.query = "";
    listBar.clear();
    popup.netQuery = "";
    netBar.clear();
    popup.netRunning = false;
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
    // The pin is NOT dropped here. Clearing it at the start of the close sends
    // the panel back to the bottom of the pill's screen while it is still
    // fading, which reads as a teleport rather than a close — so it is dropped
    // when the animation ends, below, along with the screen it was held on.
    // packet capture must not outlive the panel that asked for it
    popup.netRunning = false;
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
      // both typed views own a field; everything else types into the panel
      if (popup.mode === "list") listBar.takeFocus();
      else if (popup.mode === "net") netBar.takeFocus();
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
    enabled: !popup.pinned
    onClicked: popup.closePopup()
  }

  Item {
    id: panel
    width: 1000
    height: popup.calcHeight()
    // Zenon.slow is the pill's own height easing in shell.qml
    Behavior on height { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }
    // Anchors and x/y cannot both drive a position, and pinned it is x/y that
    // has to — so the unpinned case is written out rather than anchored. These
    // two expressions ARE the anchors they replace: centred horizontally, and
    // lifted off the bottom edge by exactly what every other layer uses.
    x: popup.pinned ? popup.pinX : (parent.width - width) / 2
    y: popup.pinned ? popup.pinY
      : parent.height - height
        - Zenon.bottomLift(popup.morphMode, popup.screen, popup.statusbar)
    // the panel grows and shrinks with the view; pinned near an edge that must
    // not push it off the screen
    onHeightChanged: popup.clampPin()
    z: 1
    opacity: popup.contentFade
    transform: Scale {
      origin.x: panel.width / 2
      origin.y: panel.height
      xScale: popup.panelX
      yScale: popup.panelY
    }

    // Sits UNDER everything the panel draws, so it only ever sees a press the
    // content did not want — an empty stretch of a graph, the strip beside a
    // header. A row keeps its click, the filter field keeps its caret, and
    // what is left over is the handle.
    MouseArea {
      id: dragArea
      anchors.fill: parent
      cursorShape: dragArea.moved ? Qt.ClosedHandCursor : Qt.ArrowCursor

      property real px: 0
      property real py: 0
      property bool moved: false

      onPressed: (m) => {
        dragArea.px = m.x;
        dragArea.py = m.y;
        dragArea.moved = false;
        popup.holding = true;
      }

      onPositionChanged: (m) => {
        if (!dragArea.pressed) return;
        const dx = m.x - dragArea.px;
        const dy = m.y - dragArea.py;
        // A press that wanders a pixel is a click, not a drag. Past the
        // threshold it is a drag, and the first one is what pins it.
        if (!dragArea.moved && Math.abs(dx) + Math.abs(dy) < 6) return;
        if (!dragArea.moved) {
          dragArea.moved = true;
          popup.pinAt(Math.round(panel.x), Math.round(panel.y));
        }
        // The panel moves by the delta, which puts the pointer back where it
        // was pressed inside it — so these accumulate rather than fight.
        popup.pinX += dx;
        popup.pinY += dy;
        popup.clampPin();
      }

      onReleased: dragArea.moved = false
    }

    // The drag area only sees presses the content did not want, so a click on
    // a row or a sort header would never have claimed the keyboard. This is
    // passive — it watches the press without taking it away from the control
    // underneath, so sorting and selecting still work exactly as they did.
    TapHandler {
      enabled: popup.pinned
      acceptedButtons: Qt.AllButtons
      grabPermissions: PointerHandler.TakeOverForbidden
      onPressedChanged: if (pressed) popup.holding = true
    }

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
        } else if (popup.mode === "net") {
          if (popup.netQuery !== "") netBar.clear();
          else popup.closePopup();
        } else if (listBar.text !== "") {
          listBar.clear();
        } else if (Object.keys(popup.selected).length > 0) {
          popup.selected = {};
        } else {
          popup.closePopup();
        }
      }

      Keys.onPressed: (event) => {
        // Tab is the seam between the views, and it works from every one of
        // them. Handled before the per-mode branches so none has to know.
        if (event.key === Qt.Key_Tab && popup.views.indexOf(popup.mode) >= 0) {
          event.accepted = true;
          popup.toggleView();
          return;
        }
        // Alt+1/2/3 land on a view directly, in the order the ring walks them,
        // for when you know where you are going and Tab is two presses away.
        // Alt because a bare digit belongs to the filter field, which is the
        // same reason Alt+S carries the sort. Read off `views` rather than
        // spelled out, so a view added to the ring gets its number for free.
        if ((event.modifiers & Qt.AltModifier)
            && event.key >= Qt.Key_1
            && event.key < Qt.Key_1 + popup.views.length) {
          event.accepted = true;
          popup.setMode(popup.views[event.key - Qt.Key_1]);
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

          FilterBar {
            id: listBar
            width: parent.width
            status: popup.statusLine
            onEdited: (text) => {
              popup.query = text;
              popup.sel = 0;
              popup.applyFilter();
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

                // The filter field, the glyph in front of it and the status line after it.
  // Both typed views wear it — the kill list filtering processes, the net view
  // filtering connections — and they differ only in what the line on the right
  // reads and what the typing is applied to. One bar, told those two things,
  // rather than a second copy of a field, a cursor and a Tab claim.
  component FilterBar: Item {
    id: bar
    property alias text: field.text
    property string status: ""
    signal edited(string text)

    function takeFocus() { field.forceActiveFocus(); }
    function clear() { field.clear(); }
    readonly property bool typing: field.activeFocus

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

    // The same line the graphs' header carries, in the same ink and the same
    // size — it is one reading about the machine, and it should not change
    // character depending on which part of the panel you are in.
    Text {
      id: barStatus
      anchors.right: parent.right
      anchors.rightMargin: 20
      anchors.verticalCenter: parent.verticalCenter
      text: bar.status
      color: popup.dimColor
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 13
    }

    // A Row would have had to be told the field's width as a number; anchored
    // between its two neighbours instead, the field gives back exactly the room
    // the status line needs however long it gets.
    Item {
      anchors.left: filterGlyph.right
      anchors.leftMargin: 10
      anchors.right: barStatus.left
      anchors.rightMargin: 16
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      visible: bar.height > 2

      TextInput {
        id: field
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

        // Focus navigation consumes Tab before Keys.forwardTo ever sees it, so
        // the seam has to be claimed here as well.
        Keys.onTabPressed: (event) => {
          event.accepted = true;
          popup.toggleView();
        }

        Rectangle {
          anchors.left: parent.left
          anchors.leftMargin: Math.min(field.contentWidth + 2, field.width - 5)
          anchors.verticalCenter: parent.verticalCenter
          width: 3
          height: 20
          radius: 1
          color: popup.entryColor
          opacity: 0.25
          visible: field.activeFocus
          SequentialAnimation on opacity {
            running: field.activeFocus
            loops: Animation.Infinite
            NumberAnimation { to: 1; duration: 550; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0.25; duration: 550; easing.type: Easing.InOutSine }
          }
        }

        onTextChanged: bar.edited(field.text)
      }
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
    // Which sort this header belongs to. The kill list and the connections
    // list each keep their own, so a header is TOLD rather than reaching for
    // one — and the kill list's headers, which is all there were, keep working
    // unchanged because its sort is what these default to.
    property string activeKey: popup.sortKey
    property bool desc: popup.sortDesc
    property var pick: (k) => popup.sortBy(k)
    readonly property bool active: head.activeKey === head.sortKey

    height: 26

    Text {
      anchors.fill: parent
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: head.rightAlign ? Text.AlignRight : Text.AlignLeft
      // \u25BE / \u25B4 — down for descending, up for ascending
      text: head.active
        ? head.label + (head.desc ? " \u25BE" : " \u25B4")
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
      onClicked: head.pick(head.sortKey)
    }
  }

  component DataCell: Text {
                  // The kill list inks its selected row; the connections list
                  // has no selection to ink, so what "hot" means is the
                  // caller's to say. Defaulted to what the kill list's cells
                  // were already doing, so none of them had to change.
                  property bool hot: index === popup.sel
                  height: parent.height
                  verticalAlignment: Text.AlignVCenter
                  color: hot ? popup.errColor : popup.fgColor
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

      // ---------------------------------------------------- net view --
      // What is actually on the wire, one row per connection. The kill list
      // one Tab back says which processes are running; this says which of them
      // are talking, to where, and how loudly.

      Item {
        id: netView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "net" ? 1 : 0
        // arrives from the right like the list does, since it sits one further
        // along the ring
        x: popup.mode === "net" ? 0 : 24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          FilterBar {
            id: netBar
            width: parent.width
            status: popup.netStatusLine
            onEdited: (text) => {
              popup.netQuery = text;
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

              Item { width: 12; height: 26 }

              // Generic, because the three tables underneath them are: the
              // first column is a process, then an address, then a connection,
              // and the second is a connection count or the process behind it.
              // A column named for one table would be wrong in the other two.
              SortHeader {
                width: parent.width * 0.42
                sortKey: "name"; label: "NAME"
                activeKey: popup.netSortKey; desc: popup.netSortDesc
                pick: (k) => popup.netSortBy(k)
              }
              SortHeader {
                width: parent.width * 0.24
                sortKey: "detail"; label: "DETAIL"
                activeKey: popup.netSortKey; desc: popup.netSortDesc
                pick: (k) => popup.netSortBy(k)
              }
              Item { width: parent.width * 0.02; height: 26 }
              SortHeader {
                width: parent.width * 0.135
                sortKey: "down"; label: "\u2193 DOWN"; rightAlign: true
                activeKey: popup.netSortKey; desc: popup.netSortDesc
                pick: (k) => popup.netSortBy(k)
              }
              SortHeader {
                width: parent.width * 0.135
                sortKey: "up"; label: "\u2191 UP"; rightAlign: true
                activeKey: popup.netSortKey; desc: popup.netSortDesc
                pick: (k) => popup.netSortBy(k)
              }
              Item { width: parent.width * 0.02; height: 1 }
            }

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: popup.borderColor
            }
          }

          // Nothing to show, and the two reasons for it read differently: a
          // quiet wire is a fine answer, a bandwhich that cannot run is not.
          // The second one carries the fix, because this shell cannot apply it
          // — the capabilities need root, and a panel that just sat there empty
          // would look broken rather than unprivileged.
          Item {
            width: parent.width
            height: popup.netEmpty ? popup.netEmptyH : 0
            clip: true

            Column {
              anchors.centerIn: parent
              spacing: 3
              visible: popup.netEmpty

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: popup.netError !== "" ? Zeus.firstProblem(popup.netError)
                  : (popup.netQuery !== "" ? "No matches found"
                                           : "Nothing on the wire")
                color: popup.netError !== "" ? popup.errColor : popup.dimColor
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 600
                font.pixelSize: 15
              }

              // The fix, as something to press. The command is still spelled
              // out underneath the label, because a button that runs a
              // privileged script should say exactly which one — and because
              // over ssh, or with no polkit agent to answer, typing it is
              // still the way through.
              Item {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: popup.netError !== "" && !popup.netGranting
                width: grantRow.implicitWidth + 18
                height: 22

                Rectangle {
                  anchors.fill: parent
                  radius: 5
                  color: grantMa.containsMouse
                    ? Qt.rgba(Zenon.green.r, Zenon.green.g, Zenon.green.b, 0.14)
                    : "transparent"
                  border.width: 1
                  border.color: grantMa.containsMouse ? Zenon.green : popup.borderColor
                  Behavior on color { ColorAnimation { duration: Zenon.fast } }
                  Behavior on border.color { ColorAnimation { duration: Zenon.fast } }
                }

                Row {
                  id: grantRow
                  anchors.centerIn: parent
                  spacing: 7

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\uF023  grant access"
                    color: grantMa.containsMouse ? Zenon.green : popup.keyColor
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.weight: Font.Bold
                    font.pixelSize: 12
                    Behavior on color { ColorAnimation { duration: Zenon.fast } }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "or  " + popup.netFixHint
                    color: popup.dimColor
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 11
                  }
                }

                MouseArea {
                  id: grantMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: popup.netGrant()
                }
              }
            }
          }

          Item {
            width: parent.width
            height: popup.netHeight()

            ListView {
              id: netList
              anchors.fill: parent
              clip: true
              model: popup.netModel
              boundsBehavior: Flickable.StopAtBounds
              // The tables come and go with the traffic, so a delegate handed
              // a row this frame may be handed a heading the next. Reused
              // rather than rebuilt, the way the kill list's are.
              reuseItems: true

              delegate: Item {
                required property var modelData
                width: netList.width
                height: modelData.head ? popup.netHeadH : popup.cellH

                // ── a table's name, and how many rows it has ──────────
                Item {
                  anchors.fill: parent
                  visible: !!modelData.head

                  Rectangle {
                    anchors.fill: parent
                    color: Zenon.headBg
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 22
                    // Centred in the band MINUS its separator, not in the whole
                    // band — the line is the edge, not part of the inside, and
                    // centring across it is what pushed the label up.
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 1
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.head
                      ? modelData.title + "  " + modelData.count : ""
                    color: popup.headColor
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.weight: Font.Bold
                    font.pixelSize: 11
                  }

                  Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 1
                    color: popup.borderColor
                  }
                }

                // ── a row of it ──────────────────────────────────────
                Row {
                  anchors.fill: parent
                  visible: !modelData.head
                  leftPadding: 10
                  spacing: 0

                  Item { width: 12; height: parent.height }

                  DataCell {
                    hot: false
                    width: parent.width * 0.42
                    elide: Text.ElideMiddle
                    text: modelData.head ? "" : Zeus.highlight(modelData.name, popup.netQuery)
                  }
                  DataCell {
                    hot: false
                    width: parent.width * 0.24
                    elide: Text.ElideRight
                    color: popup.dimColor
                    text: modelData.head ? "" : Zeus.highlight(modelData.detail, popup.netQuery)
                  }
                  Item { width: parent.width * 0.02; height: 1 }
                  DataCell {
                    hot: false
                    width: parent.width * 0.135
                    horizontalAlignment: Text.AlignRight
                    text: modelData.head ? "" : Zeus.escapeHtml(Zeus.formatBps(modelData.down))
                    color: !modelData.head && modelData.down > 0
                      ? Sysmon.netDownInk : popup.dimColor
                  }
                  DataCell {
                    hot: false
                    width: parent.width * 0.135
                    horizontalAlignment: Text.AlignRight
                    text: modelData.head ? "" : Zeus.escapeHtml(Zeus.formatBps(modelData.up))
                    color: !modelData.head && modelData.up > 0
                      ? Sysmon.netUpInk : popup.dimColor
                  }
                  Item { width: parent.width * 0.02; height: 1 }
                }
              }
            }

            // A thumb rather than a full scrollbar: it is a position report,
            // and the wheel is what does the scrolling. Same one howler's
            // history wears.
            Rectangle {
              anchors.right: parent.right
              anchors.rightMargin: 3
              width: 3
              radius: 2
              color: popup.keyColor
              opacity: 0.35
              visible: netList.contentHeight > netList.height
              height: Math.max(24, netList.height
                * (netList.height / Math.max(1, netList.contentHeight)))
              y: netList.contentHeight > netList.height
                ? (netList.contentY / (netList.contentHeight - netList.height))
                  * (netList.height - height)
                : 0
            }
          }

          // hint strip — the same one the other views carry
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
    if (popup.mode === "net")
      return 50 + 26 + (popup.netEmpty ? popup.netEmptyH : popup.netHeight())
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
      if ((popup.mode === "list" && listBar.typing) ||
          (popup.mode === "net" && netBar.typing) ||
          (popup.mode !== "list" && popup.mode !== "net" && bgRoot.activeFocus))
        stop();
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
