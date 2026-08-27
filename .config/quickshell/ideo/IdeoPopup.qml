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
import "ideo.js" as Ideo
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

  // Parsed once per shell session, not once per open. Neither set changes
  // underneath us, and re-reading 670KB of emoji-test.txt — then running a
  // regex over every one of its lines — stalled the UI thread in the middle
  // of the morph. That stall was the jerk in this layer's entrance.
  property var emojiCache: []
  property var nerdCache: []

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
    popup.emojiCache = Ideo.parseEmojiTest(text);
    // the user can tab to the other mode while this is in flight; the result
    // still belongs in the cache, but it must not overwrite what is on screen
    if (popup.appMode !== "emoji") return;
    popup.entries = popup.emojiCache;
    popup.applyFilter();
  }

  Timer {
    id: loadDeferred
    // just past the morph. A first parse still has to happen somewhere, but
    // not while the pill is mid-animation into this layer's shape.
    interval: Zenon.slow + 40
    onTriggered: {
      if (popup.appMode === "emoji") {
        emojiProc.command = ["cat", "/usr/share/unicode/emoji/emoji-test.txt"];
        emojiProc.running = true;
      } else {
        popup.fetchNerds();
      }
    }
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
      popup.nerdCache = Ideo.parseNerdCss(xhr.responseText);
      if (popup.appMode !== "nerd") return;
      popup.entries = popup.nerdCache;
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
      const cache = popup.appMode === "emoji" ? popup.emojiCache : popup.nerdCache;
      popup.entries = cache;
      popup.filtered = [];
      popup.sel = 0;
      popup.query = "";
      if (cache.length === 0) loadDeferred.restart();
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
      return [["return", "copy · paste"], ["esc", "clear · close"],
              ["tab", "nerd"]];
    return [["return", "pick format"], ["esc", "clear · close"],
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

      Column {
        anchors.fill: parent

        // ----------------------------------------------- input bar --
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
    const maxRows = popup.appMode === "emoji" ? 7 : 6;
    const rowH = popup.appMode === "emoji" ? 46 : 50;
    // Nothing loaded yet is not the same as nothing to show. Measured as one
    // row, the pill morphed to a 100px sliver and then snapped to full height
    // the instant the set landed; reserving the full grid means it opens once,
    // at the size it is going to keep.
    if (popup.entries.length === 0) return maxRows * rowH;
    const rows = Math.ceil(popup.filtered.length / cols());
    return Math.max(1, Math.min(rows, maxRows)) * rowH;
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
