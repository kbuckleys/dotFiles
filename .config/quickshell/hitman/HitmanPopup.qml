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
import "hitman.js" as Hitman
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

  // mode: list · confirm · error — one seamless surface, no separate menus
  property string mode: "list"

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
    target: "Hitman"
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
      onStreamFinished: popup.uptime = Hitman.uptimeClean(text)
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
    popup.rows = Hitman.parseProcesses(text);
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
            Hitman.escapeHtml(modelData[0]) + "</span></b> <b><span style=\"color:" +
            popup.dimColor + ";\">" + Hitman.escapeHtml(modelData[1]) + "</span></b>"
          textFormat: Text.RichText
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 13
        }
      }
    }
  }

  // hitman.js has no Quickshell dependency; alias for the hint bar
  QtObject {

    function escapeHtml(s) { return Hitman.escapeHtml(s); }
  }

  function hints() {
    if (popup.mode === "confirm")
      return [["return", popup.confirmKill ? "kill" : "abort"],
              ["left/right", "choose"], ["esc", "back"]];
    if (popup.mode === "error")
      return [["esc", "back"]];
    const n = Object.keys(popup.selected).length;
    return [["type", "filter"], ["shift return", "multi-select"],
            ["esc", "clear · close"],
            ["return", n > 0 ? "confirm (" + n + ")" : "select + confirm"]];
  }

  // ------------------------------------------------------------- open --

  function openPopup() {
    popup.shown = true;
    popup.collapsing = false;
    popup.mode = "list";
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
    popup.filtered = Hitman.filterRows(popup.rows, popup.query);
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
    const script = "for p in " + popup.killPids.map(Hitman.shellQuote).join(" ") +
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
      // Same cascade as every other layer, with hitman's one extra piece of
      // state folded in where alt c used to hold it: unwind what you have
      // built up, innermost first, and only close once there is nothing left.
      Keys.onEscapePressed: (event) => {
        event.accepted = true;
        if (popup.mode !== "list") {
          popup.goBack();
        } else if (filterInput.text !== "") {
          filterInput.clear();
        } else if (Object.keys(popup.selected).length > 0) {
          popup.selected = {};
        } else {
          popup.closePopup();
        }
      }

      Keys.onPressed: (event) => {
        if (popup.mode === "list") {
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
        x: popup.mode === "list" ? 0 : -24
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

            Row {
              anchors.fill: parent
              visible: inputBar.height > 2
              leftPadding: 16
              spacing: 10

              Text {
                text: "\uF071"
                color: popup.errColor
                anchors.verticalCenter: parent.verticalCenter
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 500
                font.pixelSize: 19
              }


              Item {
                width: parent.width - 60
                height: parent.height

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

              Text {
                width: parent.width * 0.12; height: 26
                verticalAlignment: Text.AlignVCenter
                text: "PID"
                color: popup.dimColor
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 12
              }
              Text {
                width: parent.width * 0.09; height: 26
                verticalAlignment: Text.AlignVCenter
                text: "USER"
                color: popup.dimColor
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 12
              }
              Text {
                width: parent.width * 0.54; height: 26
                verticalAlignment: Text.AlignVCenter
                text: "COMMAND"
                color: popup.dimColor
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 12
              }
              Item { width: parent.width * 0.02; height: 26 }
              Text {
                width: parent.width * 0.075; height: 26
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignRight
                text: "RAM"
                color: popup.dimColor
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 12
              }
              Text {
                width: parent.width * 0.095; height: 26
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignRight
                text: "CPU"
                color: popup.dimColor
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 12
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
                    text: Hitman.BALLOT
                    color: popup.errColor
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 16
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
                  text: Hitman.highlight(modelData.pid, popup.query)
                }
                DataCell {
                  width: parent.width * 0.09
                  elide: Text.ElideRight
                  text: Hitman.highlight(modelData.user, popup.query)
                }
                DataCell {
                  width: parent.width * 0.54
                  elide: Text.ElideRight
                  text: Hitman.highlight(modelData.args, popup.query)
                }
                Item { width: parent.width * 0.02; height: 1 }
                DataCell {
                  width: parent.width * 0.075
                  horizontalAlignment: Text.AlignRight
                  text: Hitman.highlight(modelData.mem, popup.query)
                  color: index === popup.sel ? popup.errColor : popup.fgColor
                }
                DataCell {
                  width: parent.width * 0.095
                  horizontalAlignment: Text.AlignRight
                  text: Hitman.highlight(modelData.cpu + "%", popup.query)
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

          // message strip — bottom, per the rasi mainbox order
          Rectangle {
            width: parent.width
            height: 58
            color: "#66282f36"

            Rectangle {
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: "#4d45505c"
            }

            Column {
              anchors.fill: parent
              topPadding: 8
              bottomPadding: 10
              spacing: -3

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: popup.rows.length + " Processes ~ Uptime: " + popup.uptime
                color: popup.headColor
                font.bold: true
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 600
                font.pixelSize: 16
              }

              HintBar { width: parent.width }
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
    if (popup.mode === "list")
      return 50 + 26 + (popup.filtered.length === 0 ? 40 : popup.gridHeight()) + 58;
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
}
