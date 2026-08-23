// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "ideo.js" as Ideo

PanelWindow {
  id: popup

  WlrLayershell.layer: WlrLayer.Overlay

  property bool shown: false
  property bool morphMode: false
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
  // content trails the box: it only appears once the pill has real size, and
  // clears well before the pill has finished collapsing
  readonly property real contentFade: popup.morphMode
    ? Math.max(0, Math.min(1, (popup.showFactor - 0.35) / 0.65))
    : popup.showFactor

  property var statusbar: null

  readonly property color bgColor: "#cc000000"
  readonly property color borderColor: "#20242a"
  readonly property color fgColor: "#DFDFDD"
  readonly property color headColor: "#9bbfbf"
  readonly property color keyColor: "#a2a8bc"
  readonly property color dimColor: "#6a707f"
  readonly property color entryColor: "#eebebe"
  readonly property color errColor: "#e78284"

  // mode: emoji · nerd
  property var memo: ({})             // per-mode { entries, filtered, query, sel }
  property string appMode: "emoji"
  property string query: ""
  property var entries: []
  property var filtered: []
  property int sel: 0
  property bool nerdLoading: false
  property bool nerdFailed: false

  // nerd format strip state
  property bool formatMode: false
  property int formatSel: 0
  readonly property var formats: ["icon", "class", "utf"]

  property string pickedChar: ""

  visible: popup.showFactor > 0.01
  color: "transparent"

  anchors { left: true; right: true; top: true; bottom: true }
  focusable: true
  exclusionMode: ExclusionMode.Ignore

  NumberAnimation {
    id: openAnim
    target: popup; property: "showFactor"
    to: 1; duration: 200; easing.type: Easing.OutCubic
  }

  NumberAnimation {
    id: closeAnim
    target: popup; property: "showFactor"
    to: 0; duration: 200; easing.type: Easing.OutCubic
    onFinished: popup.shown = false
  }

  HyprlandFocusGrab {
    id: grab
    windows: [ popup ]
    active: popup.shown
    onCleared: popup.closePopup()
  }

  IpcHandler {
    target: "Ideo"

    function toggle() { popup.openPopup("emoji"); }

    function emoji() { popup.openPopup("emoji"); }

    function nerd() { popup.openPopup("nerd"); }
  }

  // ------------------------------------------------------------- procs --

  Process {
    id: emojiProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: popup.onEmojiFile(text)
    }
  }

  function onEmojiFile(text) {
    popup.entries = Ideo.parseEmojiTest(text);
    popup.applyFilter();
  }

  function fetchNerds() {
    popup.nerdLoading = true;
    popup.nerdFailed = false;
    const xhr = new XMLHttpRequest();
    xhr.open("GET", "https://www.nerdfonts.com/assets/css/webfont.css");
    xhr.onreadystatechange = () => {
      if (xhr.readyState !== XMLHttpRequest.DONE) return;
      popup.nerdLoading = false;
      if (xhr.status !== 200 || !xhr.responseText) {
        popup.nerdFailed = true;
        return;
      }
      popup.entries = Ideo.parseNerdCss(xhr.responseText);
      popup.applyFilter();
    };
    xhr.send();
  }

  // ---------------------------------------------------------- actions --

  function typeChar(ch) {
    popup.closePopup();
    popup.detach("sleep 0.25 && wtype " + Ideo.shellQuote(ch));
  }

  function copyText(t) {
    popup.closePopup();
    popup.detach("sleep 0.25 && printf '%s' " + Ideo.shellQuote(t) +
      " | wl-copy >/dev/null 2>&1");
  }

  function copyFormat() {
    const e = currentRow();
    if (!e) return;
    const f = popup.formats[popup.formatSel];
    if (f === "icon") popup.copyText(e.char);
    else if (f === "class") popup.copyText(e.cls);
    else popup.copyText("U+" + e.code.toUpperCase());
  }

  function detach(script) {
    if (script) Quickshell.execDetached(["bash", "-c", script]);
  }

  // ------------------------------------------------------------- open --

  function openPopup(mode) {
    // when already shown (tab-switch) we must NOT touch showFactor — a
    // single invisible frame drops the layer surface, clears the focus
    // grab, and the grab's onCleared closes us. no open animation either:
    // the swap should be invisible, just content changing under the cursor
    const cold = !popup.shown;

    if (cold) {
      popup.shown = true;
      popup.collapsing = false;
      closeAnim.stop();
      popup.showFactor = 0;
      openAnim.restart();
      popup.memo = {};               // a fresh open retains nothing
    } else {
      // park the outgoing mode exactly where the user left it
      popup.memo[popup.appMode] = {
        entries: popup.entries,
        filtered: popup.filtered,
        query: popup.query,
        sel: popup.sel,
      };
    }

    popup.appMode = mode || "emoji";
    popup.formatMode = false;
    popup.formatSel = 0;

    const memo = popup.memo[popup.appMode];
    if (!cold && memo && memo.entries.length > 0) {
      // seen before: restore instantly, no reload flicker
      popup.entries = memo.entries;
      popup.filtered = memo.filtered;
      popup.sel = Math.min(memo.sel, Math.max(0, memo.filtered.length - 1));
      popup.query = memo.query;
    } else {
      popup.entries = [];
      popup.filtered = [];
      popup.sel = 0;
      popup.query = "";
      if (popup.appMode === "emoji") {
        emojiProc.command = ["cat", "/usr/share/unicode/emoji/emoji-test.txt"];
        emojiProc.running = true;
      } else {
        popup.fetchNerds();
      }
    }

    filterInput.text = popup.query;
    popup.applyFilter();

    if (cold) {
      focusRetry.counter = 0;
      focusRetry.restart();
    }
    popup.syncFocus();
  }

  function closePopup() {
    popup.collapsing = true;
    openAnim.stop();
    closeAnim.restart();
  }

  property real lastTab: 0

  function toggleMode() {
    const now = Date.now();
    if (now - popup.lastTab < 80) return;   // same chord delivered twice
    popup.lastTab = now;
    popup.openPopup(popup.appMode === "emoji" ? "nerd" : "emoji");
  }

  function syncFocus() {
    Qt.callLater(() => {
      if (!popup.shown) return;
      filterInput.forceActiveFocus();
    });
  }

  // ------------------------------------------------------ list logic --

  function applyFilter() {
    popup.filtered = Ideo.filterEntries(popup.entries, popup.query);
    const len = popup.filtered.length;
    if (popup.sel >= len) popup.sel = len > 0 ? len - 1 : 0;
    Qt.callLater(() => grid.positionViewAtIndex(popup.sel, ListView.Contain));
  }

  function cols() {
    return Math.max(1, Math.floor(grid.width /
      (popup.appMode === "emoji" ? 52 : 62)));
  }

  function currentRow() {
    return popup.filtered[popup.sel] || null;
  }

  function activateCurrent(copyOnly) {
    const e = currentRow();
    if (!e) return;
    if (popup.appMode === "emoji") {
      if (copyOnly) popup.copyText(e.char);
      else popup.copyPaste(e.char);
    } else {
      if (copyOnly) { popup.copyText(e.char); return; }
      popup.pickedChar = e.char;
      popup.formatMode = true;
      popup.formatSel = 0;
    }
  }

  // clipboard always; keystrokes land in whatever held focus before us
  function copyPaste(ch) {
    popup.closePopup();
    popup.detach("sleep 0.25 && printf '%s' " + Ideo.shellQuote(ch) +
      " | wl-copy >/dev/null 2>&1 && sleep 0.15 && wtype " + Ideo.shellQuote(ch));
  }

  // grid clicks copy only — typing is a keyboard decision

  function moveSel(delta) {
    const len = popup.filtered.length;
    if (len === 0) return;
    popup.sel = ((popup.sel + delta) % len + len) % len;
    Qt.callLater(() => grid.positionViewAtIndex(popup.sel, ListView.Contain));
  }

  function moveVert(delta) {
    const c = cols();
    moveSel(delta * c);
  }

  function moveHoriz(delta) {
    moveSel(delta);
  }

  // ---------------------------------------------------------- hints --

  function hints() {
    if (popup.formatMode)
      return [["left/right", "choose"], ["return", "copy"], ["esc", "back"]];
    if (popup.appMode === "emoji")
      return [["return", "copy · paste"], ["backspace", "clear"],
              ["tab", "nerd"]];
    return [["return", "pick format"], ["backspace", "clear"],
            ["tab", "emoji"]];
  }

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
            Ideo.escapeHtml(modelData[0]) + "</span></b> <b><span style=\"color:" +
            popup.dimColor + ";\">" + Ideo.escapeHtml(modelData[1]) + "</span></b>"
          textFormat: Text.RichText
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 13
        }
      }
    }
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
    // 220ms matches the pill's own height easing in shell.qml
    Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
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

      Column {
        anchors.fill: parent

        // ----------------------------------------------- input bar --
        Item {
          id: inputBar
          width: parent.width
          height: popup.query.length > 0 ? 50 : 0
          Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
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

            Rectangle {
              width: modeLabel.width + 16
              height: parent.height
              color: "transparent"

              Text {
                id: modeLabel
                anchors.centerIn: parent
                text: popup.appMode === "emoji" ? "EMOJI" : "NERD"
                color: popup.headColor
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 700
                font.pixelSize: 13
              }
            }

            Item {
              width: parent.width - modeLabel.width - 60
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

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: (event) => {
                  if (event.key === Qt.Key_Backspace && popup.formatMode) {
                    event.accepted = true;
                    popup.formatMode = false;
                    popup.syncFocus();
                  } else if (event.key === Qt.Key_Tab) {
                    event.accepted = true;
                    popup.toggleMode();
                  }
                }

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

        // ---------------------------------------------------- grid --
        Item {
          width: parent.width
          height: popup.gridHeight()

          Text {
            anchors.centerIn: parent
            visible: popup.shown && popup.filtered.length === 0 &&
                     (popup.appMode !== "nerd" || !popup.nerdLoading)
            text: popup.nerdFailed && popup.appMode === "nerd"
              ? "failed to fetch icons from nerdfonts.com"
              : popup.appMode === "nerd" && popup.nerdLoading
                ? "fetching icons…"
                : "No matches found"
            color: popup.nerdFailed && popup.appMode === "nerd"
              ? popup.errColor : popup.dimColor
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: 600
            font.pixelSize: 15
          }

          GridView {
            id: grid
            anchors.fill: parent
            clip: true
            flow: GridView.FlowLeftToRight
            cellWidth: popup.appMode === "emoji" ? 52 : 62
            cellHeight: popup.appMode === "emoji" ? 46 : 50
            model: popup.filtered
            highlightMoveDuration: 120

            delegate: Item {
              required property var modelData
              required property int index
              width: grid.cellWidth
              height: grid.cellHeight

              Rectangle {
                anchors.fill: parent
                anchors.margins: 2
                radius: 6
                color: index === popup.sel ? "#4de78284" : "transparent"
              }

              Text {
                anchors.centerIn: parent
                text: modelData.char
                color: popup.fgColor
                font.family: popup.appMode === "emoji"
                  ? "Noto Color Emoji" : "Symbols Nerd Font"
                font.pixelSize: popup.appMode === "emoji" ? 28 : 30
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  popup.sel = index;
                  popup.activateCurrent(true);
                }
              }
            }
          }
        }

        // -------------------------------------------- message strip --
        Rectangle {
          width: parent.width
          height: popup.formatMode ? 26 : 54
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
            topPadding: popup.formatMode ? 0 : 6
            bottomPadding: popup.formatMode ? 0 : 6
            spacing: -2

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: !popup.formatMode
              text: {
                if (popup.appMode === "nerd")
                  return popup.nerdLoading ? "loading…" :
                    popup.filtered.length + " Icons";
                return popup.filtered.length + " Emojis";
              }
              color: popup.headColor
              font.bold: true
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 600
              font.pixelSize: 15
            }

            HintBar {
              width: parent.width
              visible: !popup.formatMode
            }

            Row {
              id: formatRow
              width: parent.width
              visible: popup.formatMode

              Repeater {
                model: ["Icon", "Class", "UTF"]

                delegate: Item {
                  required property var modelData
                  required property int index
                  width: formatRow.width / 3
                  height: 26

                  Rectangle {
                    anchors.fill: parent
                    color: popup.formatSel === index
                      ? "#4de78284" : "transparent"
                  }

                  Text {
                    anchors.centerIn: parent
                    text: modelData
                    color: popup.formatSel === index
                      ? popup.entryColor : popup.dimColor
                    font.bold: popup.formatSel === index
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 14
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      popup.formatSel = index;
                      popup.copyFormat();
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

      Keys.onEscapePressed: (event) => {
      event.accepted = true;
      if (popup.formatMode) {
        popup.formatMode = false;
        popup.syncFocus();
      } else if (filterInput.text !== "") {
        filterInput.text = "";
      } else {
        popup.closePopup();
      }
    }

    Keys.onPressed: (event) => {
      if ((event.key === Qt.Key_C) && (event.modifiers & Qt.AltModifier)) {
        event.accepted = true;
        filterInput.text = "";
        return;
      }
      if (event.key === Qt.Key_Tab) {
        event.accepted = true;
        popup.toggleMode();
        return;
      }

      if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
        event.accepted = true;
        const page = cols() * (popup.appMode === "emoji" ? 7 : 6);
        popup.moveSel(event.key === Qt.Key_PageUp ? -page : page);
        return;
      }
      if (event.key === Qt.Key_Up) { event.accepted = true; popup.moveVert(-1); return; }
      if (event.key === Qt.Key_Down) { event.accepted = true; popup.moveVert(1); return; }
      if (event.key === Qt.Key_Left) {
        event.accepted = true;
        if (popup.formatMode) {
          popup.formatSel = (popup.formatSel + 2) % 3;
        } else popup.moveHoriz(-1);
        return;
      }
      if (event.key === Qt.Key_Right) {
        event.accepted = true;
        if (popup.formatMode) {
          popup.formatSel = (popup.formatSel + 1) % 3;
        } else popup.moveHoriz(1);
        return;
      }

      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        event.accepted = true;
        if (popup.formatMode) {
          popup.copyFormat();
          return;
        }
        if (event.modifiers & Qt.ShiftModifier) return;   // reserved
        popup.activateCurrent(false);
        return;
      }
      if (event.key === Qt.Key_Backspace && popup.formatMode) {
        event.accepted = true;
        popup.formatMode = false;
        return;
      }

    }
  }

  // -------------------------------------------------------- helpers --

  function gridHeight() {
    const rows = Math.ceil(popup.filtered.length / cols());
    const maxRows = popup.appMode === "emoji" ? 7 : 6;
    return Math.max(1, Math.min(rows, maxRows)) *
      (popup.appMode === "emoji" ? 46 : 50);
  }

  function calcHeight() {
    return (popup.query.length > 0 ? 50 : 0) +
      popup.gridHeight() + (popup.formatMode ? 26 : 54);
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
      if (filterInput.activeFocus) stop();
      if (focusRetry.counter++ > 12) stop();
    }
    property int counter: 0
  }
}
