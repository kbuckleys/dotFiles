// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "runner.js" as Runner
import "../morpheus"

PanelWindow {
  id: popup

  WlrLayershell.layer: WlrLayer.Overlay

  property bool shown: false
  property bool morphMode: false
  // 0..1, driven by shell.qml, which owns the crossfade schedule: 0 until the
  // pill's own row has finished clearing, then rising to 1 as the pill
  // finishes taking this layer's shape
  property real morphFade: 1

  property real showFactor: popup.shown ? 1 : 0
  Behavior on showFactor { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }
  // Morphed, the handover is timed off the PILL's progress rather than this
  // window's own showFactor, so the rows can't fade up over a morpheus row
  // that is still on screen.
  // Math.min, not morphFade alone. Handing the pill straight to another
  // layer leaves morphFade pinned at 1 — the pill never un-morphs, so there
  // is nothing to ease it down — and this layer stayed fully opaque until its
  // window simply blinked out. Its own closeAnim is already easing
  // showFactor to 0, so taking the lower of the two fades it out on the way
  // between layers while leaving the normal open schedule untouched.
  readonly property real contentFade: popup.morphMode
    ? Math.min(popup.morphFade, popup.showFactor) : popup.showFactor
  property string mode: "search"
  property string query: ""
  property var histLines: []
  property var freqMap: ({})
  property var appsSnapshot: []
  property var rows: []
  property var filtered: []
  property int sel: 0

  property var pickerRows: [
    { key: "Terminal", label: Runner.ICON_T + "  Terminal" },
    { key: "Process", label: Runner.ICON_P + "  Process" },
    { key: "Back", label: Runner.ICON_B + "  Back" },
  ]

  // stay mapped through the whole morph-out, not just while `shown`:
  // closeRunner() drops `shown` on frame one so the pill can start
  // collapsing, but the rows still have to fade out on the way down
  visible: popup.shown || popup.contentFade > 0.01 || popup.showFactor > 0.01
  color: "transparent"
  // Fixed-size surface, spanning the screen. The strip inside it is what
  // changes width. Runner used to animate the WINDOW: implicitWidth and both
  // side margins were driven off liveWidth, so every keystroke that changed
  // the content width renegotiated the wayland surface with the compositor
  // once per frame for the length of the ease. That is a resize storm, and no
  // amount of easing makes a resize storm smooth — every other layer here
  // already uses a fixed surface with a moving panel inside it.
  anchors { left: true; right: true; bottom: true }
  // contentWidth is the target; liveWidth is the value actually on screen.
  // The pill eases toward the same target on the same Zenon.slow curve,
  // so easing here — rather than snapping the window and letting the
  // background catch up inside it — is what keeps the rows sitting still
  // relative to the pill they are painted on.
  property real liveWidth: (popup.morphMode && popup.statusbar && popup.statusbar.width > 0)
    ? popup.statusbar.width : popup.contentWidth
  // Morphed, liveWidth already IS the pill's live animated width, so the two
  // are locked frame-for-frame by construction. A Behavior on top of that
  // would be a second easing chasing an easing source — guaranteed lag.
  // Standalone there is no pill to follow, so the ease stays.
  Behavior on liveWidth {
    enabled: !popup.morphMode
    NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease }
  }
  // the pill's own slot height, not a literal: runner is a one-liner that
  // morphs INTO the pill, so a 32 here went 2px short the moment the slot
  // grew to 34 and the strip stopped lining up with the thing it becomes
  implicitHeight: Zenon.slot
  exclusionMode: ExclusionMode.Ignore
  // the surface is screen-wide now, so say what part of it is actually there
  mask: Region { item: strip }
  focusable: true

  HyprlandFocusGrab {
    id: grab
    windows: [ popup ]
    active: popup.shown
    onCleared: popup.closeRunner()
  }

  IpcHandler {
    target: "Runner"
    function toggle() {
      popup.toggle();
    }
  }

