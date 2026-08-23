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

PanelWindow {
  id: popup

  WlrLayershell.layer: WlrLayer.Overlay

  property bool shown: false
  property bool morphMode: false
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

  visible: popup.morphMode ? popup.shown : bg.opacity > 0.01
  color: "transparent"
  anchors { bottom: true }
  implicitWidth: popup.contentWidth
  implicitHeight: 32
  margins.left: Math.max(0, ((popup.screen ? popup.screen.width : 1920) - popup.contentWidth) / 2)
  margins.right: Math.max(0, ((popup.screen ? popup.screen.width : 1920) - popup.contentWidth) / 2)
  exclusionMode: ExclusionMode.Ignore
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

  property string processIcon: "\uEB7F"
  property string terminalIcon: "\uEA85"

  onScreenChanged: popup.updateStacking()
  function updateStacking() {
    if (popup.morphMode) {
      popup.margins.bottom = 6;
      return;
    }
    const bar = popup.statusbar;
    let h = 0;
    if (bar && popup.screen && bar.screen && popup.screen.name === bar.screen.name) {
      h = bar.height;
    }
    popup.margins.bottom = h;
  }

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
      "printf '%s' " + Runner.shellQuote(job.content) + " " + op + " " + Runner.shellQuote(job.path)];
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
    popup.updateStacking();
    popup.shown = true;
    popup.mode = "search";
    popup.query = "";
    popup.sel = 0;
    input.readOnly = false;

    histCat.running = false;
    histCat.running = true;
    popup.applyFilter();
    focusRetry.counter = 0;
    focusRetry.restart();
    popup.debugState("open");
  }

  function closeRunner() {
    popup.shown = false;
    popup.debugState("close");
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
  readonly property real listW: list.contentWidth
  readonly property real pickerW: pickerList.contentWidth
  property int contentWidth: {
    if (popup.mode === "picker") return Math.min(1000, Math.ceil(popup.pickerW));
    return Math.min(1000, Math.ceil(inputBar.width + popup.listW));
  }

  Rectangle {
    id: bg
    anchors.fill: parent
    // matches the morpheus pill's morphed radius
    radius: 12
    color: popup.morphMode ? "transparent" : "#b3000000"
    border.color: popup.morphMode ? "transparent" : "#20242a"
    border.width: 1

    opacity: popup.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    // the pill tracks contentWidth, so this must ease at the pill's rate
    Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    transform: Translate {
      id: spawnT
      y: popup.shown ? 0 : bg.height
      Behavior on y { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    }

    Item {
      id: content
      anchors.fill: parent
      clip: true

      Row {
        id: searchRow
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "search" ? 1 : 0
        x: popup.mode === "search" ? 0 : -24
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

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
          Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

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
              color: "#fab387"
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
              color: "#fab387"
              selectionColor: "#fab387"
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
                color: "#fab387"
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
            required property var modelData
            required property int index
            width: rowText.implicitWidth + 24
            height: ListView.view.height

            Rectangle {
              id: selRect
              anchors.fill: parent
              // erebus' rule: only the row that actually sits in a pill corner
              // rounds off, so the strip stays square-edged in the middle
              radius: 0
              topLeftRadius: index === 0 ? 12 : 0
              bottomLeftRadius: index === 0 ? 12 : 0
              topRightRadius: index === popup.filtered.length - 1 ? 12 : 0
              bottomRightRadius: index === popup.filtered.length - 1 ? 12 : 0
              color: index === popup.sel ? "#fab387" : "transparent"
            }

            Text {
              id: rowText
              anchors.centerIn: parent
              text: Runner.highlight(modelData.displayText, popup.query)
              color: index === popup.sel ? "#000000" : "#fab387"
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
        x: popup.mode === "picker" ? 0 : -36
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        Rectangle {
          id: msgArea
          width: parent.width * 0.5
          height: parent.height
          color: "transparent"

          Text {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            text: popup.query
            color: "#fab387"
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
            required property var modelData
            required property int index
            width: pickerText.implicitWidth + 24
            height: ListView.view.height

            Rectangle {
              id: pickerSelRect
              anchors.fill: parent
              radius: 0
              topLeftRadius: index === 0 ? 12 : 0
              bottomLeftRadius: index === 0 ? 12 : 0
              topRightRadius: index === popup.pickerRows.length - 1 ? 12 : 0
              bottomRightRadius: index === popup.pickerRows.length - 1 ? 12 : 0
              color: index === popup.sel ? "#fab387" : "transparent"
            }

            Text {
              id: pickerText
              anchors.centerIn: parent
              text: modelData.label
              color: index === popup.sel ? "#000000" : "#fab387"
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
        if ((event.key === Qt.Key_C) && (event.modifiers & Qt.AltModifier)) {
          event.accepted = true;
          input.text = "";
        } else if (event.key === Qt.Key_Delete) {
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
