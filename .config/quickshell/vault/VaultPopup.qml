// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "vault.js" as Vault
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
  readonly property real contentFade: popup.morphMode ? popup.morphFade : popup.showFactor

  property var statusbar: null

  readonly property color bgColor: "#cc000000"
  readonly property color borderColor: "#20242a"
  readonly property color fgColor: "#DFDFDD"
  readonly property color headColor: "#9bbfbf"
  readonly property color keyColor: "#a2a8bc"
  readonly property color dimColor: "#6a707f"
  readonly property color entryColor: "#eebebe"
  readonly property color errColor: "#e78284"
  readonly property color selColor: "#4de78284"

  // mode: list · actions · unlock
  property string mode: "list"

  property string query: ""
  property var entries: []
  property var filtered: []
  property int sel: 0

  // the entry whose action strip is open
  property var activeEntry: null
  property string pendingKind: ""
  property int actionSel: 0
  readonly property var actionTypes: [
    { kind: "both",     label: "Type both" },
    { kind: "user",     label: "Type user" },
    { kind: "pass",     label: "Type pass" },
    { kind: "totp",     label: "Type TOTP" },
    { kind: "copypass", label: "Copy pass" },
    { kind: "copyuser", label: "Copy user" },
    { kind: "copytotp", label: "Copy TOTP" },
  ]

  readonly property int cols: 2
  // results that fit one visible column span the whole window
  readonly property int effCols:
    (popup.filtered.length >= 1 && popup.filtered.length <= popup.visibleRows)
      ? 1 : popup.cols
  readonly property int visibleRows: 7
  readonly property int cellH: 34

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
    target: "Vault"

    function toggle() { popup.toggle(); }
  }

  // ------------------------------------------------------------- procs --

  Process {
    id: lsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: popup.onEntries(text)
    }
  }

  Process {
    id: syncProc
    onExited: popup.loadEntries()
  }

  // exit code tells us whether the agent is unlocked
  Process {
    id: unlockedCheck
    onExited: (exitCode) => popup.onUnlockedCheck(exitCode)
  }

  // runs the actual rbw fetch + consume pipeline; secrets stay in pipes
  // (only the failure sentinel ever reaches stdout)
  Process {
    id: actionProc
    stdout: StdioCollector {
      id: actionCol
      waitForEnd: true
    }
    onExited: popup.onActionDone()
  }

  property string errorMsg: ""
  property bool busy: false

  function loadEntries() {
    lsProc.command = ["rbw", "ls", "--raw"];
    lsProc.running = true;
  }

  function onEntries(text) {
    popup.entries = Vault.parseEntries(text);
    popup.applyFilter();
  }

  // ---------------------------------------------------------- actions --

  function currentEntry() {
    return popup.filtered[popup.sel] || null;
  }

  function openActions() {
    const e = currentEntry();
    if (!e) return;
    popup.activeEntry = e;
    popup.actionSel = 0;
    popup.query = "";
    filterInput.text = "";
    popup.applyFilter();
    popup.mode = "actions";
    popup.syncFocus();
  }

  // needle args for rbw: uuid is unambiguous
  function needleArgs(entry) {
    return [Vault.shellQuote(entry.id)];
  }

  function rbwFetch(kind, entry) {
    const id = Vault.shellQuote(entry.id);
    if (kind === "user")
      return "u=$(rbw get --field user " + id + "); ";
    if (kind === "pass")
      return "p=$(rbw get " + id + "); ";
    if (kind === "totp")
      return "t=$(rbw code " + id + "); ";
    return "";
  }

  function execute(kind) {
    const entry = popup.activeEntry;
    if (!entry) return;

    popup.pendingKind = kind;

    // consume pipelines: rbw output flows through pipes only — secrets
    // never appear in argv, env, files, or logs
    if (kind === "both") {
      actionProc.command = ["bash", "-c",
        "{ " + rbwFetch("user", entry) + "} && { " + rbwFetch("pass", entry) + "}" +
        " && sleep 0.3 && wtype \"$u\" -k Tab \"$p\""];
    } else if (kind === "user") {
      actionProc.command = ["bash", "-c",
        rbwFetch("user", entry) + "sleep 0.3 && wtype \"$u\"" +
        " || echo VAULT_ACTION_FAILED"];
    } else if (kind === "pass") {
      actionProc.command = ["bash", "-c",
        rbwFetch("pass", entry) + "sleep 0.3 && wtype \"$p\"" +
        " || echo VAULT_ACTION_FAILED"];
    } else if (kind === "totp") {
      actionProc.command = ["bash", "-c",
        rbwFetch("totp", entry) + "sleep 0.3 && wtype \"$t\"" +
        " || echo VAULT_ACTION_FAILED"];
    } else if (kind === "copypass") {
      actionProc.command = ["bash", "-c",
        rbwFetch("pass", entry) +
        "printf '%s' \"$p\" | wl-copy >/dev/null 2>&1" +
        " && sleep 30" +
        " && if [ \"$(wl-paste)\" = \"$p\" ]; then printf '' | wl-copy >/dev/null 2>&1; fi" +
        " || echo VAULT_ACTION_FAILED"];
    } else if (kind === "copyuser") {
      actionProc.command = ["bash", "-c",
        rbwFetch("user", entry) +
        "printf '%s' \"$u\" | wl-copy >/dev/null 2>&1" +
        " && sleep 30" +
        " && if [ \"$(wl-paste)\" = \"$u\" ]; then printf '' | wl-copy >/dev/null 2>&1; fi" +
        " || echo VAULT_ACTION_FAILED"];
    } else if (kind === "copytotp") {
      actionProc.command = ["bash", "-c",
        rbwFetch("totp", entry) +
        "printf '%s' \"$t\" | wl-copy >/dev/null 2>&1" +
        " && sleep 30" +
        " && if [ \"$(wl-paste)\" = \"$t\" ]; then printf '' | wl-copy >/dev/null 2>&1; fi" +
        " || echo VAULT_ACTION_FAILED"];
    } else {
      return;
    }

    // gate everything behind the agent's lock state
    checkAndRun();
  }

  function checkAndRun() {
    unlockedCheck.command = ["rbw", "unlocked"];
    unlockedCheck.running = true;
  }

  function onUnlockedCheck(code) {
    if (code !== 0) {
      popup.mode = "unlock";
      popup.syncFocus();
      return;
    }
    popup.busy = true;
    actionProc.running = true;
    closeTimer.restart();
  }

  function onActionDone() {
    closeTimer.stop();
    popup.busy = false;
    if (actionCol.text.indexOf("VAULT_ACTION_FAILED") >= 0) {
      popup.errorMsg = popup.pendingKind === "totp"
        ? "no TOTP configured for this entry" : "action failed";
      popup.mode = "error";
      popup.syncFocus();
      return;
    }
    popup.closePopup();
  }

  Timer {
    id: closeTimer
    interval: 700
    repeat: false
    onTriggered: {
      if (popup.mode !== "actions") return;
      popup.closePopup();
    }
  }

  function startUnlock() {
    popup.detach("rbw unlock");
    unlockPoll.restart();
  }

  function detach(script) {
    if (script) Quickshell.execDetached(["bash", "-c", script]);
  }

  Timer {
    id: unlockPoll
    interval: 1000
    repeat: true
    property int tries: 0
    onTriggered: {
      tries++;
      unlockedCheck.command = ["rbw", "unlocked"];
      unlockedCheck.running = true;
      if (tries > 45) {
        stop();
        popup.mode = "list";
        popup.syncFocus();
      }
    }
  }

  // ------------------------------------------------------------- open --

  // fills down each column first:  1 3
  //                                2 4
  property var displayOrder: []

  function rebuildDisplayOrder() {
    const len = popup.filtered.length;
    const c = popup.effCols;
    const r = Math.max(1, Math.ceil(len / c));
    const order = [];
    for (let col = 0; col < c; ++col)
      for (let row = 0; row < r; ++row) {
        const i = col * r + row;
        if (i < len) order.push(i);
      }
    popup.displayOrder = order;
  }

  function applyFilter() {
    popup.filtered = Vault.filterEntries(popup.entries, popup.query);
    if (popup.sel >= popup.filtered.length) popup.sel = popup.filtered.length - 1;
    if (popup.sel < 0) popup.sel = 0;
    rebuildDisplayOrder();
    Qt.callLater(() => list.positionViewAtIndex(popup.sel, GridView.Contain));
  }

  function syncFocus() {
    Qt.callLater(() => {
      if (!popup.shown) return;
      if (popup.mode === "list") filterInput.forceActiveFocus();
      else bgRoot.forceActiveFocus();
    });
  }

  function openPopup() {
    popup.shown = true;
    popup.collapsing = false;
    popup.mode = "list";
    popup.query = "";
    filterInput.text = "";
    popup.sel = 0;
    popup.entries = [];
    popup.filtered = [];
    popup.loadEntries();

    focusRetry.counter = 0;
    focusRetry.restart();
    closeAnim.stop();
    popup.showFactor = 0;
    openAnim.restart();
    popup.syncFocus();
  }

  function closePopup() {
    popup.collapsing = true;
    openAnim.stop();
    closeAnim.restart();
  }

  function toggle() {
    if (popup.shown) popup.closePopup();
    else popup.openPopup();
  }

  function goBack() {
    popup.mode = "list";
    unlockPoll.stop();
    popup.applyFilter();
    popup.syncFocus();
  }

  // ----------------------------------------------------------- hints --

  component HintBar: Item {
    id: hintBarRoot
    height: 26
    property var rows: popup.hints()
    Row {
      anchors.centerIn: parent
      spacing: 20
      Repeater {
        model: hintBarRoot.rows
        Text {
          required property var modelData
          text: "<b><span style=\"color:" + popup.keyColor + ";\">" +
            Vault.escapeHtml(modelData[0]) + "</span></b> <b><span style=\"color:" +
            popup.dimColor + ";\">" + Vault.escapeHtml(modelData[1]) + "</span></b>"
          textFormat: Text.RichText
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 13
        }
      }
    }
  }

  function hints() {
    if (popup.mode === "actions")
      return [["backspace", "back"], ["return", "execute"]];
    if (popup.mode === "unlock")
      return [["return", "unlock"], ["esc", "back"]];
    if (popup.mode === "error")
      return [["esc / return", "back"]];
    return [["type", "filter"], ["return", "actions"], ["alt s", "sync"],
            ["alt l", "lock"]];
  }

  // ----------------------------------------------------------- keys --

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
      bottomMargin: popup.morphMode ? 6 : (popup.screen && popup.statusbar && popup.statusbar.screen &&
        popup.screen.name === popup.statusbar.screen.name ? popup.statusbar.height : 0)
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

    Rectangle {
      id: bgRoot
      anchors.fill: parent
      color: popup.morphMode ? "transparent" : popup.bgColor
      radius: 10
      topLeftRadius: 10
      topRightRadius: 10
      bottomLeftRadius: 10
      bottomRightRadius: 10
      border.color: popup.morphMode ? "transparent" : popup.borderColor
      border.width: 1
      clip: true
      focus: true

      // ---------------------------------------------------- list view --

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

          Item {
            id: inputBar
            width: parent.width
            height: popup.query.length > 0 ? 50 : 0
            Behavior on height { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
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
              spacing: 12

              Text {
                text: "\uF023"
                color: popup.headColor
                anchors.verticalCenter: parent.verticalCenter
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 500
                font.pixelSize: 17
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
                    height: 22
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
            id: list
            width: parent.width
            height: popup.listHeight()
            clip: true
            flow: GridView.FlowLeftToRight
            cellWidth: width / popup.effCols
            cellHeight: popup.cellH
            model: popup.displayOrder
            highlightMoveDuration: 120

            delegate: Item {
              required property var modelData   // index into filtered
              required property int index
              readonly property var entry: popup.filtered[modelData]
              width: list.cellWidth
              height: list.cellHeight

              Rectangle {
                anchors.fill: parent
                color: modelData === popup.sel ? popup.selColor : "transparent"
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.right: parent.right
                anchors.rightMargin: 8
                text: {
                  if (!entry) return "";
                  const pref = entry.folder
                    ? "<span style=\"color:" + popup.dimColor + ";\">" +
                      Vault.escapeHtml(entry.folder) + "  ›  </span>" : "";
                  const usr = entry.user
                    ? "<span style=\"color:" + popup.dimColor + ";\">" +
                      Vault.escapeHtml(entry.user) + "  ·  </span>" : "";
                  return pref + usr + "<b>" +
                    Vault.highlight(entry.name, popup.query) + "</b>";
                }
                color: index === popup.sel ? popup.entryColor : popup.fgColor
                textFormat: Text.RichText
                elide: Text.ElideRight
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 16
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  popup.sel = index;
                  popup.openActions();
                }
              }
            }
          }

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
                text: popup.filtered.length + " Credentials"
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

      // ------------------------------------------------- actions view --

      Item {
        id: actionsView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "actions" ? 1 : 0
        x: popup.mode === "actions" ? 0 : 24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Item { width: 1; height: 2 }

          Rectangle {
            width: parent.width
            height: 56
            color: "#66282f36"

            Column {
              anchors.centerIn: parent
              spacing: 3

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: popup.activeEntry ? Vault.escapeHtml(popup.activeEntry.name) : ""
                color: popup.fgColor
                font.bold: true
                elide: Text.ElideMiddle
                width: Math.min(implicitWidth + 8, popup.width - 60)
                horizontalAlignment: Text.AlignHCenter
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 700
                font.pixelSize: 17
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: popup.activeEntry && popup.activeEntry.user !== ""
                text: popup.activeEntry ? popup.activeEntry.user : ""
                color: popup.dimColor
                elide: Text.ElideMiddle
                width: Math.min(implicitWidth + 8, popup.width - 80)
                horizontalAlignment: Text.AlignHCenter
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 14
              }
            }
          }

          Item { width: 1; height: 2 }

          Row {
            id: actionButtons
            width: parent.width

            Repeater {
              model: popup.actionTypes

              delegate: Item {
                required property var modelData
                required property int index
                width: actionButtons.width / popup.actionTypes.length
                height: 48

                Rectangle {
                  anchors.fill: parent
                  color: popup.actionSel === index
                    ? popup.selColor : "transparent"
                }

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: popup.actionSel === index
                    ? popup.entryColor : popup.dimColor
                  font.bold: popup.actionSel === index
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.pixelSize: 14
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    popup.actionSel = index;
                    popup.execute(modelData.kind);
                  }
                }
              }
            }
          }

          HintBar { width: parent.width }
        }
      }

      // ---------------------------------------------------- error view --

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

          Item { width: 1; height: 12 }

          Rectangle {
            width: parent.width
            height: 56
            color: popup.errColor

            Text {
              anchors.centerIn: parent
              text: popup.errorMsg
              color: "#000000"
              font.bold: true
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 700
              font.pixelSize: 16
            }
          }

          Item { width: 1; height: 12 }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "press esc to go back"
            color: popup.dimColor
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 14
          }
        }
      }

      // -------------------------------------------------- unlock view --

      Item {
        id: unlockView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "unlock" ? 1 : 0
        x: popup.mode === "unlock" ? 0 : 24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Item { width: 1; height: 12 }

          Rectangle {
            width: parent.width
            height: 52
            color: popup.errColor
            topLeftRadius: 10
            topRightRadius: 10

            Text {
              anchors.centerIn: parent
              text: "vault locked"
              color: "#000000"
              font.bold: true
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 700
              font.pixelSize: 16
            }
          }

          Item { width: 1; height: 10 }

          Item {
            width: parent.width
            height: 44

            Rectangle {
              anchors.fill: parent
              color: unlockPoll.running ? "transparent" : popup.selColor
            }

            Text {
              anchors.centerIn: parent
              text: unlockPoll.running
                ? "waiting for unlock…" : "Unlock — opens passphrase prompt"
              color: unlockPoll.running ? popup.dimColor : popup.entryColor
              font.bold: !unlockPoll.running
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 15
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: unlockPoll.running
                ? Qt.ArrowCursor : Qt.PointingHandCursor
              onClicked: if (!unlockPoll.running) popup.startUnlock()
            }
          }

          HintBar { width: parent.width }

        }
      }

  Keys.onEscapePressed: (event) => {
    event.accepted = true;
    if (popup.mode === "list" && filterInput.text !== "") {
      filterInput.text = "";
    } else if (popup.mode === "list") popup.closePopup();
    else if (popup.mode === "error") popup.openActions();
    else popup.goBack();
  }

  Keys.onPressed: (event) => {
    if (popup.mode === "list") {
      if ((event.key === Qt.Key_S) && (event.modifiers & Qt.AltModifier)) {
        event.accepted = true;
        syncProc.command = ["rbw", "sync"];
        syncProc.running = true;
        return;
      }
      if ((event.key === Qt.Key_L) && (event.modifiers & Qt.AltModifier)) {
        event.accepted = true;
        popup.closePopup();
        popup.detach("rbw lock");
        return;
      }
      if ((event.key === Qt.Key_C) && (event.modifiers & Qt.AltModifier)) {
        event.accepted = true;
        filterInput.text = "";
        return;
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        event.accepted = true;
        popup.openActions();
        return;
      }
      if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
        event.accepted = true;
        popup.moveSel(event.key === Qt.Key_PageUp
          ? -popup.visibleRows * popup.effCols : popup.visibleRows * popup.effCols);
        return;
      }
      if (event.key === Qt.Key_Up) {
        event.accepted = true; popup.moveVert(-1); return;
      }
      if (event.key === Qt.Key_Down) {
        event.accepted = true; popup.moveVert(1); return;
      }
      if (event.key === Qt.Key_Left) {
        event.accepted = true; popup.moveHoriz(-1); return;
      }
      if (event.key === Qt.Key_Right) {
        event.accepted = true; popup.moveHoriz(1); return;
      }
    } else if (event.key === Qt.Key_Backspace &&
               (popup.mode === "actions" || popup.mode === "unlock")) {
      event.accepted = true;
      popup.goBack();
    } else if (popup.mode === "actions") {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        event.accepted = true;
        popup.execute(popup.actionTypes[popup.actionSel].kind);
        return;
      }
      if (event.key === Qt.Key_Left || event.key === Qt.Key_Tab) {
        event.accepted = true;
        popup.actionSel = (popup.actionSel + popup.actionTypes.length - 1) %
          popup.actionTypes.length;
        return;
      }
      if (event.key === Qt.Key_Right) {
        event.accepted = true;
        popup.actionSel = (popup.actionSel + 1) % popup.actionTypes.length;
        return;
      }
    } else if (popup.mode === "error") {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter ||
          event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace) {
        event.accepted = true;
        popup.openActions();
        return;
      }
    }
  }
    }
  }

  // -------------------------------------------------------- helpers --

  function listHeight() {
    if (popup.filtered.length === 0) return 0;
    const needed = Math.ceil(popup.filtered.length / popup.effCols);
    return Math.max(1, Math.min(needed, popup.visibleRows)) * popup.cellH;
  }

  function calcHeight() {
    if (popup.mode === "list")
      return (popup.query.length > 0 ? 50 : 0) + (popup.filtered.length === 0 ? 40 : popup.listHeight()) + 58;
    if (popup.mode === "actions")
      return 2 + 56 + 2 + 48 + 26;
    if (popup.mode === "error")
      return 12 + 56 + 12 + 24;
    return 12 + 52 + 10 + 44 + 26;
  }

  // column-major display: down = next credential, right = next column
  function moveVert(delta) {
    moveSel(delta);
  }

  function moveHoriz(delta) {
    popup.moveSel(delta * popup.effCols);
  }

  function moveSel(delta) {
    const len = popup.filtered.length;
    if (len === 0) return;
    popup.sel = ((popup.sel + delta) % len + len) % len;
    Qt.callLater(() => list.positionViewAtIndex(popup.sel, GridView.Contain));
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
}
