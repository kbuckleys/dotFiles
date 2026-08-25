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
import "calc.js" as Calc
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
  readonly property color headColor: "#9fcbfc"
  readonly property color keyColor: "#a2a8bc"
  readonly property color dimColor: "#6a707f"
  readonly property color entryColor: "#eebebe"
  readonly property color errColor: "#e78284"

  property string query: ""
  property int seq: 0

  // what's currently displayed
  property string shownExpr: ""
  property string shownResult: ""
  property bool fromHistory: false

  // session history of {expr, result}, newest first
  property var history: []
  property int histIdx: -1            // -1 = live input

  component HintBar: Item {
    id: hintBarRoot
    height: 20
    property var rows: [
      ["return", "copy · paste"], ["esc", "clear · close"], ["↑↓", "history"]
    ]
    Row {
      anchors.centerIn: parent
      spacing: 20
      Repeater {
        model: hintBarRoot.rows
        Text {
          required property var modelData
          text: "<b><span style=\"color:" + popup.keyColor + ";\">" +
            Calc.escapeHtml(modelData[0]) + "</span></b> <b><span style=\"color:" +
            popup.dimColor + ";\">" + Calc.escapeHtml(modelData[1]) + "</span></b>"
          textFormat: Text.RichText
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 13
        }
      }
    }
  }

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
    target: "Adder"

    function toggle() { popup.toggle(); }
  }

  // ------------------------------------------------------------- procs --

  Process {
    id: calcProc
    property int runSeq: 0

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (calcProc.runSeq !== popup.seq) return;
        const out = text.trim();
        if (out === "") return;
        popup.shownExpr = popup.query.trim();
        popup.shownResult = out;
        popup.fromHistory = false;
        popup.pushHistory(popup.shownExpr, out);
      }
    }
  }

  function pushHistory(expr, result) {
    if (!expr || !result) return;
    const h = popup.history.filter((x) => x.expr !== expr || x.result !== result);
    h.unshift({ expr: expr, result: result });
    popup.history = h.slice(0, 30);
  }

  function detach(script) {
    if (script) Quickshell.execDetached(["bash", "-c", script]);
  }

  // ------------------------------------------------------------- open --

  function openPopup() {
    popup.shown = true;
    popup.collapsing = false;
    popup.query = "";
    filterInput.text = "";
    popup.seq++;
    popup.shownExpr = "";
    popup.shownResult = "";
    popup.histIdx = -1;

    focusRetry.counter = 0;
    focusRetry.restart();
    closeAnim.stop();
    popup.showFactor = 0;
    openAnim.restart();
    popup.syncFocus();

    popup.detach("qalc --exrates >/dev/null 2>&1");
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

  function setQuery(q) {
    filterInput.text = q;
    popup.query = q;
    debounce.restart();
  }

  function syncFocus() {
    Qt.callLater(() => {
      if (!popup.shown) return;
      filterInput.forceActiveFocus();
    });
  }

  // -------------------------------------------------------- evaluate --

  Timer {
    id: debounce
    interval: 150
    onTriggered: popup.evaluate()
  }

  function evaluate() {
    const q = popup.query.trim();
    if (!q) {
      popup.seq++;
      popup.shownExpr = "";
      popup.shownResult = "";
      return;
    }
    const s = ++popup.seq;
    calcProc.runSeq = s;
    calcProc.command = ["qalc", "--terse", q];
    calcProc.running = true;
  }

  // ---------------------------------------------------------- history --

  function histStep(delta) {
    if (popup.history.length === 0) return;
    let idx = popup.histIdx + delta;
    if (idx < -1) idx = popup.history.length - 1;
    if (idx >= popup.history.length) idx = -1;
    popup.histIdx = idx;
    if (idx === -1) {
      popup.shownExpr = popup.query.trim();
      popup.shownResult = "";
      filterInput.forceActiveFocus();
    } else {
      popup.shownExpr = popup.history[idx].expr;
      popup.shownResult = popup.history[idx].result;
    }
  }

  // ---------------------------------------------------------- actions --

  function copyShown() {
    if (!popup.shownResult) return;
    popup.closePopup();
    popup.detach("sleep 0.25 && printf '%s' " +
      Calc.shellQuote(popup.shownResult) + " | wl-copy >/dev/null 2>&1");
  }

  function copyPasteShown() {
    if (!popup.shownResult) return;
    popup.closePopup();
    popup.detach("sleep 0.25 && printf '%s' " + Calc.shellQuote(popup.shownResult) +
      " | wl-copy >/dev/null 2>&1 && sleep 0.15 && wtype " +
      Calc.shellQuote(popup.shownResult));
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
    width: 600
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

      Keys.onEscapePressed: (event) => {
        event.accepted = true;
        if (filterInput.text !== "") {
          filterInput.clear();
          popup.query = "";
        } else {
          popup.closePopup();
        }
      }

      Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          event.accepted = true;
          popup.copyPasteShown();
          return;
        }
        if (event.key === Qt.Key_Up) {
          event.accepted = true;
          popup.histStep(1);
          return;
        }
        if (event.key === Qt.Key_Down) {
          event.accepted = true;
          popup.histStep(-1);
          return;
        }
      }

      Column {
        anchors.fill: parent

        // -------------------------------------------------- input --
        Item {
          width: parent.width
          height: 46

          Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: popup.borderColor
          }

          Row {
            anchors.fill: parent
            leftPadding: 16
            spacing: 12

            Text {
              text: "\uDB80\uDCEC"
              color: popup.headColor
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
                color: popup.headColor
                selectionColor: popup.headColor
                selectedTextColor: "#000000"
                // 14-segment, not the clock's 7: what you type here has
                // operators in it, and DSEG7 contains none of them
                font.family: Zenon.segmentFamily
                font.weight: Font.Bold
                font.pixelSize: 20
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
                  height: 24
                  radius: 1
                  color: popup.headColor
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
                  popup.histIdx = -1;
                  debounce.restart();
                }
              }

            }
          }
        }

        // ------------------------------------------------- result --
        Item {
          width: parent.width
          height: popup.query.trim().length > 0 ? 66 : 0
          Behavior on height { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
          clip: true

          Column {
            anchors.centerIn: parent
            spacing: 3

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: popup.shownExpr.length > 0
              text: (popup.fromHistory ? "↺ " : "") + popup.shownExpr + "  ="
              color: popup.dimColor
              // an expression too, so 14-segment like the input above it
              font.family: Zenon.segmentFamily
              font.weight: Font.Bold
              font.pixelSize: 14
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: popup.shownResult.length > 0
              text: popup.shownResult
              color: popup.headColor
              elide: Text.ElideMiddle
              width: Math.min(implicitWidth + 8, popup.width - 40)
              horizontalAlignment: Text.AlignHCenter
              // the answer is a bare number, so it gets the clock's own face
              font.family: Zenon.clockFamily
              font.weight: Font.Bold
              font.pixelSize: 26
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: popup.shownResult.length === 0 && popup.query.trim().length > 0
              text: "…"
              color: popup.dimColor
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 16
            }
          }
        }

        // --------------------------------------------- hint strip --
        Rectangle {
          width: parent.width
          height: 34
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
            anchors.centerIn: parent
          }
        }
      }
    }
    }

  // -------------------------------------------------------- helpers --

  function calcHeight() {
    return 46 + (popup.query.trim().length > 0 ? 66 : 0) + 34;
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
