// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// Notification history. mako's config said history=0, so this is the one
// thing it never had: the toasts you missed, still readable afterwards.

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

  readonly property color bgColor: "#cc000000"
  readonly property color borderColor: "#20242a"
  readonly property color msgColor: "#66282f36"
  readonly property color msgBorder: "#4d45505c"
  readonly property color fgColor: "#DFDFDD"
  readonly property color headColor: "#9bbfbf"
  readonly property color keyColor: "#a2a8bc"
  readonly property color dimColor: "#6a707f"
  readonly property color selColor: "#4d45505c"

  property string query: ""
  property int sel: 0
  // re-read on every open so "3m" does not sit there going stale
  property double now: Date.now()

  readonly property var rows: {
    const q = popup.query.trim().toLowerCase();
    const all = Howler.history;
    if (q === "") return all;
    return all.filter((r) =>
      String(r.summary || "").toLowerCase().indexOf(q) >= 0 ||
      String(r.body || "").toLowerCase().indexOf(q) >= 0 ||
      String(r.appName || "").toLowerCase().indexOf(q) >= 0);
  }

  readonly property int visibleRows: 8
  readonly property int rowHeight: 56

    function hints() {
      if (popup.rows.length === 0) return [];
      return [["type", "filter"], ["delete", "remove"],
              ["alt d", "clear all"], ["alt+t", Howler.trackMusic ? "music tracking ON" : "music tracking OFF"]];
    }

  function bodyH() {
    if (popup.rows.length === 0) return 60;
    return Math.min(popup.rows.length, popup.visibleRows) * popup.rowHeight;
  }

  function calcHeight() {
    return 72 + popup.bodyH();
  }

  component HintBar: Item {
    id: hintBarRoot
    height: 30
    property var rows: popup.hints()
    Connections {
      target: Howler
      function onTrackMusicChanged() { hintBarRoot.rows = popup.hints() }
    }
    Row {
      anchors.centerIn: parent
      spacing: 22
      Repeater {
        model: hintBarRoot.rows
        Text {
          required property var modelData
          text: "<b><span style=\"color:" + popup.keyColor + ";\">" +
            Wolf.escapeHtml(modelData[0]) + "</span></b> <span style=\"color:" +
            popup.dimColor + ";\">" + Wolf.escapeHtml(modelData[1]) + "</span>"
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
    popup.query = "";
    popup.sel = 0;
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

  function clampSel() {
    const len = popup.rows.length;
    if (len === 0) popup.sel = 0;
    else popup.sel = Math.max(0, Math.min(popup.sel, len - 1));
    followSelection();
  }

  function moveSel(delta) {
    const len = popup.rows.length;
    if (len === 0) return;
    popup.sel = ((popup.sel + delta) % len + len) % len;
    followSelection();
  }

  function followSelection() {
    Qt.callLater(() => list.positionViewAtIndex(popup.sel, ListView.Contain));
  }

  // The filtered view and the store are different lists, so a row cannot be
  // removed by its on-screen index — it has to be found in the store first.
  function removeSelected() {
    if (popup.rows.length === 0) return;
    const row = popup.rows[popup.sel];
    const idx = Howler.history.indexOf(row);
    if (idx < 0) return;
    Howler.forget(idx);
    popup.clampSel();
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
      border.color: popup.morphMode ? "transparent" : popup.borderColor
      border.width: 1
      focus: true

      Keys.onEscapePressed: (event) => {
        event.accepted = true;
        if (popup.query !== "") popup.query = "";
        else popup.closePopup();
      }

      Keys.onUpPressed: (event) => { event.accepted = true; popup.moveSel(-1); }
      Keys.onDownPressed: (event) => { event.accepted = true; popup.moveSel(1); }

      Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Delete) {
          event.accepted = true;
          popup.removeSelected();
        } else if (event.key === Qt.Key_D && (event.modifiers & Qt.AltModifier)) {
          event.accepted = true;
          Howler.clearHistory();
          popup.clampSel();
        } else if (event.key === Qt.Key_PageUp) {
          event.accepted = true;
          popup.moveSel(-popup.visibleRows);
        } else if (event.key === Qt.Key_PageDown) {
          event.accepted = true;
          popup.moveSel(popup.visibleRows);
        } else if (event.key === Qt.Key_T && (event.modifiers & Qt.AltModifier)) {
          event.accepted = true;
          Howler.toggleMusicTracking();
        } else if (event.key === Qt.Key_Backspace) {
          event.accepted = true;
          if (popup.query.length > 0) {
            const chars = Array.from(popup.query);
            chars.pop();
            popup.query = chars.join("");
            popup.clampSel();
          }
        } else if (event.text && event.text.length > 0 &&
                   !(event.modifiers & Qt.ControlModifier) &&
                   !(event.modifiers & Qt.AltModifier) &&
                   !(event.modifiers & Qt.MetaModifier) &&
                   event.key !== Qt.Key_Escape && event.key !== Qt.Key_Return &&
                   event.key !== Qt.Key_Enter && event.key !== Qt.Key_Tab) {
          // the same free-typing filter every focus-less list here uses
          event.accepted = true;
          popup.query += event.text;
          popup.clampSel();
        }
      }

      Column {
        anchors.fill: parent

        Rectangle {
          width: parent.width
          height: 72
          color: popup.msgColor

          Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: popup.msgBorder
          }

          Column {
            anchors.fill: parent
            topPadding: 6

            Item {
              width: parent.width
              height: 32
              Text {
                anchors.centerIn: parent
                // the header doubles as the input, since there is no field
                text: popup.query === ""
                  ? "Notifications" + (Howler.history.length > 0
                      ? "  (" + Howler.history.length + ")" : "")
                  : popup.query
                color: popup.headColor
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 600
                font.pixelSize: 18
              }
            }

            HintBar { width: parent.width }
          }
        }

        Item {
          width: parent.width
          height: popup.bodyH()

          Text {
            anchors.centerIn: parent
            visible: popup.rows.length === 0
            text: popup.query === "" ? "nothing yet" : "no match"
            color: popup.dimColor
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: Font.Bold
            font.pixelSize: 16
          }

          ListView {
            id: list
            anchors.fill: parent
            clip: true
            model: popup.rows
            visible: popup.rows.length > 0
            highlightMoveDuration: 120

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
                color: histRow.index === popup.sel ? popup.selColor : "transparent"
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
                  color: popup.fgColor
                  font.family: "JetBrainsMono Nerd Font Propo"
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
                  color: popup.dimColor
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.pixelSize: 14
                  elide: Text.ElideRight
                }
              }

              // app name and age, right-aligned — until you hover a music
              // entry, where the same slot hands you the transport instead
              Item {
                id: stampBox
                anchors.right: parent.right
                anchors.rightMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                width: 96
                height: parent.height

                Column {
                  id: stampCol
                  anchors.centerIn: parent
                  width: parent.width
                  spacing: 2
                  opacity: 1 - rowTransport.opacity
                  visible: opacity > 0.01

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Wolf.ago(histRow.modelData.time, popup.now)
                    color: popup.keyColor
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.weight: Font.Bold
                    font.pixelSize: 14
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Helpers.collapse(histRow.modelData.appName ?? "")
                    color: popup.dimColor
                    font.family: "JetBrainsMono Nerd Font Propo"
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
                  opacity: (histRow.isSong && rowHover.containsMouse) ? 1 : 0
                  visible: opacity > 0.01
                  Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

                  RowKey {
                    glyph: "\uF04A"
                    onActivated: if (histRow.player) histRow.player.previous();
                  }
                  RowKey {
                    glyph: histRow.player && histRow.player.isPlaying ? "\uF04C" : "\uF04B"
                    onActivated: if (histRow.player) histRow.player.togglePlaying();
                  }
                  RowKey {
                    glyph: "\uF04E"
                    onActivated: if (histRow.player) histRow.player.next();
                  }
                }
              }

              MouseArea {
                id: rowHover
                anchors.fill: parent
                hoverEnabled: true
                // the transport keys sit on top and take their own clicks
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor
                onEntered: popup.sel = histRow.index
                onClicked: popup.removeSelected()
              }
            }
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
    color: popup.fgColor
    font.family: "JetBrainsMono Nerd Font Propo"
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
}
