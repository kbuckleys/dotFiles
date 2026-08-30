// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// Notification history. mako's config said history=0, so this is the one
// thing it never had: the toasts you missed, still readable afterwards.
//
// POINTER-ONLY, like chronos. It opens off a click on the bell, so it answers
// a mouse: the list scrolls, a row's ✕ removes it, the header clears the lot
// and toggles music tracking, and filtering is a row of app chips rather than
// a search field with no field. Escape closes, and that is the only key —
// a layer that took the focus grab has to have some way to hand it back.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Services.Notifications
import "../morpheus"
import "../morpheus/helpers.js" as Helpers
import "howler.js" as Wolf

PanelWindow {
  id: popup

  WlrLayershell.layer: WlrLayer.Overlay

  property bool shown: false
  property bool morphMode: false
  // 0..1, driven by shell.qml, which owns the crossfade schedule
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
  readonly property string glyphBell:   ""
  readonly property string glyphMusic:  ""
  readonly property string glyphClear:  ""
  readonly property string glyphRemove: ""
  readonly property string glyphFilter: ""

  // Which app the list is narrowed to, empty for all of them. This is what the
  // free-typing filter used to be: the same job, done by clicking the name of
  // the thing you are looking for instead of spelling it.
  property string appFilter: ""
  // re-read while open so "3m" does not sit there going stale
  property double now: Date.now()

  readonly property var rows: {
    const all = Howler.history;
    if (popup.appFilter === "") return all;
    return all.filter((r) => String(r.appName || "") === popup.appFilter);
  }

  // Every app in the history, most talkative first, so the chip you want is
  // usually the first one. Capped: past six the row stops being a row.
  readonly property var apps: {
    const counts = {};
    const order = [];
    const all = Howler.history;
    for (let i = 0; i < all.length; ++i) {
      const name = String(all[i].appName || "");
      if (name === "") continue;
      if (counts[name] === undefined) { counts[name] = 0; order.push(name); }
      counts[name] += 1;
    }
    order.sort((a, b) => counts[b] - counts[a]);
    return order.slice(0, 6).map((n) => ({ name: n, count: counts[n] }));
  }
  // one app is not a choice, so the row only earns its space past that
  readonly property bool hasChips: popup.apps.length > 1

  readonly property int visibleRows: 8
  readonly property int rowHeight: 56
  // The header laid out as padding and gaps rather than as two boxes with the
  // content floating in the middle of each: centred in 44 and 34, the space
  // between the title and the chips came out at 17px against 11 above and 6
  // below, so the two rows read as separate bands instead of one header.
  readonly property int titleH: 26   // the buttons are the tallest thing in it
  readonly property int chipsH: 22
  readonly property int headPadTop: 10
  readonly property int headGap: 7
  readonly property int headPadBottom: 9
  readonly property int headerH: popup.headPadTop + popup.titleH
    + (popup.hasChips ? popup.headGap + popup.chipsH : 0) + popup.headPadBottom

  function bodyH() {
    if (popup.rows.length === 0) return 60;
    return Math.min(popup.rows.length, popup.visibleRows) * popup.rowHeight;
  }

  function calcHeight() {
    return popup.headerH + popup.bodyH();
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

  // "3m" was written once at open and then sat there. Re-read while the panel
  // is up, and only while it is up.
  Timer {
    interval: 30000
    repeat: true
    running: popup.shown
    onTriggered: popup.now = Date.now()
  }

  IpcHandler {
    target: "Howler"

    function toggle() { popup.toggle(); }
    // clear what is on screen without touching what is in the panel
    function dismiss(): string { Howler.dismissAll(); return "ok"; }
    function clear(): string { Howler.clearHistory(); return "ok"; }
    function stat(): string {
      return "live=" + Howler.live.values.length
        + " history=" + Howler.history.length
        + " unread=" + Howler.unread;
    }
  }

  // ---------------------------------------------------------- actions --

  function openPopup() {
    popup.shown = true;
    popup.collapsing = false;
    popup.appFilter = "";
    popup.now = Date.now();
    // opening the panel IS reading it; the bell goes quiet
    Howler.markRead();
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

  function syncFocus() {
    Qt.callLater(() => {
      if (!popup.shown) return;
      bgRoot.forceActiveFocus();
    });
  }

  // The filtered view and the store are different lists, so a row cannot be
  // removed by its on-screen index — it has to be found in the store first.
  function forget(row) {
    const idx = Howler.history.indexOf(row);
    if (idx < 0) return;
    Howler.forget(idx);
    // the chip that was filtering may have just lost its last row
    if (popup.appFilter !== "" && popup.rows.length === 0) popup.appFilter = "";
  }

  function clearAll() {
    Howler.clearHistory();
    popup.appFilter = "";
  }

  // ------------------------------------------------------------ panel --

  MouseArea {
    anchors.fill: parent
    z: 0
    onClicked: popup.closePopup()
  }

  Item {
    id: panel
    width: 800
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
      cornerRadius: popup.clipRadius
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
      color: popup.morphMode ? "transparent" : Zenon.layerBg
      radius: popup.clipRadius
      border.color: popup.morphMode ? "transparent" : Zenon.surface
      border.width: 1
      focus: true

      Keys.onEscapePressed: (event) => {
        event.accepted = true;
        // a filter is a state you can be in, so escape backs out of that first
        if (popup.appFilter !== "") popup.appFilter = "";
        else popup.closePopup();
      }

      Column {
        anchors.fill: parent

        // ── the header ──────────────────────────────────────────────
        Rectangle {
          width: parent.width
          height: popup.headerH
          color: Zenon.headBg

          Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Zenon.msgBorder
          }

          Item {
            width: parent.width
            y: popup.headPadTop
            height: popup.titleH

            Row {
              anchors.left: parent.left
              anchors.leftMargin: 20
              anchors.verticalCenter: parent.verticalCenter
              height: 22
              spacing: 8

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: popup.glyphBell
                color: Zenon.cyan
                font.family: popup.face
                font.pixelSize: 16
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Notifications"
                color: Zenon.cyan
                font.family: popup.face
                font.weight: 600
                font.pixelSize: 18
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: Howler.history.length > 0
                text: popup.appFilter === ""
                  ? String(Howler.history.length)
                  : popup.rows.length + " of " + Howler.history.length
                color: Zenon.muted
                font.family: popup.face
                font.weight: Font.Bold
                font.pixelSize: 14
              }
            }

            Row {
              anchors.right: parent.right
              anchors.rightMargin: 20
              anchors.verticalCenter: parent.verticalCenter
              height: 26
              spacing: 8

              // Music tracking, which used to be alt+t and a line of hint text
              // reporting its state. It is a switch, so it is drawn as one.
              IconButton {
                glyph: popup.glyphMusic
                label: Howler.trackMusic ? "music tracked" : "music ignored"
                accent: Zenon.magenta
                on: Howler.trackMusic
                onActivated: Howler.toggleMusicTracking()
              }
              IconButton {
                glyph: popup.glyphClear
                label: "clear all"
                accent: Zenon.red
                dimmed: Howler.history.length === 0
                onActivated: popup.clearAll()
              }
            }
          }

          // ── the app chips ─────────────────────────────────────────
          // What the typing filter was for, as hit targets. One is always
          // "everything"; the rest narrow to a single sender.
          Item {
            width: parent.width
            y: popup.headPadTop + popup.titleH + popup.headGap
            height: popup.chipsH
            visible: popup.hasChips

            Row {
              anchors.left: parent.left
              anchors.leftMargin: 20
              anchors.verticalCenter: parent.verticalCenter
              height: 22
              spacing: 6

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: popup.glyphFilter
                color: popup.appFilter === "" ? Zenon.muted : Zenon.sand
                Behavior on color { ColorAnimation { duration: Zenon.fast } }
                font.family: popup.face
                font.pixelSize: 12
              }

              Chip {
                label: "all"
                count: Howler.history.length
                on: popup.appFilter === ""
                onActivated: popup.appFilter = ""
              }

              Repeater {
                model: popup.apps

                delegate: Chip {
                  required property var modelData
                  label: Helpers.collapse(modelData.name)
                  count: modelData.count
                  on: popup.appFilter === modelData.name
                  // clicking the chip you are already on takes the filter off,
                  // so the row never becomes a one-way door
                  onActivated: popup.appFilter =
                    (popup.appFilter === modelData.name) ? "" : modelData.name
                }
              }
            }
          }
        }

        // ── the list ────────────────────────────────────────────────
        Item {
          width: parent.width
          height: popup.bodyH()

          Text {
            anchors.centerIn: parent
            visible: popup.rows.length === 0
            text: Howler.history.length === 0 ? "nothing yet" : "nothing from that one"
            color: Zenon.muted
            font.family: popup.face
            font.weight: Font.Bold
            font.pixelSize: 16
          }

          ListView {
            id: list
            anchors.fill: parent
            clip: true
            model: popup.rows
            visible: popup.rows.length > 0
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
              id: histRow
              required property var modelData
              required property int index
              width: list.width
              height: popup.rowHeight

              readonly property var player:
                Howler.playerFor(histRow.modelData.appName, histRow.modelData.desktopEntry)
              readonly property bool isSong: histRow.player !== null

              Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                radius: Howler.radius
                color: rowHover.hovered ? Zenon.selBg : "transparent"
                Behavior on color { ColorAnimation { duration: Zenon.fast } }
              }

              // a slim urgency stripe, so a critical entry is findable while
              // scrolling without repeating the toast's whole colour scheme
              Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 3
                height: parent.height - 16
                radius: 2
                color: Howler.bgFor(histRow.modelData.urgency)
              }

              ClippingRectangle {
                id: rowIcon
                anchors.left: parent.left
                anchors.leftMargin: 22
                anchors.verticalCenter: parent.verticalCenter
                width: visible ? 32 : 0
                height: 32
                radius: Howler.iconRadius
                color: "transparent"
                visible: Howler.iconsEnabled && rowIconImg.source !== ""

                IconImage {
                  id: rowIconImg
                  anchors.fill: parent
                  source: {
                    const img = histRow.modelData.image ?? "";
                    if (img !== "") return img;
                    const ai = histRow.modelData.appIcon ?? "";
                    return ai === "" ? "" : Quickshell.iconPath(ai, true);
                  }
                }
              }

              Column {
                anchors.left: rowIcon.visible ? rowIcon.right : parent.left
                anchors.leftMargin: rowIcon.visible ? 12 : 22
                anchors.right: stampBox.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                  width: parent.width
                  text: Wolf.escapeHtml(histRow.modelData.summary)
                  textFormat: Text.StyledText
                  color: Zenon.white
                  font.family: popup.face
                  font.weight: Font.Bold
                  font.pixelSize: 16
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  visible: text !== ""
                  text: Helpers.collapse(
                    Helpers.pangoToStyled(histRow.modelData.body ?? "")
                      .replace(/\n/g, "  "))
                  textFormat: Text.StyledText
                  color: Zenon.muted
                  font.family: popup.face
                  font.pixelSize: 14
                  elide: Text.ElideRight
                }
              }

              // App name and age, right-aligned — until you hover, where the
              // same slot hands you the transport for a music entry, and the ✕
              // for everything else.
              Item {
                id: stampBox
                anchors.right: parent.right
                anchors.rightMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                width: 96
                height: parent.height

                // The row's hover ORed with this box's own, as hysteresis:
                // once the controls are up, moving onto one cannot fade it out
                // from under the pointer.
                readonly property bool live: rowHover.hovered || stampHover.hovered
                readonly property bool showTransport: histRow.isSong && stampBox.live

                HoverHandler { id: stampHover }

                Column {
                  id: stampCol
                  anchors.centerIn: parent
                  width: parent.width
                  spacing: 2
                  opacity: stampBox.live ? 0 : 1
                  visible: opacity > 0.01
                  Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Wolf.ago(histRow.modelData.time, popup.now)
                    color: Zenon.keyInk
                    font.family: popup.face
                    font.weight: Font.Bold
                    font.pixelSize: 14
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Helpers.collapse(histRow.modelData.appName ?? "")
                    color: Zenon.muted
                    font.family: popup.face
                    font.pixelSize: 12
                    elide: Text.ElideRight
                    width: stampCol.width
                    horizontalAlignment: Text.AlignHCenter
                  }
                }

                Row {
                  id: rowTransport
                  anchors.centerIn: parent
                  spacing: 12
                  opacity: stampBox.showTransport ? 1 : 0
                  visible: opacity > 0.01
                  Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

                  RowKey {
                    glyph: "\uF04A"
                    onActivated: if (histRow.player) histRow.player.previous();
                  }
                  RowKey {
                    glyph: histRow.player && histRow.player.isPlaying
                      ? "\uF04C" : "\uF04B"
                    onActivated: if (histRow.player) histRow.player.togglePlaying();
                  }
                  RowKey {
                    glyph: "\uF04E"
                    onActivated: if (histRow.player) histRow.player.next();
                  }
                }

                // Removing a row is its own button now. It used to be a click
                // anywhere on the row, which meant reading one and losing it
                // were the same gesture.
                Item {
                  anchors.centerIn: parent
                  width: 26
                  height: 26
                  opacity: (stampBox.live && !stampBox.showTransport) ? 1 : 0
                  visible: opacity > 0.01
                  Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

                  Rectangle {
                    anchors.fill: parent
                    radius: 6
                    color: killMa.containsMouse
                      ? Qt.rgba(Zenon.red.r, Zenon.red.g, Zenon.red.b, 0.22) : "transparent"
                    border.color: killMa.containsMouse ? Zenon.red : Zenon.surface
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: Zenon.fast } }
                    Behavior on border.color { ColorAnimation { duration: Zenon.fast } }
                  }

                  Text {
                    anchors.centerIn: parent
                    text: popup.glyphRemove
                    color: killMa.containsMouse ? Zenon.red : Zenon.muted
                    Behavior on color { ColorAnimation { duration: Zenon.fast } }
                    font.family: popup.face
                    font.pixelSize: 13
                  }

                  MouseArea {
                    id: killMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: popup.forget(histRow.modelData)
                  }
                }
              }

              // Hover through a HANDLER, not a MouseArea. A hoverEnabled
              // MouseArea filling the row is the topmost thing in it and takes
              // the pointer for itself, so the ✕ and the transport keys inside
              // never lit up. A HoverHandler reports the pointer without
              // consuming it, and it needs no acceptedButtons dance to keep out
              // of their way — the row itself has no click of its own.
              HoverHandler { id: rowHover }
            }
          }

          // A thumb rather than a full scrollbar: it is a position report, and
          // the wheel is what does the scrolling.
          Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: 3
            width: 3
            radius: 2
            visible: list.visible && popup.rows.length > popup.visibleRows
            color: Zenon.msgBorder
            y: list.y + list.visibleArea.yPosition * list.height
            height: Math.max(24, list.visibleArea.heightRatio * list.height)
          }
        }
      }
    }
  }

  // Same reason as the toast overlay's: an inline component is only legal at
  // the document root.
  component RowKey: Text {
    id: rowKey
    property string glyph: ""
    signal activated()

    text: rowKey.glyph
    color: Zenon.white
    font.family: popup.face
    font.weight: Font.Bold
    font.pixelSize: 16
    opacity: rowKeyArea.containsMouse ? 1 : 0.6
    Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

    MouseArea {
      id: rowKeyArea
      anchors.fill: parent
      anchors.margins: -5
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: rowKey.activated()
    }
  }

  // A glyph that grows its label out on hover, so the header stays a row of
  // buttons rather than a sentence. `on` is for one that reports a state as
  // well as doing something — it stays lit while that state holds.
  component IconButton: Rectangle {
    id: btn
    property string glyph: ""
    property string label: ""
    property color accent: Zenon.cyan
    property bool dimmed: false
    property bool on: false
    signal activated()

    readonly property bool hovered: btnMa.containsMouse && !btn.dimmed
    readonly property bool lit: btn.hovered || btn.on

    implicitWidth: btnRow.implicitWidth + 18
    implicitHeight: 26
    width: btn.implicitWidth
    height: btn.implicitHeight
    radius: 6
    color: btn.lit
      ? Qt.rgba(btn.accent.r, btn.accent.g, btn.accent.b, btn.hovered ? 0.22 : 0.12)
      : "transparent"
    border.color: btn.lit ? btn.accent : Zenon.surface
    border.width: 1
    opacity: btn.dimmed ? 0.4 : 1
    Behavior on color { ColorAnimation { duration: Zenon.fast } }
    Behavior on border.color { ColorAnimation { duration: Zenon.fast } }
    Behavior on opacity { NumberAnimation { duration: Zenon.fast } }

    Row {
      id: btnRow
      anchors.centerIn: parent
      height: 18
      spacing: (btn.hovered && btn.label !== "") ? 6 : 0

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: btn.glyph
        color: btn.lit ? btn.accent : Zenon.muted
        Behavior on color { ColorAnimation { duration: Zenon.fast } }
        font.family: popup.face
        font.weight: Font.Bold
        font.pixelSize: 13
      }

      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: (btn.hovered && btn.label !== "") ? btnLabel.implicitWidth : 0
        height: btnLabel.implicitHeight
        clip: true
        Behavior on width { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

        Text {
          id: btnLabel
          anchors.verticalCenter: parent.verticalCenter
          text: btn.label
          color: btn.accent
          font.family: popup.face
          font.weight: Font.Bold
          font.pixelSize: 12
        }
      }
    }

    MouseArea {
      id: btnMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: btn.dimmed ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: if (!btn.dimmed) btn.activated()
    }
  }

  // One app in the filter row: its name and how many it has sent.
  component Chip: Rectangle {
    id: chip
    property string label: ""
    property int count: 0
    property bool on: false
    signal activated()

    readonly property bool lit: chip.on || chipMa.containsMouse

    implicitWidth: chipRow.implicitWidth + 16
    implicitHeight: 22
    width: chip.implicitWidth
    height: chip.implicitHeight
    radius: 11
    color: chip.on ? Qt.rgba(Zenon.sand.r, Zenon.sand.g, Zenon.sand.b, 0.20)
      : (chipMa.containsMouse ? Zenon.hoverTint : "transparent")
    border.color: chip.on ? Zenon.sand : Zenon.surface
    border.width: 1
    Behavior on color { ColorAnimation { duration: Zenon.fast } }
    Behavior on border.color { ColorAnimation { duration: Zenon.fast } }

    Row {
      id: chipRow
      anchors.centerIn: parent
      height: 14
      spacing: 5

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: chip.label
        color: chip.on ? Zenon.sand : (chip.lit ? Zenon.white : Zenon.keyInk)
        Behavior on color { ColorAnimation { duration: Zenon.fast } }
        font.family: popup.face
        font.weight: Font.Bold
        font.pixelSize: 12
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: String(chip.count)
        color: Zenon.muted
        font.family: popup.face
        font.pixelSize: 11
      }
    }

    MouseArea {
      id: chipMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.activated()
    }
  }
}
