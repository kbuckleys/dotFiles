// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// CHRONOS — what the clock opens into. A calendar you can actually walk
// through, and the pomodoro timers beside it. The bar's clock keeps a
// one-line tooltip for "what is today"; this is for everything else.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import "../morpheus"
import "chronos.js" as Chr

PanelWindow {
  id: popup

  WlrLayershell.layer: WlrLayer.Overlay

  property bool shown: false
  property bool morphMode: false
  property real morphFade: 1
  property real showFactor: 0
  property bool collapsing: false
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
  readonly property color msgColor: "#66282f36"
  readonly property color msgBorder: "#4d45505c"
  readonly property color headColor: "#9bbfbf"
  readonly property color keyColor: "#a2a8bc"
  readonly property color dimColor: "#6a707f"
  readonly property color entryColor: "#eebebe"

  // ── what the calendar is showing ─────────────────────────────────────
  // A cursor into the months, not a Date: paging by month on a Date lands on
  // the 31st of a 30-day month and silently skips one.
  property int viewYear: 2026
  property int viewMonth: 0
  property var today: new Date()

  // "calendar" | "timers" — which half the keyboard is driving
  property string pane: "calendar"
  property int timerSel: 0

  // typing a name for a timer that does not exist yet
  property bool naming: false

  function startNaming() {
    popup.pane = "timers";
    popup.naming = true;
    nameInput.text = "";
    Qt.callLater(() => { if (popup.naming) nameInput.forceActiveFocus(); });
  }

  function commitName() {
    const label = nameInput.text.trim();
    popup.naming = false;
    // an empty name still makes a timer; it just gets the generic one
    Chronos.add(label, 0);
    popup.timerSel = Chronos.timers.length - 1;
    bgRoot.forceActiveFocus();
  }

  function cancelName() {
    popup.naming = false;
    bgRoot.forceActiveFocus();
  }

  readonly property var cells: Chr.monthCells(popup.viewYear, popup.viewMonth)
  // Deliberately not named with an "on" + capital prefix: QML reads that
  // shape as a signal handler, and the binding never resolves — the same
  // class of trap that `id: state` was in cerberus.
  readonly property bool showsToday: popup.today.getFullYear() === popup.viewYear
    && popup.today.getMonth() === popup.viewMonth

  function goToday() {
    popup.today = new Date();
    popup.viewYear = popup.today.getFullYear();
    popup.viewMonth = popup.today.getMonth();
  }

  function stepMonth(d) {
    let m = popup.viewMonth + d;
    let y = popup.viewYear;
    while (m < 0) { m += 12; y -= 1; }
    while (m > 11) { m -= 12; y += 1; }
    popup.viewMonth = m;
    popup.viewYear = y;
  }

  function stepYear(d) { popup.viewYear += d; }

  function clampTimerSel() {
    const n = Chronos.timers.length;
    popup.timerSel = n === 0 ? 0 : Math.max(0, Math.min(popup.timerSel, n - 1));
  }

  // ── geometry ─────────────────────────────────────────────────────────
  readonly property int cellW: 46
  readonly property int cellH: 34
  // Both halves are the calendar's natural width — the grid decides how wide
  // this layer is, and the timers match it. The panel is then only as wide as
  // it needs to be rather than stretched to the usual 1000.
  readonly property int paneW: popup.cellW * 7 + 28
  readonly property int sideMargin: 22
  readonly property int splitGap: 18
  readonly property int panelWidth:
    popup.sideMargin * 2 + popup.paneW * 2 + popup.splitGap * 2 + 1

  // hints only — the date is already the largest thing on the left
  function stripHeight() { return 42; }

  // Tall enough for the calendar's six rows whatever the timer list is doing,
  // and grown by the list once that is the taller of the two.
  function bodyHeight() {
    const rows = Chronos.timers.length + (popup.naming ? 1 : 0);
    return Math.max(300, 90 + rows * 46);
  }
  function calcHeight() { return popup.bodyHeight() + popup.stripHeight(); }

  function hints() {
    if (popup.naming)
      return [["type", "name"], ["return", "create"], ["esc", "cancel"]];
    if (popup.pane === "timers")
      return [["space", "start · pause"], ["r", "reset"], ["±", "minutes"],
              ["n / d", "new · delete"], ["tab", "calendar"], ["esc", "close"]];
    return [["← →", "month"], ["↑ ↓", "year"], ["t", "today"],
            ["tab", "timers"], ["esc", "close"]];
  }

  component HintBar: Item {
    id: hintBarRoot
    height: 30
    property var rows: popup.hints()
    Row {
      anchors.centerIn: parent
      spacing: 20
      Repeater {
        model: hintBarRoot.rows
        Text {
          required property var modelData
          text: "<b><span style=\"color:" + popup.keyColor + ";\">" +
            Chr.escapeHtml(modelData[0]) + "</span></b> <span style=\"color:" +
            popup.dimColor + ";\">" + Chr.escapeHtml(modelData[1]) + "</span>"
          textFormat: Text.RichText
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 15
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
    target: "Chronos"

    function toggle() { popup.toggle(); }

    // Start a fresh timer of N minutes without opening anything — the form a
    // keybind wants. 0 means the default length.
    function pomodoro(minutes: int): string {
      const m = minutes > 0 ? minutes : Chronos.defaultMinutes;
      Chronos.add("Pomodoro", m);
      Chronos.toggle(Chronos.timers.length - 1);
      return "started " + m + "m";
    }

    // stop everything that is counting, without deleting anything
    function halt(): string {
      for (let i = 0; i < Chronos.timers.length; ++i)
        if (Chronos.timers[i].running) Chronos.toggle(i);
      return "halted";
    }

    function status(): string {
      let s = "shown=" + popup.shown + " pane=" + popup.pane
        + " sel=" + popup.timerSel + " naming=" + popup.naming
        + " view=" + popup.viewYear + "-" + (popup.viewMonth + 1)
        + " timers=" + Chronos.timers.length;
      for (let i = 0; i < Chronos.timers.length; ++i) {
        const t = Chronos.timers[i];
        s += " [" + t.label + " " + t.minutes + "m run=" + t.running
          + " left=" + t.remaining + "]";
      }
      return s;
    }
  }

  function openPopup() {
    popup.shown = true;
    popup.collapsing = false;
    popup.pane = "calendar";
    popup.goToday();
    popup.clampTimerSel();
    closeAnim.stop();
    popup.showFactor = 0;
    openAnim.restart();
    Qt.callLater(() => { if (popup.shown) bgRoot.forceActiveFocus(); });
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

  MouseArea {
    anchors.fill: parent
    z: 0
    onClicked: popup.closePopup()
  }

  Item {
    id: panel
    width: popup.panelWidth
    height: popup.calcHeight()
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
      cornerRadius: 10
      morphed: popup.morphMode
    }

    ClippingRectangle {
      id: bgRoot
      anchors.fill: parent
      // Grown by its own border: a ClippingRectangle insets its children by
      // border.width on every side, so the content box came out 2px smaller
      // than the panel and any layout measured against the panel's size fell
      // one row or one column short. This hands the content its full box back.
      anchors.margins: -bgRoot.border.width
      color: popup.morphMode ? "transparent" : popup.bgColor
      radius: 10
      border.color: popup.morphMode ? "transparent" : popup.borderColor
      border.width: 1
      focus: true

      Keys.onEscapePressed: (event) => {
        event.accepted = true;
        popup.closePopup();
      }

      Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          event.accepted = true;
          popup.pane = popup.pane === "calendar" ? "timers" : "calendar";
          return;
        }

        if (popup.pane === "timers") {
          const n = Chronos.timers.length;
          if (event.key === Qt.Key_Up) {
            event.accepted = true;
            if (n > 0) popup.timerSel = (popup.timerSel + n - 1) % n;
          } else if (event.key === Qt.Key_Down) {
            event.accepted = true;
            if (n > 0) popup.timerSel = (popup.timerSel + 1) % n;
          } else if (event.key === Qt.Key_Space
                     || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            event.accepted = true;
            Chronos.toggle(popup.timerSel);
          } else if (event.key === Qt.Key_R) {
            event.accepted = true;
            Chronos.reset(popup.timerSel);
          } else if (event.key === Qt.Key_N) {
            event.accepted = true;
            popup.startNaming();
          } else if (event.key === Qt.Key_D) {
            event.accepted = true;
            Chronos.remove(popup.timerSel);
            popup.clampTimerSel();
          } else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal
                     || event.key === Qt.Key_Right) {
            event.accepted = true;
            Chronos.bump(popup.timerSel, event.modifiers & Qt.ShiftModifier ? 5 : 1);
          } else if (event.key === Qt.Key_Minus || event.key === Qt.Key_Left) {
            event.accepted = true;
            Chronos.bump(popup.timerSel, event.modifiers & Qt.ShiftModifier ? -5 : -1);
          }
          return;
        }

        if (event.key === Qt.Key_Left) {
          event.accepted = true; popup.stepMonth(-1);
        } else if (event.key === Qt.Key_Right) {
          event.accepted = true; popup.stepMonth(1);
        } else if (event.key === Qt.Key_Up) {
          event.accepted = true; popup.stepYear(-1);
        } else if (event.key === Qt.Key_Down) {
          event.accepted = true; popup.stepYear(1);
        } else if (event.key === Qt.Key_PageUp) {
          event.accepted = true; popup.stepYear(-1);
        } else if (event.key === Qt.Key_PageDown) {
          event.accepted = true; popup.stepYear(1);
        } else if (event.key === Qt.Key_T || event.key === Qt.Key_Home) {
          event.accepted = true; popup.goToday();
        }
      }

      Column {
        anchors.fill: parent

        Item {
          width: parent.width
          height: popup.bodyHeight()

          // ── the calendar ─────────────────────────────────────────
          Item {
            id: calPane
            width: popup.paneW
            height: parent.height
            anchors.left: parent.left
            anchors.leftMargin: popup.sideMargin

            Column {
              anchors.centerIn: parent
              spacing: 8

              Row {
                width: popup.cellW * 7
                height: 30

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: popup.cellW * 7
                  text: Chr.monthName(popup.viewMonth) + "  " + popup.viewYear
                  color: popup.pane === "calendar" ? popup.headColor : popup.dimColor
                  Behavior on color { ColorAnimation { duration: Zenon.normal } }
                  horizontalAlignment: Text.AlignHCenter
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.weight: Font.Bold
                  font.pixelSize: 18
                }
              }

              Row {
                Repeater {
                  model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
                  delegate: Text {
                    required property string modelData
                    required property int index
                    width: popup.cellW
                    height: 20
                    text: modelData
                    color: index >= 5 ? popup.dimColor : Zenon.dim
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.weight: Font.Bold
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                  }
                }
              }

              Grid {
                columns: 7
                columnSpacing: 0
                rowSpacing: 0

                Repeater {
                  model: popup.cells

                  delegate: Item {
                    id: dayCell
                    required property int modelData
                    required property int index
                    width: popup.cellW
                    height: popup.cellH

                    readonly property bool isToday: popup.showsToday
                      && dayCell.modelData === popup.today.getDate()

                    Rectangle {
                      anchors.centerIn: parent
                      width: popup.cellW - 6
                      height: popup.cellH - 4
                      radius: 5
                      visible: dayCell.isToday
                      color: Zenon.cyan
                    }

                    Text {
                      anchors.centerIn: parent
                      text: dayCell.modelData === 0 ? "" : String(dayCell.modelData)
                      color: dayCell.isToday ? "#000000"
                        : (dayCell.index % 7 >= 5 ? popup.dimColor : Zenon.white)
                      font.family: "JetBrainsMono Nerd Font Propo"
                      font.weight: dayCell.isToday ? Font.Black : Font.Bold
                      font.pixelSize: 15
                    }
                  }
                }
              }
            }
          }

          Rectangle {
            anchors.left: calPane.right
            anchors.leftMargin: popup.splitGap
            anchors.verticalCenter: parent.verticalCenter
            width: 1
            height: parent.height - 48
            color: popup.msgBorder
          }

          // ── the timers ───────────────────────────────────────────
          Item {
            anchors.left: calPane.right
            anchors.leftMargin: popup.splitGap * 2 + 1
            width: popup.paneW
            height: parent.height

            Column {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              spacing: 6

              Text {
                text: "Pomodoro"
                color: popup.pane === "timers" ? popup.headColor : popup.dimColor
                Behavior on color { ColorAnimation { duration: Zenon.normal } }
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: Font.Bold
                font.pixelSize: 18
                bottomPadding: 6
              }

              Text {
                visible: Chronos.timers.length === 0
                text: "no timers — n to add one"
                color: popup.dimColor
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 15
              }

              Repeater {
                model: Chronos.timers

                delegate: Rectangle {
                  id: timerRow
                  required property var modelData
                  required property int index
                  width: parent.width
                  height: 40
                  radius: 6
                  readonly property bool selected: popup.pane === "timers"
                    && timerRow.index === popup.timerSel
                  color: timerRow.selected ? "#4d45505c" : "transparent"

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: timerRow.modelData.running ? "" : ""
                    color: timerRow.modelData.running ? Zenon.green : popup.dimColor
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 17
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 40
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 190
                    elide: Text.ElideRight
                    text: timerRow.modelData.label
                    color: timerRow.selected ? popup.entryColor : Zenon.white
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.weight: Font.Bold
                    font.pixelSize: 15
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 74
                    anchors.verticalCenter: parent.verticalCenter
                    text: timerRow.modelData.minutes + "m"
                    color: popup.dimColor
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 14
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    // the remaining time once it has started, its full length
                    // before that — never a bare 00:00 for something idle
                    text: Chr.clock(timerRow.modelData.remaining > 0
                      ? timerRow.modelData.remaining
                      : timerRow.modelData.minutes * 60)
                    color: timerRow.modelData.running ? Zenon.green
                      : (timerRow.modelData.remaining > 0 ? Zenon.sand : Zenon.white)
                    font.family: Zenon.clockFamily
                    font.weight: Font.Bold
                    font.pixelSize: 16
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: { popup.pane = "timers"; popup.timerSel = timerRow.index; }
                    onClicked: Chronos.toggle(timerRow.index)
                  }
                }
              }

              // The new timer's name, typed before it exists. Sits where the
              // timer itself will appear, so creating one is a row growing
              // into place rather than a dialog.
              Item {
                width: parent.width
                height: popup.naming ? 40 : 0
                visible: popup.naming
                clip: true

                Rectangle {
                  anchors.fill: parent
                  radius: 6
                  color: "#4d45505c"
                }

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  text: ""
                  color: popup.dimColor
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.pixelSize: 17
                }

                TextInput {
                  id: nameInput
                  anchors.left: parent.left
                  anchors.leftMargin: 40
                  anchors.right: parent.right
                  anchors.rightMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  color: popup.entryColor
                  selectionColor: "#4de78284"
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.weight: Font.Bold
                  font.pixelSize: 15
                  // Handled as key events, not through onAccepted: that signal
                  // does not consume the keypress, so Return reached the panel
                  // behind and was read as "start the timer" — every timer
                  // created this way started counting the moment it was named.
                  Keys.onReturnPressed: (event) => {
                    event.accepted = true;
                    popup.commitName();
                  }
                  Keys.onEnterPressed: (event) => {
                    event.accepted = true;
                    popup.commitName();
                  }
                  Keys.onEscapePressed: (event) => {
                    event.accepted = true;
                    popup.cancelName();
                  }

                  Text {
                    anchors.fill: parent
                    visible: nameInput.text === ""
                    text: "name it, or just press return"
                    color: popup.dimColor
                    font: nameInput.font
                    verticalAlignment: Text.AlignVCenter
                  }
                }
              }
            }
          }
        }

        // ── the strip ───────────────────────────────────────────────
        Rectangle {
          width: parent.width
          height: popup.stripHeight()
          color: popup.msgColor

          Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: popup.msgBorder
          }

          Column {
            anchors.fill: parent
            topPadding: 6
            bottomPadding: 6
            spacing: -2

            HintBar { width: parent.width }
          }
        }
      }
    }
  }
}
