// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// CHRONOS — what the clock opens into. The pomodoro band across the top, the
// calendar under its left half, the forecast under its right.
//
// POINTER-ONLY, deliberately. It spawns from a pill you clicked, so it is
// answering a mouse, and every affordance in here is a hit target: months step
// on a click or a scroll, a timer's length steps on a scroll or its own
// stepper, and nothing hides behind a chord. The single exception is naming a
// timer, which is typing by definition — and even that commits and cancels
// from two buttons as well as from the keyboard.
//
// The two panes are wired together: picking a day in the calendar focuses the
// forecast on it, and picking a day in the forecast strip moves the calendar's
// selection to match. One selected date, two views of it.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import "../morpheus"
import "../morpheus/helpers.js" as Helpers
import "chronos.js" as Chr
import "weather.js" as Wx

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

  readonly property string face: "JetBrainsMono Nerd Font Propo"

  // While the pill is still growing into this layer, the panel is scaled down
  // to the pill's live size — and a radius scales with it. Halfway through, an
  // 8px corner paints as ~5px on screen while the pill's own corner is a true
  // 8px, so the dark header strip inside this clip pokes out past the pill's
  // arc. Dividing by the scale keeps the ON-SCREEN radius at pillRadius. The
  // two axes scale by different amounts, so mid-morph the corner is cut a
  // shade wide — which shows the pill's own background rather than this
  // layer's, and is gone by the time the scale reaches 1.
  readonly property real clipRadius: Zenon.pillRadius
    / Math.max(0.2, Math.min(popup.panelX, popup.panelY))

  // the glyphs this panel is built out of, named once. Every codepoint was
  // read off the installed font rather than taken from a cheat sheet.
  readonly property string glyphRename:  ""
  readonly property string glyphReset:   ""
  readonly property string glyphRemove:  ""
  readonly property string glyphToday:   ""
  readonly property string glyphTimer:   ""
  readonly property string glyphOk:      ""
  readonly property string glyphCelsius: ""
  readonly property string glyphFahren:  ""

  // ── the date the whole panel is pointed at ───────────────────────────
  // A month cursor rather than a Date for the view: paging by month on a Date
  // lands on the 31st of a 30-day month and silently skips one.
  property int viewYear: 0
  property int viewMonth: 0
  // The selection carries its own y/m/d rather than an offset into the view:
  // the grid's dim cells belong to the neighbouring months, so what is
  // selected is not always inside the month on screen.
  property int selYear: 0
  property int selMonth: 0
  property int selDay: 1
  property var today: new Date()

  readonly property string todayIso: Chr.isoOf(popup.today)
  readonly property string selIso:
    Chr.isoDay(popup.selYear, popup.selMonth, popup.selDay)
  readonly property var selDate: new Date(popup.selYear, popup.selMonth, popup.selDay)
  readonly property bool selIsToday: popup.selIso === popup.todayIso

  readonly property var cells: Chr.monthGrid(popup.viewYear, popup.viewMonth)

  function goToday() {
    popup.today = new Date();
    popup.viewYear = popup.today.getFullYear();
    popup.viewMonth = popup.today.getMonth();
    popup.selYear = popup.viewYear;
    popup.selMonth = popup.viewMonth;
    popup.selDay = popup.today.getDate();
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

  // Picking a day in a dim leading or trailing cell pages the view to that
  // day's own month, which is what clicking one of them plainly means.
  function pick(y, m, d) {
    popup.selYear = y;
    popup.selMonth = m;
    popup.selDay = d;
    popup.viewYear = y;
    popup.viewMonth = m;
  }

  // ── naming, the one place typing belongs ─────────────────────────────
  // -1 while naming something that does not exist yet, otherwise the index of
  // the timer being renamed.
  property bool naming: false
  property int nameTarget: -1

  function startNaming(index) {
    popup.nameTarget = index;
    popup.naming = true;
    nameInput.text = (index >= 0 && Chronos.timers[index])
      ? Chronos.timers[index].label : "";
    nameInput.selectAll();
    Qt.callLater(() => { if (popup.naming) nameInput.forceActiveFocus(); });
  }

  function commitName() {
    const label = nameInput.text.trim();
    const target = popup.nameTarget;
    popup.naming = false;
    popup.nameTarget = -1;
    // an empty name still makes a timer; it just gets the generic one
    if (target < 0) Chronos.add(label, 0);
    else if (label !== "") Chronos.relabel(target, label);
    bgRoot.forceActiveFocus();
  }

  function cancelName() {
    popup.naming = false;
    popup.nameTarget = -1;
    bgRoot.forceActiveFocus();
  }

  // ── geometry ─────────────────────────────────────────────────────────
  readonly property int cellW: 52
  readonly property int cellH: 34
  readonly property int gridW: popup.cellW * 7
  // both panes are the calendar grid plus breathing room, and the panel is as
  // wide as the two of them rather than stretched to the usual 1000
  readonly property int paneW: popup.gridW + 24
  readonly property int sideMargin: 20
  readonly property int splitGap: 20
  readonly property int panelWidth:
    popup.sideMargin * 2 + popup.paneW * 2 + popup.splitGap * 2 + 1

  // ── the pomodoro band ────────────────────────────────────────────────
  // Cells divide the band's width between them: one timer takes all of it, two
  // take a half each, three a third each. Past three they wrap, and the rows
  // are balanced rather than filled — four comes out 2+2, not 3+1, because a
  // lone cell stretched across a whole row does not read as one of a set.
  readonly property int perRow: 3
  readonly property int cellGap: 10
  // A cell is the same height as the empty invitation, so the band never
  // changes shape when the first timer appears.
  readonly property int timerH: popup.emptyH
  // the ＋ strip runs the full height of the band down its right edge
  readonly property bool bandEmpty: Chronos.timers.length === 0
  readonly property int bandPadTop: 8
  readonly property int bandPadBottom: 8

  readonly property var bandLayout: {
    const counts = Chr.bandRows(Chronos.timers.length, popup.perRow);
    const out = [];
    let i = 0;
    for (const n of counts) {
      const row = [];
      for (let k = 0; k < n; ++k) row.push(i++);
      out.push(row);
    }
    return out;
  }

  // The empty invitation is one LINE — a glyph and a sentence beside it — so it
  // has no business being as tall as a cell carrying a countdown, a label, a
  // stepper and a progress rule.
  readonly property int emptyH: 44

  readonly property int bandInner: {
    if (popup.bandEmpty) return popup.emptyH;
    const rows = Math.max(1, popup.bandLayout.length);
    return rows * popup.timerH + (rows - 1) * popup.cellGap;
  }
  readonly property int bandHeight:
    popup.bandPadTop + popup.bandInner + popup.bandPadBottom
  readonly property int bandWidth: popup.panelWidth - popup.sideMargin * 2
  readonly property bool hasTimers: Chronos.timers.length > 0
  // The cells own the whole band. Adding a timer is one of the buttons on a
  // cell now, so nothing is reserved beside them — which is also what makes
  // "one timer takes the whole width" literally true.
  readonly property int cellsWidth: popup.bandWidth

  function cellWidthFor(count) {
    if (count <= 0) return popup.cellsWidth;
    return (popup.cellsWidth - (count - 1) * popup.cellGap) / count;
  }

  // ── the body ─────────────────────────────────────────────────────────
  // Fixed, and sized by the calendar: six rows of a month is the tallest thing
  // in here and the one that must not move as you page through months.
  readonly property int panePad: 18
  // header + weekday row + six weeks + footer + the gaps between them, and a
  // little over so the forecast's week strip is not fighting the calendar for
  // the last dozen pixels
  readonly property int paneInner: 34 + 22 + popup.cellH * 6 + 26 + 24 + 14
  readonly property int bodyHeight: popup.panePad * 2 + popup.paneInner

  function calcHeight() { return popup.bandHeight + 1 + popup.bodyHeight; }

  // ── the forecast the right pane is showing ───────────────────────────
  // The selected day if there is one in range, otherwise nothing — and with
  // nothing, the pane shows the live reading instead.
  readonly property var selForecast: Weather.dayFor(popup.selIso)
  readonly property bool showingNow: popup.selIsToday || popup.selForecast === null

  // Everything the forecast block binds to, resolved here rather than in the
  // tree. Weather.current is null until the first reply lands and the panes
  // keep their bindings live behind `visible`, so every read of it needs a
  // guard — one place for them, not fifteen.
  readonly property var wxNow: Weather.current
  readonly property var wxRow: popup.showingNow ? Weather.today : popup.selForecast
  readonly property int wxCode: popup.showingNow
    ? (popup.wxNow ? popup.wxNow.code : 0)
    : (popup.selForecast ? popup.selForecast.code : 0)
  readonly property bool wxIsDay: popup.showingNow
    ? (popup.wxNow ? popup.wxNow.isDay : true) : true
  readonly property string wxTemp: popup.showingNow
    ? (popup.wxNow ? Weather.fmt(popup.wxNow.temp) : "--")
    : Weather.fmt(popup.selForecast.hi)
  readonly property string wxLow: popup.showingNow
    ? "" : Weather.fmt(popup.selForecast.lo)
  readonly property string wxFeels: popup.showingNow
    ? (popup.wxNow ? Weather.fmt(popup.wxNow.feels) + Weather.unit : "--")
    : Weather.fmt(popup.selForecast.lo) + Weather.unit
  readonly property string wxHumid: popup.showingNow
    ? (popup.wxNow ? popup.wxNow.humidity + "%" : "--")
    : ((popup.selForecast.pop ?? 0) + "%")
  readonly property string wxWind: popup.wxNow
    ? Math.round(popup.wxNow.wind) + " km/h " + Wx.windDir(popup.wxNow.windDeg)
    : "--"
  readonly property string wxSunrise:
    popup.wxRow ? Wx.hhmm(popup.wxRow.sunrise) : "--:--"
  readonly property string wxSunset:
    popup.wxRow ? Wx.hhmm(popup.wxRow.sunset) : "--:--"

  function roleColor(code) {
    const r = Wx.role(code);
    if (r === "sun") return Zenon.sand;
    if (r === "cloud") return Zenon.cyan;
    if (r === "rain") return Zenon.blue;
    if (r === "snow") return Zenon.white;
    if (r === "sleet") return Zenon.pink;
    if (r === "storm") return Zenon.magenta;
    return Zenon.muted;
  }

  // How long ago the forecast came in. Zero means it was restored from disk and
  // has not been refreshed this session, which is worth saying out loud rather
  // than dressing up as fresh.
  property double ageNow: Date.now()
  readonly property string age: {
    if (!Weather.ready) return "";
    if (Weather.fetched === 0) return "cached";
    const s = Math.max(0, Math.floor((popup.ageNow - Weather.fetched) / 1000));
    if (s < 60) return "just now";
    const m = Math.floor(s / 60);
    if (m < 60) return m + "m ago";
    return Math.floor(m / 60) + "h ago";
  }

  visible: popup.showFactor > 0.01
  color: "transparent"
  anchors { left: true; right: true; top: true; bottom: true }
  focusable: true
  exclusionMode: ExclusionMode.Ignore

  Component.onCompleted: popup.goToday()

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

  // Keeps "today" and the forecast's age honest while the panel sits open —
  // only while it is open, since neither matters to anything else.
  Timer {
    interval: 30000
    repeat: true
    running: popup.shown
    onTriggered: {
      popup.ageNow = Date.now();
      const now = new Date();
      // a panel left open across midnight should move its own highlight
      if (Chr.isoOf(now) !== popup.todayIso) popup.today = now;
    }
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

    function weather(): string {
      Weather.refresh();
      return "refreshing " + (Weather.place !== "" ? Weather.place : "unknown place");
    }

    function status(): string {
      let s = "shown=" + popup.shown + " naming=" + popup.naming
        + " view=" + popup.viewYear + "-" + (popup.viewMonth + 1)
        + " sel=" + popup.selIso
        + " timers=" + Chronos.timers.length
        + " weather=" + (Weather.ready ? "ready"
            : (Weather.error !== "" ? Weather.error : "pending"));
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
    popup.naming = false;
    popup.nameTarget = -1;
    popup.goToday();
    popup.ageNow = Date.now();
    // opening is the moment someone actually wants to know, so this is where a
    // stale forecast gets replaced — the fifteen-minute poll is the background
    Weather.refreshIfStale();
    closeAnim.stop();
    popup.showFactor = 0;
    openAnim.restart();
    Qt.callLater(() => { if (popup.shown) bgRoot.forceActiveFocus(); });
  }

  function closePopup() {
    popup.collapsing = true;
    popup.naming = false;
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
      cornerRadius: popup.clipRadius
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
      color: popup.morphMode ? "transparent" : Zenon.layerBg
      radius: popup.clipRadius
      border.color: popup.morphMode ? "transparent" : Zenon.surface
      border.width: 1
      focus: true

      // Escape closes, because a layer that took the focus grab has to give it
      // back somehow. It is the only key this panel answers.
      Keys.onEscapePressed: (event) => {
        event.accepted = true;
        popup.closePopup();
      }

      Column {
        anchors.fill: parent

        // ── calendar | forecast ─────────────────────────────────────
        Item {
          id: body
          width: parent.width
          height: popup.bodyHeight

          // ── the calendar ─────────────────────────────────────────
          Item {
            id: calPane
            width: popup.paneW
            height: parent.height
            anchors.left: parent.left
            anchors.leftMargin: popup.sideMargin

            // Scrolling anywhere over the pane pages the month, and with shift
            // held, the year. The chevrons in the header do the same for anyone
            // who would rather click.
            WheelHandler {
              acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
              onWheel: (event) => {
                const d = event.angleDelta.y > 0 ? -1 : 1;
                if (event.modifiers & Qt.ShiftModifier) popup.stepYear(d);
                else popup.stepMonth(d);
              }
            }

            Column {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: 8

              // «  ‹  August 2026  ›  »  — month on the inner pair, year on the
              // outer, so paging a year is a click and not a chord
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                height: 34
                spacing: 2

                Chevron { glyph: "«"; onActivated: popup.stepYear(-1) }
                Chevron { glyph: "‹"; onActivated: popup.stepMonth(-1) }

                Item {
                  width: 196
                  height: 34

                  Row {
                    anchors.centerIn: parent
                    height: 24
                    spacing: 8

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: Chr.monthName(popup.viewMonth)
                      color: headMa.containsMouse ? Zenon.white : Zenon.cyan
                      Behavior on color { ColorAnimation { duration: Zenon.fast } }
                      font.family: popup.face
                      font.weight: Font.Bold
                      font.pixelSize: 19
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: String(popup.viewYear)
                      color: Zenon.muted
                      font.family: popup.face
                      font.pixelSize: 15
                    }
                  }

                  MouseArea {
                    id: headMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: popup.goToday()
                  }
                }

                Chevron { glyph: "›"; onActivated: popup.stepMonth(1) }
                Chevron { glyph: "»"; onActivated: popup.stepYear(1) }
              }

              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                height: 22

                Repeater {
                  model: 7
                  delegate: Text {
                    required property int index
                    width: popup.cellW
                    height: 22
                    text: Chr.dayShort(index)
                    color: index >= 5 ? Zenon.muted : Zenon.keyInk
                    font.family: popup.face
                    font.weight: Font.Bold
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                  }
                }
              }

              Grid {
                anchors.horizontalCenter: parent.horizontalCenter
                columns: 7
                columnSpacing: 0
                rowSpacing: 0

                Repeater {
                  model: popup.cells

                  delegate: Item {
                    id: dayCell
                    required property var modelData
                    required property int index
                    width: popup.cellW
                    height: popup.cellH

                    readonly property string iso: Chr.isoDay(
                      dayCell.modelData.y, dayCell.modelData.m, dayCell.modelData.d)
                    readonly property bool isToday: dayCell.iso === popup.todayIso
                    readonly property bool isSel: dayCell.iso === popup.selIso
                    readonly property bool weekend: dayCell.index % 7 >= 5
                    readonly property var forecast: Weather.dayFor(dayCell.iso)

                    Rectangle {
                      anchors.centerIn: parent
                      width: popup.cellW - 6
                      height: popup.cellH - 4
                      radius: 6
                      color: dayCell.isToday ? Zenon.cyan
                        : (dayCell.isSel
                            ? Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.16)
                            : (dayMa.containsMouse ? Zenon.hoverTint : "transparent"))
                      border.color: (dayCell.isSel && !dayCell.isToday)
                        ? Zenon.cyan : "transparent"
                      border.width: 1
                      Behavior on color { ColorAnimation { duration: Zenon.fast } }
                    }

                    Text {
                      anchors.centerIn: parent
                      anchors.verticalCenterOffset: dayCell.forecast ? -3 : 0
                      text: String(dayCell.modelData.d)
                      color: dayCell.isToday ? Zenon.black
                        : (!dayCell.modelData.cur ? Zenon.dim
                        : (dayCell.weekend ? Zenon.muted : Zenon.white))
                      font.family: popup.face
                      font.weight: dayCell.isToday ? Font.Black : Font.Bold
                      font.pixelSize: 15
                    }

                    // A day the forecast reaches wears a dot in its condition's
                    // colour, so the week ahead is readable off the grid itself
                    // without clicking through it day by day.
                    Rectangle {
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: 5
                      width: 4
                      height: 4
                      radius: 2
                      visible: dayCell.forecast !== null
                      color: dayCell.isToday ? Zenon.black
                        : popup.roleColor(dayCell.forecast ? dayCell.forecast.code : 0)
                    }

                    MouseArea {
                      id: dayMa
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: popup.pick(dayCell.modelData.y,
                        dayCell.modelData.m, dayCell.modelData.d)
                    }
                  }
                }
              }

              // What is selected, spelled out, and the way back to today
              Item {
                width: parent.width
                height: 26

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  text: Chr.longDay(popup.selDate)
                  color: popup.selIsToday ? Zenon.cyan : Zenon.keyInk
                  Behavior on color { ColorAnimation { duration: Zenon.normal } }
                  font.family: popup.face
                  font.weight: Font.Bold
                  font.pixelSize: 13
                }

                PillButton {
                  anchors.right: parent.right
                  anchors.rightMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  glyph: popup.glyphToday
                  label: "today"
                  accent: Zenon.cyan
                  dimmed: popup.selIsToday && popup.viewMonth === popup.today.getMonth()
                    && popup.viewYear === popup.today.getFullYear()
                  onActivated: popup.goToday()
                }
              }
            }
          }

          Rectangle {
            anchors.left: calPane.right
            anchors.leftMargin: popup.splitGap
            anchors.verticalCenter: parent.verticalCenter
            width: 1
            height: parent.height - popup.panePad * 2
            color: Zenon.msgBorder
          }

          // ── the forecast ─────────────────────────────────────────
          Item {
            id: wxPane
            anchors.left: calPane.right
            anchors.leftMargin: popup.splitGap * 2 + 1
            width: popup.paneW
            height: parent.height

            // ── nothing to show yet ─────────────────────────────
            Column {
              anchors.centerIn: parent
              spacing: 10
              visible: !Weather.ready

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Wx.icon("unknown")
                color: Zenon.muted
                font.family: popup.face
                font.pixelSize: 34
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Weather.loading ? "fetching the forecast…"
                  : (Weather.error !== "" ? Weather.error : "no forecast yet")
                color: Zenon.muted
                font.family: popup.face
                font.weight: Font.Bold
                font.pixelSize: 15
              }
              PillButton {
                anchors.horizontalCenter: parent.horizontalCenter
                glyph: Wx.icon("refresh")
                label: Weather.located ? "try again" : "find me"
                accent: Zenon.cyan
                dimmed: Weather.loading
                onActivated: if (!Weather.loading) Weather.refresh()
              }
            }

            // ── the reading, and the numbers around it ──────────
            // Anchored from the top, with the week pinned to the bottom
            // separately: the slack between them lands where nothing is, so
            // neither block can be pushed off the pane by a font metric.
            Column {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.topMargin: popup.panePad
              spacing: 10
              visible: Weather.ready

              // place, age, units, refresh
              Item {
                width: parent.width
                height: 26

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  height: 20
                  spacing: 8

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Weather.place !== "" ? Weather.place : "here"
                    color: Zenon.cyan
                    font.family: popup.face
                    font.weight: Font.Bold
                    font.pixelSize: 16
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: popup.age
                    color: Zenon.muted
                    font.family: popup.face
                    font.pixelSize: 12
                  }
                }

                Row {
                  anchors.right: parent.right
                  anchors.rightMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  height: 24
                  spacing: 6

                  PillButton {
                    glyph: Weather.fahrenheit ? popup.glyphCelsius : popup.glyphFahren
                    label: Weather.fahrenheit ? "to °C" : "to °F"
                    accent: Zenon.sand
                    onActivated: Weather.toggleUnits()
                  }
                  PillButton {
                    glyph: Wx.icon("refresh")
                    label: Weather.loading ? "fetching" : "refresh"
                    accent: Weather.error !== "" ? Zenon.red : Zenon.cyan
                    dimmed: Weather.loading
                    onActivated: if (!Weather.loading) Weather.refresh()
                  }
                }
              }

              // Now, or the selected day if one is picked. The same block
              // either way, so switching between them changes numbers rather
              // than layout.
              Item {
                width: parent.width
                height: 94

                Text {
                  id: bigGlyph
                  anchors.left: parent.left
                  anchors.leftMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  width: 74
                  horizontalAlignment: Text.AlignHCenter
                  text: Wx.glyph(popup.wxCode, popup.wxIsDay)
                  color: popup.roleColor(popup.wxCode)
                  Behavior on color { ColorAnimation { duration: Zenon.normal } }
                  font.family: popup.face
                  font.pixelSize: 52
                }

                Column {
                  anchors.left: bigGlyph.right
                  anchors.leftMargin: 4
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 2

                  Row {
                    height: 38
                    spacing: 4

                    // The reading on its own unlit face, the way the bar's
                    // clock and the countdowns are drawn: every segment lit
                    // behind the live digits, which is literally what the panel
                    // of a real thermometer display is doing.
                    Item {
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: 2
                      width: bigTemp.implicitWidth
                      height: bigTemp.implicitHeight

                      Text {
                        anchors.centerIn: parent
                        text: Helpers.ghostText(popup.wxTemp)
                        color: Zenon.trough(Zenon.white)
                        font.family: Zenon.clockFamily
                        font.weight: Font.Bold
                        font.pixelSize: 32
                      }
                      Text {
                        id: bigTemp
                        anchors.centerIn: parent
                        text: popup.wxTemp
                        color: Zenon.white
                        font.family: Zenon.clockFamily
                        font.weight: Font.Bold
                        font.pixelSize: 32
                      }
                    }
                    Text {
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: 9
                      text: Weather.unit
                      color: Zenon.keyInk
                      font.family: popup.face
                      font.weight: Font.Bold
                      font.pixelSize: 15
                    }
                    Text {
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: 9
                      visible: !popup.showingNow
                      text: "  ↓ " + popup.wxLow
                      color: Zenon.blue
                      font.family: popup.face
                      font.weight: Font.Bold
                      font.pixelSize: 15
                    }
                  }

                  Text {
                    text: Wx.label(popup.wxCode)
                    color: Zenon.keyInk
                    font.family: popup.face
                    font.weight: Font.Bold
                    font.pixelSize: 15
                  }

                  Text {
                    text: popup.showingNow
                      ? Chr.longDay(popup.today) : Chr.longDay(popup.selDate)
                    color: Zenon.muted
                    font.family: popup.face
                    font.pixelSize: 12
                  }
                }

                Column {
                  anchors.right: parent.right
                  anchors.rightMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 8

                  Reading {
                    glyph: Wx.icon("sunrise")
                    text: popup.wxSunrise
                  }
                  Reading {
                    glyph: Wx.icon("sunset")
                    text: popup.wxSunset
                  }
                }
              }

              // the three numbers under it
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 20

                Reading {
                  glyph: Wx.icon("thermo")
                  text: popup.wxFeels
                  hint: popup.showingNow ? "feels like" : "low"
                }
                Reading {
                  glyph: Wx.icon("humidity")
                  text: popup.wxHumid
                  hint: popup.showingNow ? "humidity" : "rain"
                }
                Reading {
                  glyph: Wx.icon("wind")
                  visible: popup.showingNow
                  text: popup.wxWind
                  hint: "wind"
                }
                Reading {
                  glyph: Wx.icon("umbrella")
                  visible: !popup.showingNow
                  text: popup.wxHumid
                  hint: "chance of rain"
                }
              }

              // ── the next twelve hours ─────────────────────────
              Item {
                width: parent.width
                height: 42
                visible: Weather.hourlyCurve.length >= 2

                Sparkline {
                  anchors.left: parent.left
                  anchors.leftMargin: 46
                  anchors.right: parent.right
                  anchors.rightMargin: 46
                  anchors.top: parent.top
                  height: 28
                  values: Weather.hourlyCurve
                  lineColor: Zenon.sand
                  fillColor: Zenon.sand
                  fillOpacity: 0.16
                  maxPoints: 12
                }

                // The curve is normalized to its own extremes, so the hours
                // that make it readable have to sit beside it.
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 12
                  anchors.top: parent.top
                  text: Weather.nextHours.length > 0
                    ? Wx.hhmm(Weather.nextHours[0].time) : ""
                  color: Zenon.muted
                  font.family: popup.face
                  font.pixelSize: 11
                }
                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: 12
                  anchors.top: parent.top
                  text: Weather.nextHours.length > 0
                    ? Wx.hhmm(Weather.nextHours[Weather.nextHours.length - 1].time) : ""
                  color: Zenon.muted
                  font.family: popup.face
                  font.pixelSize: 11
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.bottom: parent.bottom
                  text: "next 12 hours"
                  color: Zenon.muted
                  font.family: popup.face
                  font.pixelSize: 11
                }
              }
            }

            // ── the week ────────────────────────────────────────
            // Clicking one moves the calendar's selection to it, which is the
            // same act as clicking that day in the grid — one selected date,
            // reachable from either pane.
            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: popup.panePad
              spacing: 0
              visible: Weather.ready

              Repeater {
                model: Weather.days

                delegate: Item {
                  id: dayStrip
                  required property var modelData
                  required property int index
                  width: Math.floor(popup.gridW / 7)
                  // Sized by its own content, not by a number that has to be
                  // kept in step with four font sizes by hand — at a fixed 66
                  // the column overflowed the cell and the selected day's
                  // border cut its low temperature in half.
                  height: stripCol.implicitHeight + 14

                  readonly property bool isSel: dayStrip.modelData.date === popup.selIso
                  readonly property bool isToday: dayStrip.modelData.date === popup.todayIso
                  // noon, so a DST shift cannot land the parse on the previous day
                  readonly property var when: new Date(dayStrip.modelData.date + "T12:00:00")

                  Rectangle {
                    anchors.fill: parent
                    anchors.margins: 2
                    radius: 6
                    color: dayStrip.isSel
                      ? Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.16)
                      : (stripMa.containsMouse ? Zenon.hoverTint : "transparent")
                    border.color: dayStrip.isSel ? Zenon.cyan : "transparent"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: Zenon.fast } }
                  }

                  Column {
                    id: stripCol
                    anchors.centerIn: parent
                    spacing: 1

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: dayStrip.isToday ? "now"
                        : Chr.dayShort(Chr.weekIndex(dayStrip.when))
                      color: dayStrip.isToday ? Zenon.cyan : Zenon.muted
                      font.family: popup.face
                      font.weight: Font.Bold
                      font.pixelSize: 11
                    }
                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: Wx.glyph(dayStrip.modelData.code, true)
                      color: popup.roleColor(dayStrip.modelData.code)
                      font.family: popup.face
                      font.pixelSize: 20
                    }
                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: Weather.fmt(dayStrip.modelData.hi)
                      color: Zenon.white
                      font.family: popup.face
                      font.weight: Font.Bold
                      font.pixelSize: 13
                    }
                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: Weather.fmt(dayStrip.modelData.lo)
                      color: Zenon.muted
                      font.family: popup.face
                      font.pixelSize: 11
                    }
                  }

                  MouseArea {
                    id: stripMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: popup.pick(dayStrip.when.getFullYear(),
                      dayStrip.when.getMonth(), dayStrip.when.getDate())
                  }
                }
              }
            }
          }
        }
        Rectangle {
          width: parent.width
          height: 1
          color: Zenon.msgBorder
        }

        // ── pomodoro, across both halves ────────────────────────────
        Item {
          id: band
          width: parent.width
          height: popup.bandHeight

          Rectangle {
            anchors.fill: parent
            color: Zenon.headBg
          }

          Row {
            x: popup.sideMargin
            y: popup.bandPadTop
            width: popup.bandWidth
            height: popup.bandInner
            spacing: popup.cellGap

            // the cells, in balanced rows
            Column {
              width: popup.cellsWidth
              spacing: popup.cellGap

              // an empty band is one full-width invitation, which is the only
              // thing worth putting there
              Rectangle {
                visible: !popup.hasTimers
                width: parent.width
                height: popup.emptyH
                radius: 8
                color: emptyMa.containsMouse ? Zenon.selBg : "transparent"
                border.color: emptyMa.containsMouse ? Zenon.cyan : Zenon.surface
                border.width: 1
                Behavior on color { ColorAnimation { duration: Zenon.fast } }
                Behavior on border.color { ColorAnimation { duration: Zenon.fast } }

                Row {
                  anchors.centerIn: parent
                  spacing: 14

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: popup.glyphTimer
                    color: emptyMa.containsMouse ? Zenon.cyan : Zenon.muted
                    Behavior on color { ColorAnimation { duration: Zenon.fast } }
                    font.family: popup.face
                    font.pixelSize: 20
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "no timers — click to start one"
                    color: Zenon.muted
                    font.family: popup.face
                    font.weight: Font.Bold
                    font.pixelSize: 14
                  }
                }

                MouseArea {
                  id: emptyMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: popup.startNaming(-1)
                }
              }

              Repeater {
                model: popup.bandLayout

                delegate: Row {
                  id: cellRow
                  required property var modelData
                  readonly property int count: cellRow.modelData.length
                  width: popup.cellsWidth
                  height: popup.timerH
                  spacing: popup.cellGap

                  Repeater {
                    model: cellRow.modelData

                    delegate: TimerCell {
                      required property int modelData
                      slot: modelData
                      width: popup.cellWidthFor(cellRow.count)
                      height: popup.timerH
                    }
                  }
                }
              }
            }

          }

          // ── naming ────────────────────────────────────────────────
          // Across the band rather than inside one cell: half the time the
          // timer being named does not exist yet, and a field where a cell is
          // about to appear is clearer than one squeezed into a corner.
          Rectangle {
            id: nameStrip
            anchors.fill: parent
            color: Zenon.panelBgDeep
            visible: opacity > 0.01
            opacity: popup.naming ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

            // swallows clicks, so the band underneath cannot be poked at while
            // a name is half typed
            MouseArea { anchors.fill: parent }

            Row {
              anchors.centerIn: parent
              width: popup.bandWidth - 40
              height: 40
              spacing: 10

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 22
                horizontalAlignment: Text.AlignHCenter
                text: popup.nameTarget < 0 ? popup.glyphTimer : popup.glyphRename
                color: Zenon.cyan
                font.family: popup.face
                font.pixelSize: 17
              }

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 220
                height: 34
                radius: 6
                color: Zenon.selBg
                border.color: Zenon.cyan
                border.width: 1

                TextInput {
                  id: nameInput
                  anchors.fill: parent
                  anchors.leftMargin: 12
                  anchors.rightMargin: 12
                  verticalAlignment: TextInput.AlignVCenter
                  color: Zenon.pink
                  selectionColor: Qt.rgba(Zenon.red.r, Zenon.red.g, Zenon.red.b, 0.30)
                  selectByMouse: true
                  font.family: popup.face
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
                    text: popup.nameTarget < 0
                      ? "name it, or just take the default" : "new name"
                    color: Zenon.muted
                    font: nameInput.font
                    verticalAlignment: Text.AlignVCenter
                  }
                }
              }

              // Naming is the one place a key is unavoidable; finishing it
              // still is not, so both ways out are buttons too.
              PillButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: popup.glyphOk
                accent: Zenon.green
                label: popup.nameTarget < 0 ? "create" : "rename"
                onActivated: popup.commitName()
              }
              PillButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: popup.glyphRemove
                accent: Zenon.red
                label: "cancel"
                onActivated: popup.cancelName()
              }
            }
          }
        }

      }
    }
  }

  // ── the pieces ─────────────────────────────────────────────────────────
  // Inline components are only legal at the document root, which is why these
  // live down here rather than beside the things that use them.

  // One pomodoro. Click it to start or stop, scroll it to change its length,
  // and the three buttons on hover rename, reset and remove it.
  //
  // A ClippingRectangle rather than a Rectangle with clip: true — Qt's own clip
  // is RECTANGULAR and knows nothing about the radius, so the drain wash and
  // the progress rule, both square and both painted to the edge, filled in the
  // cell's rounded corners behind them.
  component TimerCell: ClippingRectangle {
    id: cell
    required property int slot
    readonly property var t: Chronos.timers[cell.slot] ?? null
    readonly property bool running: cell.t !== null && cell.t.running
    readonly property bool armed: cell.t !== null && cell.t.remaining > 0
    readonly property int total: cell.t !== null ? Math.max(1, cell.t.minutes * 60) : 1
    readonly property int remain: cell.t !== null
      ? (cell.t.remaining > 0 ? cell.t.remaining : cell.total) : 0
    // idle reads as a full dial rather than an empty one: the length is set and
    // the whole of it is still ahead of you
    readonly property real frac: Math.max(0, Math.min(1, cell.remain / cell.total))
    readonly property color accent: cell.running ? Zenon.green
      : (cell.armed ? Zenon.sand : Zenon.cyan)

    radius: 8
    color: cellHover.hovered ? Zenon.selBg : Zenon.panelBg
    border.color: cell.running
      ? Qt.rgba(cell.accent.r, cell.accent.g, cell.accent.b, 0.55) : Zenon.surface
    border.width: 1
    Behavior on color { ColorAnimation { duration: Zenon.fast } }
    Behavior on border.color { ColorAnimation { duration: Zenon.normal } }

    // Hover through a HANDLER, not a MouseArea. A hoverEnabled MouseArea over
    // the whole cell is the topmost thing in it and takes the pointer for
    // itself, so the buttons inside never lit and never got their clicks. A
    // HoverHandler reports the pointer without consuming it.
    HoverHandler { id: cellHover }

    // And the cell's own click target is declared FIRST, which in QML means
    // BOTTOM: every button below is a later sibling, so it sits above this and
    // takes its own clicks. Only the bare parts of the cell reach here.
    MouseArea {
      id: cellMa
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: Chronos.toggle(cell.slot)
    }

    // the drain: a wash across the cell that shrinks with the countdown
    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * cell.frac
      color: Qt.rgba(cell.accent.r, cell.accent.g, cell.accent.b,
        cell.running ? 0.13 : 0.06)
      Behavior on width { NumberAnimation { duration: 900; easing.type: Easing.Linear } }
    }

    // Everything on ONE line, chained right to left: the buttons hold the right
    // edge, the stepper sits inside them, the countdown inside that, and the
    // label takes whatever is left and elides. Nothing can overlap anything
    // else however narrow the cell gets — at three across the label simply
    // runs out of room, which is the right thing to lose first.
    //
    // The tools are always LAID OUT, only their opacity moves. Anchoring to an
    // item that toggles `visible` would make the stepper jump sideways every
    // time the pointer entered the cell. `enabled` follows the hover instead,
    // so a faded button cannot be clicked.
    Row {
      id: cellTools
      anchors.right: parent.right
      anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: -1
      spacing: 4
      opacity: (cellHover.hovered || toolsHover.hovered) ? 1 : 0
      enabled: cellHover.hovered || toolsHover.hovered
      Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

      HoverHandler { id: toolsHover }

      // Adding a timer lives here rather than in a strip of its own: it is one
      // more thing you do from a cell, and it sits FIRST so the destructive one
      // stays at the far end, away from it.
      TinyButton {
        glyph: "＋"
        accent: Zenon.green
        dimmed: Chronos.timers.length >= Chronos.maxTimers
        onActivated: popup.startNaming(-1)
      }
      TinyButton {
        glyph: popup.glyphRename
        accent: Zenon.cyan
        onActivated: popup.startNaming(cell.slot)
      }
      TinyButton {
        glyph: popup.glyphReset
        accent: Zenon.sand
        dimmed: !cell.running && !cell.armed
        onActivated: Chronos.reset(cell.slot)
      }
      TinyButton {
        glyph: popup.glyphRemove
        accent: Zenon.red
        onActivated: Chronos.remove(cell.slot)
      }
    }

    // The countdown and its stepper travel together as one BODY, centred in the
    // cell — with a single timer the cell is the whole band, and a reading pinned
    // to its right edge looked like an afterthought.
    //
    // Centred only while there is room. Below that the tools would reach across
    // and sit on the stepper, so the body falls back to hanging off their left
    // edge. The test is on WIDTH, not on hover, so nothing moves under the
    // pointer — a narrow cell is simply laid out the other way round.
    readonly property bool roomToCentre:
      (cell.width - cellBody.width) / 2 > cellTools.width + 14

    Row {
      id: cellBody
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: -1
      anchors.horizontalCenter: cell.roomToCentre ? parent.horizontalCenter : undefined
      anchors.right: cell.roomToCentre ? undefined : cellTools.left
      anchors.rightMargin: 8
      spacing: 8

      // the countdown, over its own unlit face
      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: liveTime.implicitWidth
        height: liveTime.implicitHeight

        Text {
          anchors.centerIn: parent
          text: Helpers.ghostText(Chr.clock(cell.remain))
          color: Zenon.trough(cell.accent)
          font.family: Zenon.clockFamily
          font.weight: Font.Bold
          font.pixelSize: 20
        }
        Text {
          id: liveTime
          anchors.centerIn: parent
          text: Chr.clock(cell.remain)
          color: cell.accent
          Behavior on color { ColorAnimation { duration: Zenon.normal } }
          font.family: Zenon.clockFamily
          font.weight: Font.Bold
          font.pixelSize: 20
        }
      }

      // The length, as a stepper. It is also what the scroll wheel over the cell
      // is driving, so the number the wheel moves is always on screen.
      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        TinyButton {
          glyph: "‹"
          accent: Zenon.keyInk
          onActivated: Chronos.bump(cell.slot, -1)
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: 30
          horizontalAlignment: Text.AlignHCenter
          text: (cell.t !== null ? cell.t.minutes : 0) + "m"
          color: cellHover.hovered ? Zenon.keyInk : Zenon.muted
          Behavior on color { ColorAnimation { duration: Zenon.fast } }
          font.family: popup.face
          font.weight: Font.Bold
          font.pixelSize: 13
        }
        TinyButton {
          glyph: "›"
          accent: Zenon.keyInk
          onActivated: Chronos.bump(cell.slot, 1)
        }
      }
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: 10
      anchors.right: cellBody.left
      anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: -1
      elide: Text.ElideRight
      text: cell.t !== null ? cell.t.label : ""
      color: cell.running ? cell.accent : Zenon.white
      Behavior on color { ColorAnimation { duration: Zenon.normal } }
      font.family: popup.face
      font.weight: Font.Bold
      font.pixelSize: 13
    }


    // the same countdown as a rule along the bottom edge, for the glance that
    // does not stop to read digits
    Rectangle {
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      width: parent.width * cell.frac
      height: 3
      color: cell.accent
      opacity: (cell.running || cell.armed) ? 1 : 0.35
      Behavior on width { NumberAnimation { duration: 900; easing.type: Easing.Linear } }
    }

    // Scroll to lengthen or shorten, five minutes at a time with shift. On the
    // cell rather than on the number, so it works wherever the pointer is.
    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: (event) => {
        const step = (event.modifiers & Qt.ShiftModifier) ? 5 : 1;
        Chronos.bump(cell.slot, event.angleDelta.y > 0 ? step : -step);
      }
    }
  }

  // A small square button. `dimmed` is for one that is currently pointless.
  //
  // No outline: four boxed buttons in a 44px row read as a strip of chrome, the
  // hover fill already says which one the pointer is on, and the border was
  // costing the cell horizontal room it does not have.
  component TinyButton: Rectangle {
    id: tiny
    property string glyph: ""
    property color accent: Zenon.cyan
    property bool dimmed: false
    signal activated()

    readonly property bool lit: tinyMa.containsMouse && !tiny.dimmed

    width: 20
    height: 20
    radius: 5
    color: tiny.lit
      ? Qt.rgba(tiny.accent.r, tiny.accent.g, tiny.accent.b, 0.20) : "transparent"
    opacity: tiny.dimmed ? 0.4 : 1
    Behavior on color { ColorAnimation { duration: Zenon.fast } }
    Behavior on opacity { NumberAnimation { duration: Zenon.fast } }

    Text {
      anchors.centerIn: parent
      text: tiny.glyph
      color: tiny.lit ? tiny.accent : Zenon.muted
      Behavior on color { ColorAnimation { duration: Zenon.fast } }
      font.family: popup.face
      font.pixelSize: 12
    }

    MouseArea {
      id: tinyMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: tiny.dimmed ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: if (!tiny.dimmed) tiny.activated()
    }
  }

  // A glyph that grows its label out on hover rather than carrying it all the
  // time, so a row of them stays a row of buttons.
  component PillButton: Rectangle {
    id: pill
    property string glyph: ""
    property string label: ""
    property color accent: Zenon.cyan
    property bool dimmed: false
    signal activated()

    readonly property bool lit: pillMa.containsMouse && !pill.dimmed

    implicitWidth: pillRow.implicitWidth + 18
    implicitHeight: 24
    width: pill.implicitWidth
    height: pill.implicitHeight
    radius: 6
    color: pill.lit
      ? Qt.rgba(pill.accent.r, pill.accent.g, pill.accent.b, 0.18) : "transparent"
    border.color: pill.lit ? pill.accent : Zenon.surface
    border.width: 1
    opacity: pill.dimmed ? 0.45 : 1
    Behavior on color { ColorAnimation { duration: Zenon.fast } }
    Behavior on border.color { ColorAnimation { duration: Zenon.fast } }
    Behavior on opacity { NumberAnimation { duration: Zenon.fast } }

    Row {
      id: pillRow
      anchors.centerIn: parent
      height: 18
      spacing: (pill.lit && pill.label !== "") ? 6 : 0

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: pill.glyph
        color: pill.lit ? pill.accent : Zenon.muted
        Behavior on color { ColorAnimation { duration: Zenon.fast } }
        font.family: popup.face
        font.weight: Font.Bold
        font.pixelSize: 13
      }

      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: (pill.lit && pill.label !== "") ? pillLabel.implicitWidth : 0
        height: pillLabel.implicitHeight
        clip: true
        Behavior on width { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

        Text {
          id: pillLabel
          anchors.verticalCenter: parent.verticalCenter
          text: pill.label
          color: pill.accent
          font.family: popup.face
          font.weight: Font.Bold
          font.pixelSize: 12
        }
      }
    }

    MouseArea {
      id: pillMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: pill.dimmed ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: if (!pill.dimmed) pill.activated()
    }
  }

  // glyph, value, and a word under it — the forecast's small print
  component Reading: Row {
    id: reading
    property string glyph: ""
    property string text: ""
    property string hint: ""

    // A glyph and the number it labels are two things, not one word — at 5 the
    // pair read as a single smudge
    spacing: 13

    // Uncoloured. The glyph is a label for the number beside it, not a reading
    // of its own, and five different inks along one row turned the small print
    // into a paintbox. The condition glyph and the week strip still carry the
    // palette, because there the colour IS the information.
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: reading.glyph
      color: Zenon.keyInk
      font.family: popup.face
      font.pixelSize: 17
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        text: reading.text
        color: Zenon.white
        font.family: popup.face
        font.weight: Font.Bold
        font.pixelSize: 13
      }
      Text {
        visible: reading.hint !== ""
        text: reading.hint
        color: Zenon.muted
        font.family: popup.face
        font.pixelSize: 10
      }
    }
  }

  // A month or year chevron. Big enough to hit without aiming.
  component Chevron: Item {
    id: chev
    property string glyph: ""
    signal activated()

    width: 26
    height: 34

    Text {
      anchors.centerIn: parent
      text: chev.glyph
      color: chevMa.containsMouse ? Zenon.cyan : Zenon.muted
      Behavior on color { ColorAnimation { duration: Zenon.fast } }
      font.family: popup.face
      font.weight: Font.Bold
      font.pixelSize: 18
    }

    MouseArea {
      id: chevMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chev.activated()
    }
  }
}