property var statusbar: null

  // every rounded corner in the runner, in one place — single token in Zenon
  readonly property real corner: Zenon.pillRadius
  // the pill's live corner radius, handed down by shell.qml (also Zenon.pillRadius)
  property real morphRadius: Zenon.pillRadius
  // The radius of the corner a row is actually sitting in. Standalone that is
  // the runner's own background; morphed the runner IS the pill, so it is the
  // pill's — and the pill's is easing, so a row that rounded to the runner's
  // own 5 cut a visible notch across a 12px pill corner.
  readonly property real edgeCorner: popup.morphMode ? popup.morphRadius : popup.corner
  // The panel's stroke — the pill's own when morphed, since bg goes
  // transparent and the pill is what you are actually seeing. A highlight
  // drawn flush to the panel's bounds sits ON that 1px line with its corner
  // struck at the OUTER radius, so the two arcs never nest and the row reads
  // as stepping outside the panel it is in.
  readonly property real edgeInset: 1
  readonly property real innerCorner: Math.max(0, popup.edgeCorner - popup.edgeInset)

  property string processIcon: "\uEB7F"
  property string terminalIcon: "\uEA85"

  // A binding, not an imperative call from openRunner(). openRunner() ran
  // BEFORE `shown` flipped, so morphMode was still false when it fired and the
  // morphed runner was stacked a bar-height above the pill it is supposed to
  // be sitting inside. The runner puts it on the window rather than an inner
  // panel, but the number is the same one every layer uses.
  margins.bottom: Zenon.bottomLift(popup.morphMode, popup.screen, popup.statusbar)

  Repeater {
    id: appLoader
    model: DesktopEntries.applications
    delegate: Item { required property var modelData }
  }

  Cat {
    id: histCat
    path: Runner.histPath()
    onDone: (text) => {
      popup.histLines = Runner.parseHistory(text);
      popup.loadTick();
    }
  }

  Cat {
    id: freqCat
    path: Runner.freqPath()
    onDone: (text) => {
      popup.freqMap = Runner.parseFreq(text);
      popup.loadTick();
    }
  }

  property int pendingLoad: 2

  function loadTick() {
    if (--popup.pendingLoad === 0) {
      popup.debugState("loaded");
      popup.rebuild();
    }
  }

  Process {
    id: writeProc
    onExited: popup.drainWrite()
  }
  property var writeQueue: []

  function writeFile(path, content) {
    popup.writeQueue.push({ path: path, content: content, append: false });
    popup.drainWrite();
  }

  function appendFile(path, content) {
    popup.writeQueue.push({ path: path, content: content, append: true });
    popup.drainWrite();
  }

  function drainWrite() {
    if (popup.writeQueue.length === 0 || writeProc.running) return;
    const job = popup.writeQueue.shift();
    const op = job.append ? ">>" : ">";
    writeProc.command = ["sh", "-c",
      "printf '%s' " + Strings.shellQuote(job.content) + " " + op + " " + Strings.shellQuote(job.path)];
    writeProc.running = true;
  }

  function writeHistory() {
    popup.writeFile(Runner.histPath(), Runner.serializeHistory(popup.histLines));
  }

  function writeFreq() {
    popup.writeFile(Runner.freqPath(), Runner.serializeFreq(popup.freqMap));
  }

  function refreshApps() {
    const vals = DesktopEntries.applications.values;
    const snapshot = [];
    for (let i = 0; i < vals.length; ++i) {
      const e = vals[i];
      if (e) snapshot.push({ name: e.name, exec: e.execString, id: e.id, icon: e.icon });
    }
    popup.appsSnapshot = snapshot;
    popup.debugState("apps");
    popup.rebuild();
  }

  function rebuild() {
    const apps = Runner.getApps(popup.appsSnapshot);
    popup.rows = Runner.buildRows(apps, popup.histLines || [], popup.freqMap || {});
    popup.applyFilter();
  }

  function applyFilter() {
    popup.filtered = Runner.filterRows(popup.rows, popup.query);
    fitTimer.restart();
    if (popup.sel >= popup.filtered.length) popup.sel = popup.filtered.length - 1;
    if (popup.sel < 0) popup.sel = 0;
    popup.followSelection();
    popup.debugState("filter");
  }

  function followSelection() {
    Qt.callLater(() => {
      list.positionViewAtIndex(popup.sel, ListView.Contain);
      pickerList.positionViewAtIndex(popup.sel, ListView.Contain);
    });
  }

  function bump(key) {
    popup.freqMap = Runner.bumpFreq(popup.freqMap, key);
    popup.writeFreq();
  }

  function runCommand(cmd, mode) {
    const icon = mode === "Terminal" ? popup.terminalIcon : popup.processIcon;
    popup.histLines = Runner.addHistory(popup.histLines, cmd, mode, icon);
    popup.bump(cmd);
    popup.writeHistory();
    if (mode === "Terminal") {
      Quickshell.execDetached(["sh", "-c", Runner.terminalCommand(cmd)]);
    } else {
      Quickshell.execDetached(["sh", "-c", Runner.processCommand(cmd)]);
    }
    popup.closeRunner();
  }

  function confirm() {
    const idx = popup.sel;
    if (popup.mode === "picker") {
      const choice = popup.pickerRows[idx].key;
      if (choice === "Terminal") popup.runCommand(popup.query, "Terminal");
      else if (choice === "Process") popup.runCommand(popup.query, "Process");
      else popup.backToSearch();
      return;
    }
    const row = popup.filtered[idx];
    if (row) {
      if (row.kind === "app") {
        popup.bump(row.key);
        Quickshell.execDetached(["sh", "-c", Runner.launchAppCommand(row.id)]);
        popup.closeRunner();
      } else {
        popup.runCommand(row.key, row.raw.startsWith(Runner.ICON_P) ? "Process" : "Terminal");
      }
    } else {
      popup.showPicker();
    }
  }

  function deleteSelected() {
    if (popup.mode !== "search") return;
    const row = popup.filtered[popup.sel];
    if (row && row.kind === "hist") {
      popup.histLines = Runner.deleteHistoryLine(popup.histLines, row.raw);
      popup.writeHistory();
      popup.rebuild();
    }
  }

  function showPicker() {
    popup.mode = "picker";
    popup.sel = 0;
    input.readOnly = true;
    popup.debugState("picker");
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
      input.forceActiveFocus();
      if (input.activeFocus) stop();
      if (focusRetry.counter++ > 12) stop();
    }
    property int counter: 0
  }

  function backToSearch() {
    popup.mode = "search";
    input.readOnly = false;
    Qt.callLater(() => input.forceActiveFocus());
    popup.debugState("back");
  }

  function debugState(tag) {
    const rows = popup.filtered.map((r) => r.displayText + (r.kind === "app" ? " [app:" + r.id + "]" : "")).join("|");
    const appInfo = popup.appsSnapshot.slice(0, 4).map((a) => "{" + a.name + "|" + a.exec + "}").join("");
    popup.appendFile("/tmp/runner_state.txt",
      tag + " mode=" + popup.mode + " query=" + JSON.stringify(popup.query) + " sel=" + popup.sel + " shown=" + popup.shown +
      " apps=" + popup.appsSnapshot.length + " hist=" + popup.histLines.length + " rows=" + popup.rows.length + " filtered=" + popup.filtered.length +
      " appInfo=" + appInfo +
      " rows=[" + rows + "]\n");
  }

  function openRunner() {
    popup._resetAfterClose();
    popup.shown = true;
    popup.mode = "search";
    popup.query = "";
    popup.sel = 0;
    if (input) {
      input.text = "";
      input.readOnly = false;
    }

    histCat.running = false;
    histCat.running = true;
    popup.applyFilter();
    focusRetry.counter = 0;
    focusRetry.restart();
    popup.debugState("open");
  }

  // standalone close on selection should keep the strip at its current
  // width and keep the selected row highlighted while it slides/fades,
  // not snap the model to "" and shrink to 0 mid-animation
  property bool _isClosing: false
  Timer {
    id: closeResetTimer
    interval: Zenon.slow + 40
    onTriggered: {
      popup.query = "";
      popup.mode = "search";
      popup.sel = 0;
      if (input) {
        input.text = "";
        input.readOnly = false;
      }
      popup._isClosing = false;
      popup.debugState("close-reset");
    }
  }
  function closeRunner() {
    if (popup._isClosing) return;
    popup._isClosing = true;
    popup.shown = false;
    // keep query/mode/sel until the slide/fade (showFactor) finishes
    // so fittedListW/contentWidth/list stay at the selected width
    closeResetTimer.restart();
    popup.debugState("close");
  }
  function _resetAfterClose() {
    // used when reopening before the close timer fires (e.g. quick toggle)
    closeResetTimer.stop();
    popup._isClosing = false;
  }

  function toggle() {
    if (popup.shown) popup.closeRunner();
    else popup.openRunner();
  }

  function moveSel(delta) {
    const len = popup.mode === "picker" ? popup.pickerRows.length : popup.filtered.length;
    if (len === 0) return;
    popup.sel = (popup.sel + delta + len) % len;
    popup.followSelection();
  }

  function autocomplete() {
    if (popup.mode !== "search") {
      popup.moveSel(1);
      return;
    }
    const row = popup.filtered[popup.sel];
    if (!row) return;
    const kind = row.kind;
    const key = row.key;
    input.text = row.text;
    const idx = popup.filtered.findIndex((r) => r.kind === kind && r.key === key);
    if (idx >= 0) popup.sel = idx;
  }

  // Shrink-wrap width: input bar (while typing) + list content, max 1000.
  // No trailing pad and no minimum — the rows already carry 12px a side, so
  // anything added here is dead space at the right end, most obvious once a
  // filter has narrowed the list to a couple of short entries.
  // ListView's own content extent, not contentItem.childrenRect: childrenRect
  // measures whichever delegates happen to be materialised, so it lingers wide
  // after a filter narrows the model and the pill keeps the old width.
  readonly property real pickerW: pickerList.contentWidth

  // ── whole-row shrink-wrap ────────────────────────────────────────────────
  // The strip ends on a row boundary rather than at the raw 1000px cap, so a
  // row dropped for being sliced doesn't leave its slot behind as dead space.
  //
  // Measured imperatively rather than as a binding, and against the fixed cap
  // rather than the live viewport: the pill's width is what the measurement
  // decides, so a binding that read the viewport back would be a cycle
  // (width -> which rows fit -> width). Evaluating once per change instead of
  // iterating to a fixpoint makes that impossible.
  readonly property real listCap: 1000 - inputBar.width
  property real fittedListW: 0

  // The run of rows the strip actually shows, as model indices. This is what
  // makes the corners content-aware: a row rounds because it is the first or
  // last row on screen, not because of where it sits in the model. Filtering,
  // scrolling and dropping a sliced row all move these two numbers, so the
  // rounding follows without any of them being special-cased.
  property int fitFirst: -1
  property int fitLast: -1

  function measureFit() {
    const avail = popup.listCap;
    const c = list.contentX;
    let first = -1;
    let last = -1;
    let best = 0;
    for (let i = 0; i < popup.filtered.length; ++i) {
      const it = list.itemAtIndex(i);
      if (!it) break;                    // beyond what the view has realised
      const left = it.x - c;
      const right = left + it.width;
      if (right <= 0.5) continue;        // scrolled off to the left
      if (left < -0.5) continue;         // sliced by the left edge
      if (right > avail + 0.5) break;    // first row the cap would slice
      if (first < 0) first = i;
      last = i;
      best = right;
    }
    if (first >= 0) {
      popup.fitFirst = first;
      popup.fitLast = last;
      return best;
    }
    // Nothing fits whole: a single row wider than the entire strip. It is
    // shown clipped rather than collapsing the pill to nothing — moveSel
    // already keeps it selected. It does own the left corner, but the strip
    // ends part-way through it, so there is no row in the right one.
    popup.fitFirst = popup.filtered.length > 0 ? 0 : -1;
    popup.fitLast = -1;
    return Math.min(avail, list.contentWidth);
  }

  Timer {
    id: fitTimer
    interval: 0
    onTriggered: popup.fittedListW = popup.measureFit()
  }

  Connections {
    target: list
    // contentWidth fires once the delegates for a new model are sized, which
    // is the earliest point measureFit() can see real geometry
    function onContentWidthChanged() { fitTimer.restart(); }
    function onContentXChanged() { fitTimer.restart(); }
  }
  onListCapChanged: fitTimer.restart()

  property int contentWidth: {
    if (popup.mode === "picker") return Math.min(1000, Math.ceil(msgArea.width + popup.pickerW));
    return Math.min(1000, Math.ceil(inputBar.width + popup.fittedListW));
  }

  // The moving part. Its width eases on the GPU instead of on the compositor.
  Item {
    id: strip
    width: popup.liveWidth
    height: parent.height
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
  }

  Rectangle {
    id: bg
    anchors.fill: strip
    radius: popup.edgeCorner
    color: popup.morphMode ? "transparent" : "#b3000000"
    border.color: popup.morphMode ? "transparent" : Zenon.surface
    border.width: 1

    opacity: popup.morphMode ? 1 : popup.showFactor
    transform: Translate {
      id: spawnT
      // the slide-up is the standalone entrance. Morphed, the pill has already
      // travelled that distance and the panel IS the pill, so a second slide
      // reads as the two coming apart.
      y: popup.morphMode ? 0 : bg.height * (1 - popup.showFactor)
    }

    Item {
      id: content
      anchors.fill: parent
      clip: true
      // only the morph needs a separate content fade; standalone, bg already
      // carries the whole panel out and a second fade just muddies it
      opacity: popup.morphMode ? popup.contentFade : 1

      // Erebus' crossfade, to the pixel: the outgoing view leaves to the
      // LEFT by 12 and the incoming one arrives from the RIGHT by the same
      // 12, so the pair reads as one strip sliding rather than two views
      // both retreating the same way. Runner had them both leaving left, at
      // -24 and -36 — two different distances in one direction, which is why
      // the picker never felt like it came from anywhere.
      Row {
        id: searchRow
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "search" ? 1 : 0
        x: popup.mode === "search" ? 0 : -12
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Rectangle {
          id: inputBar
          // Only surfaces once what you have typed matches nothing already in
          // the list (history or apps) — i.e. you are composing a new command
          // and the row strip can no longer show you what you are typing.
          property bool showInput: input.text.length > 0 && popup.filtered.length === 0
          width: showInput
            ? Math.min(10 + promptText.width + input.contentWidth + 12, 700)
            : 0
          height: parent.height
          color: "transparent"
          Behavior on width { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

          Row {
            anchors.fill: parent
            leftPadding: 10
            spacing: 0

            Text {
              id: promptText
              width: 30
              height: parent.height
              text: "\uF120"
              visible: inputBar.showInput
              color: Zenon.yellow
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 18
              verticalAlignment: Text.AlignVCenter
            }

            TextInput {
              id: input
              width: parent.width - promptText.width
              height: parent.height
              text: popup.query
              color: Zenon.yellow
              selectionColor: Zenon.yellow
              selectedTextColor: "#000000"
              cursorVisible: true

              cursorDelegate: Item {}
              clip: true
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 18
              verticalAlignment: Text.AlignVCenter
              Keys.forwardTo: content
              onTextChanged: {
                popup.query = input.text;
                popup.sel = 0;
                popup.applyFilter();
              }

              Rectangle {
                id: pulseCursor
                anchors.left: parent.left
                anchors.leftMargin: Math.min(input.contentWidth, input.width - pulseCursor.width)
                anchors.verticalCenter: input.verticalCenter
                width: 3
                height: 20
                radius: 1
                color: Zenon.yellow
                opacity: 0.25
                visible: inputBar.showInput
                SequentialAnimation on opacity {
                  running: input.activeFocus && popup.mode === "search" && inputBar.showInput
                  loops: Animation.Infinite
                  NumberAnimation { to: 1; duration: 550; easing.type: Easing.InOutSine }
                  NumberAnimation { to: 0.25; duration: 550; easing.type: Easing.InOutSine }
                }
              }
            }
          }
        }

        ListView {
          id: list
          width: parent.width - inputBar.width
          height: parent.height
          orientation: ListView.Horizontal
          clip: true
          model: popup.filtered
          snapMode: ListView.SnapOneItem
          highlightMoveDuration: 120
          // realise offscreen delegates so ListView.contentWidth is an exact sum
          // of real delegate widths rather than an average-based estimate
          cacheBuffer: 4000

          delegate: Item {
            id: row
            required property var modelData
            required property int index
            width: rowText.implicitWidth + 24
            height: ListView.view.height

            // Half an entry is worse than no entry, so anything not wholly
            // inside the strip is simply not painted — whether it is cut off
            // by the 1000px cap or by the strip being scrolled. The slot
            // itself stays, so scrolling and index maths are untouched.
            // The selected row is always drawn: it is the one about to run,
            // and an entry wider than the whole strip would otherwise vanish
            // the moment you arrowed onto it.
            visible: row.index === popup.sel || popup.fitLast < 0
              || (row.index >= popup.fitFirst && row.index <= popup.fitLast)

            // Corners follow the pill's edge, not the row's position in the
            // model — index 0 is not the left edge while the input bar is
            // showing, and the last index stopped being the right edge as
            // soon as a sliced row could be dropped. Asked of measureFit's
            // kept run rather than of live geometry: the strip's width eases
            // whenever the pill does, and a row measured against a viewport
            // still in motion never matches its edge, so the corner sat
            // square for the whole animation.
            readonly property bool atLeftEdge: row.index === popup.fitFirst
              && inputBar.width < 0.5
            readonly property bool atRightEdge: row.index === popup.fitLast

            Rectangle {
              id: selRect
              // held off the panel's stroke, and only on the sides that
              // actually touch it
              anchors.fill: parent
              anchors.topMargin: popup.edgeInset
              anchors.bottomMargin: popup.edgeInset
              anchors.leftMargin: row.atLeftEdge ? popup.edgeInset : 0
              anchors.rightMargin: row.atRightEdge ? popup.edgeInset : 0
              // erebus' rule: only the row that actually sits in a pill corner
              // rounds off, so the strip stays square-edged in the middle
              radius: 0
              topLeftRadius: row.atLeftEdge ? popup.innerCorner : 0
              bottomLeftRadius: row.atLeftEdge ? popup.innerCorner : 0
              topRightRadius: row.atRightEdge ? popup.innerCorner : 0
              bottomRightRadius: row.atRightEdge ? popup.innerCorner : 0
              color: index === popup.sel ? Zenon.yellow : "transparent"
            }

            Text {
              id: rowText
              anchors.centerIn: parent
              text: Runner.highlight(modelData.displayText, popup.query)
              color: index === popup.sel ? "#000000" : Zenon.yellow
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 16
              textFormat: Text.RichText
              horizontalAlignment: Text.AlignHCenter
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                popup.sel = index;
                popup.confirm();
              }
            }
          }
        }
      }

      Row {
        id: pickerRow
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "picker" ? 1 : 0
        x: popup.mode === "picker" ? 0 : 12
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Rectangle {
          id: msgArea
          // shrink-wrap the echoed command instead of claiming a flat half of
          // the pill: at 50% the three picker buttons were handed less width
          // than they needed and the last one was cut off by the ListView clip.
          // The cap is the point past which a very long command elides rather
          // than pushing the buttons off the end.
          width: Math.min(420, msgText.implicitWidth + 24)
          height: parent.height
          color: "transparent"

          Text {
            id: msgText
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            text: popup.query
            color: Zenon.yellow
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: Font.Bold
            font.pixelSize: 16
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideMiddle
          }
        }

        ListView {
          id: pickerList
          width: parent.width - msgArea.width
          height: parent.height
          orientation: ListView.Horizontal
          clip: true
          model: popup.pickerRows
          highlightMoveDuration: 120
          cacheBuffer: 4000

          delegate: Item {
            id: pickerBtn
            required property var modelData
            required property int index
            width: pickerText.implicitWidth + 24
            height: ListView.view.height

            // Same rule as the search strip, asked of the picker's own
            // content: msgArea always holds the pill's left end, so index 0
            // (Terminal) is a middle row and stays square, and only the last
            // button sits in a corner. The picker is never filtered, so its
            // run is simply the whole model.
            readonly property bool atLeftEdge: msgArea.width < 0.5 && index === 0
            readonly property bool atRightEdge: index === popup.pickerRows.length - 1

            Rectangle {
              id: pickerSelRect
              anchors.fill: parent
              anchors.topMargin: popup.edgeInset
              anchors.bottomMargin: popup.edgeInset
              anchors.leftMargin: pickerBtn.atLeftEdge ? popup.edgeInset : 0
              anchors.rightMargin: pickerBtn.atRightEdge ? popup.edgeInset : 0
              radius: 0
              topLeftRadius: pickerBtn.atLeftEdge ? popup.innerCorner : 0
              bottomLeftRadius: pickerBtn.atLeftEdge ? popup.innerCorner : 0
              topRightRadius: pickerBtn.atRightEdge ? popup.innerCorner : 0
              bottomRightRadius: pickerBtn.atRightEdge ? popup.innerCorner : 0
              color: index === popup.sel ? Zenon.yellow : "transparent"
            }

            Text {
              id: pickerText
              anchors.centerIn: parent
              text: modelData.label
              color: index === popup.sel ? "#000000" : Zenon.yellow
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 16
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                popup.sel = index;
                popup.confirm();
              }
            }
          }
        }
      }

      Keys.onEscapePressed: (event) => {
        event.accepted = true;
        if (popup.mode === "picker") {
          popup.backToSearch();
        } else if (input.text !== "") {
          input.text = "";
        } else {
          popup.closeRunner();
        }
      }
      Keys.onReturnPressed: (event) => {
        event.accepted = true;
        popup.confirm();
      }
      Keys.onTabPressed: (event) => {
        event.accepted = true;
        popup.autocomplete();
      }
      Keys.onBacktabPressed: (event) => {
        event.accepted = true;
        popup.moveSel(-1);
      }
      Keys.onLeftPressed: (event) => popup.moveSel(-1)
      Keys.onRightPressed: (event) => popup.moveSel(1)
      Keys.onUpPressed: (event) => popup.moveSel(-1)
      Keys.onDownPressed: (event) => popup.moveSel(1)
      Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Delete) {
          event.accepted = true;
          popup.deleteSelected();
        } else if (event.key === Qt.Key_Return && (event.modifiers & Qt.AltModifier)) {
          event.accepted = true;
          popup.showPicker();
        }
      }
    }
  }

  Timer {
    id: appPoll
    interval: 50
    repeat: true
    running: true
    onTriggered: {
      const vals = DesktopEntries.applications.values;
      if (vals && vals.length > 0) {
        popup.refreshApps();
        appPoll.stop();
      }
    }
  }

  Component.onCompleted: {
    Quickshell.execDetached(["bash", "-c", "rm -f /tmp/runner_state.txt"]);
    DesktopEntries.applicationsChanged.connect(() => popup.refreshApps());
    histCat.running = true;
    freqCat.running = true;
  }
}
