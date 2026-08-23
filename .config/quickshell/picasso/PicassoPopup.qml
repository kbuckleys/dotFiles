// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// The setter. Pick a wallpaper in the grid, then pick where it goes from the
// strip along the bottom — the same two-step shape ideo uses to choose an
// icon and then its format.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import "../morpheus"
import "picasso.js" as Art

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
  readonly property real contentFade: popup.morphMode ? popup.morphFade : popup.showFactor

  property var statusbar: null

  readonly property color bgColor: "#cc000000"
  readonly property color borderColor: "#20242a"
  readonly property color msgColor: "#66282f36"
  readonly property color msgBorder: "#4d45505c"
  readonly property color fgColor: "#DFDFDD"
  readonly property color headColor: "#9bbfbf"
  readonly property color keyColor: "#a2a8bc"
  readonly property color dimColor: "#6a707f"
  readonly property color entryColor: "#eebebe"
  readonly property color selColor: "#4d45505c"

  property string query: ""
  property int sel: 0

  // second step: which monitor the picked wallpaper goes to
  property bool targetMode: false
  property int targetSel: 0

  readonly property var filtered: Art.filter(Picasso.files, popup.query)

  // "All monitors" first, then one entry per connected output. Built from the
  // live screen list, so plugging a monitor in adds its option with no edit.
  readonly property var targets: {
    const out = [{ key: Picasso.fallbackKey, label: "All monitors" }];
    const screens = Quickshell.screens;
    for (let i = 0; i < screens.length; ++i)
      out.push({ key: screens[i].name, label: screens[i].name });
    return out;
  }

  readonly property int cols: 4
  readonly property int visibleRows: 3
  readonly property int cellW: 1000 / popup.cols
  readonly property int cellH: 150

  function hints() {
    if (popup.targetMode)
      return [["left/right", "choose"], ["return", "set"], ["backspace", "back"]];
    if (popup.filtered.length === 0) return [["esc", "close"]];
    return [["type", "filter"], ["return", "choose target"], ["esc", "clear · close"]];
  }

  function gridHeight() {
    if (popup.filtered.length === 0) return 90;
    const rows = Math.ceil(popup.filtered.length / popup.cols);
    return Math.max(1, Math.min(rows, popup.visibleRows)) * popup.cellH;
  }

  // the bottom strip is the ideo shape: 26 while choosing a target, the
  // usual count-plus-hints otherwise
  function stripHeight() { return popup.targetMode ? 26 : 54; }

  function calcHeight() {
    return popup.gridHeight() + popup.stripHeight();
  }

  component HintBar: Item {
    id: hintBarRoot
    height: 30
    property var rows: popup.hints()
    Row {
      anchors.centerIn: parent
      spacing: 22
      Repeater {
        model: hintBarRoot.rows
        Text {
          required property var modelData
          text: "<b><span style=\"color:" + popup.keyColor + ";\">" +
            Art.escapeHtml(modelData[0]) + "</span></b> <span style=\"color:" +
            popup.dimColor + ";\">" + Art.escapeHtml(modelData[1]) + "</span>"
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
    target: "Picasso"

    function toggle() { popup.toggle(); }
    function rescan(): string { Picasso.scan(); return "scanning"; }
    function status(): string {
      return "dir=" + Picasso.dir + " files=" + Picasso.files.length
        + " assignment=" + JSON.stringify(Picasso.assignment);
    }
  }

  // ---------------------------------------------------------- actions --

  function openPopup() {
    popup.shown = true;
    popup.collapsing = false;
    popup.query = "";
    popup.sel = 0;
    popup.targetMode = false;
    popup.targetSel = 0;
    Picasso.scan();
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
    const len = popup.filtered.length;
    if (len === 0) popup.sel = 0;
    else popup.sel = Math.max(0, Math.min(popup.sel, len - 1));
    followSelection();
  }

  function moveSel(delta) {
    const len = popup.filtered.length;
    if (len === 0) return;
    popup.sel = Math.max(0, Math.min(popup.sel + delta, len - 1));
    followSelection();
  }

  function followSelection() {
    Qt.callLater(() => grid.positionViewAtIndex(popup.sel, GridView.Contain));
  }

  function chooseTarget() {
    if (popup.filtered.length === 0) return;
    popup.targetMode = true;
    popup.targetSel = 0;
  }

  function applyTarget() {
    if (popup.filtered.length === 0) return;
    const path = popup.filtered[Math.min(popup.sel, popup.filtered.length - 1)];
    const t = popup.targets[Math.min(popup.targetSel, popup.targets.length - 1)];
    if (t.key === Picasso.fallbackKey) Picasso.setAll(path);
    else Picasso.setFor(t.key, path);
    popup.targetMode = false;
    popup.closePopup();
  }

  // ------------------------------------------------------------ panel --

  MouseArea {
    anchors.fill: parent
    z: 0
    onClicked: popup.closePopup()
  }

  Item {
    id: panel
    width: 1000
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

    Rectangle {
      id: bgRoot
      anchors.fill: parent
      color: popup.morphMode ? "transparent" : popup.bgColor
      radius: 10
      border.color: popup.morphMode ? "transparent" : popup.borderColor
      border.width: 1
      clip: true
      focus: true

      Keys.onEscapePressed: (event) => {
        event.accepted = true;
        if (popup.targetMode) popup.targetMode = false;
        else if (popup.query !== "") popup.query = "";
        else popup.closePopup();
      }

      Keys.onPressed: (event) => {
        if (popup.targetMode) {
          const n = popup.targets.length;
          if (event.key === Qt.Key_Left) {
            event.accepted = true;
            popup.targetSel = (popup.targetSel + n - 1) % n;
          } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
            event.accepted = true;
            popup.targetSel = (popup.targetSel + 1) % n;
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            event.accepted = true;
            popup.applyTarget();
          } else if (event.key === Qt.Key_Backspace) {
            event.accepted = true;
            popup.targetMode = false;
          }
          return;
        }

        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          event.accepted = true;
          popup.chooseTarget();
        } else if (event.key === Qt.Key_Left) {
          event.accepted = true; popup.moveSel(-1);
        } else if (event.key === Qt.Key_Right) {
          event.accepted = true; popup.moveSel(1);
        } else if (event.key === Qt.Key_Up) {
          event.accepted = true; popup.moveSel(-popup.cols);
        } else if (event.key === Qt.Key_Down) {
          event.accepted = true; popup.moveSel(popup.cols);
        } else if (event.key === Qt.Key_PageUp) {
          event.accepted = true; popup.moveSel(-popup.cols * popup.visibleRows);
        } else if (event.key === Qt.Key_PageDown) {
          event.accepted = true; popup.moveSel(popup.cols * popup.visibleRows);
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
                   event.key !== Qt.Key_Escape && event.key !== Qt.Key_Tab) {
          event.accepted = true;
          popup.query += event.text;
          popup.clampSel();
        }
      }

      Column {
        anchors.fill: parent

        // ------------------------------------------------- the grid --
        Item {
          width: parent.width
          height: popup.gridHeight()

          Text {
            anchors.centerIn: parent
            visible: popup.filtered.length === 0
            text: Picasso.scanning ? "scanning…"
              : (Picasso.files.length === 0
                  ? "no wallpapers in " + Picasso.dir
                  : "no match")
            color: popup.dimColor
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: Font.Bold
            font.pixelSize: 16
          }

          GridView {
            id: grid
            anchors.fill: parent
            clip: true
            visible: popup.filtered.length > 0
            model: popup.filtered
            cellWidth: popup.cellW
            cellHeight: popup.cellH
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
              id: cell
              required property var modelData
              required property int index
              width: popup.cellW
              height: popup.cellH

              readonly property bool selected: cell.index === popup.sel

              Rectangle {
                anchors.fill: parent
                anchors.margins: 6
                radius: 6
                color: cell.selected ? popup.selColor : "transparent"
              }

              ClippingRectangle {
                id: thumbBox
                anchors.top: parent.top
                anchors.topMargin: 12
                anchors.horizontalCenter: parent.horizontalCenter
                width: popup.cellW - 28
                height: popup.cellH - 52
                radius: 5
                color: "#20242a"

                Image {
                  id: thumb
                  anchors.fill: parent
                  source: "file://" + cell.modelData
                  fillMode: Image.PreserveAspectCrop
                  // decode at thumbnail scale — a grid of full 4K decodes
                  // would stall the shell every time the filter changed
                  sourceSize.width: 320
                  asynchronous: true
                  // NOT cached. A file dropped in here is often still being
                  // written when the directory watcher first sees it, and Qt
                  // caches the resulting decode failure against the URL — so
                  // a wallpaper that arrived mid-copy stayed permanently blank
                  // even after it finished. Re-decoding at 320px is cheap.
                  cache: false
                }

                // An image Qt cannot decode used to leave a plain empty box,
                // indistinguishable from a very dark wallpaper. Say so.
                Text {
                  anchors.centerIn: parent
                  visible: thumb.status === Image.Error
                  text: "\uF071"
                  color: popup.dimColor
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.pixelSize: 22
                }

                Text {
                  anchors.centerIn: parent
                  visible: thumb.status === Image.Loading
                  text: "\uF110"
                  color: popup.dimColor
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.pixelSize: 18
                }
              }

              // a corner tick on whatever is currently on a monitor, so the
              // grid says what is already in use without being opened twice
              Rectangle {
                anchors.right: thumbBox.right
                anchors.top: thumbBox.top
                anchors.margins: 4
                width: 18
                height: 18
                radius: 9
                visible: popup.inUse(cell.modelData)
                color: popup.entryColor
                Text {
                  anchors.centerIn: parent
                  text: ""
                  color: "#000000"
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.pixelSize: 11
                }
              }

              Text {
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 12
                anchors.horizontalCenter: parent.horizontalCenter
                width: popup.cellW - 28
                text: Art.label(cell.modelData)
                color: cell.selected ? popup.entryColor : popup.dimColor
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: cell.selected ? Font.Bold : Font.Normal
                font.pixelSize: 13
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: if (!popup.targetMode) popup.sel = cell.index
                onClicked: { popup.sel = cell.index; popup.chooseTarget(); }
              }
            }
          }
        }

        // --------------------------------------------- bottom strip --
        Rectangle {
          width: parent.width
          height: popup.stripHeight()
          color: popup.msgColor
          Behavior on height { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

          Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: popup.msgBorder
          }

          Column {
            anchors.fill: parent
            topPadding: popup.targetMode ? 0 : 6
            bottomPadding: popup.targetMode ? 0 : 6
            spacing: -2

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: !popup.targetMode
              text: Picasso.scanning ? "scanning…"
                : popup.filtered.length + (popup.filtered.length === 1
                    ? " Wallpaper" : " Wallpapers")
              color: popup.headColor
              font.bold: true
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 600
              font.pixelSize: 15
            }

            HintBar {
              width: parent.width
              visible: !popup.targetMode
            }

            Row {
              id: targetRow
              width: parent.width
              visible: popup.targetMode

              Repeater {
                model: popup.targets

                delegate: Item {
                  required property var modelData
                  required property int index
                  width: targetRow.width / popup.targets.length
                  height: 26

                  Rectangle {
                    anchors.fill: parent
                    color: popup.targetSel === index ? "#4de78284" : "transparent"
                  }

                  Text {
                    anchors.centerIn: parent
                    text: modelData.label
                    color: popup.targetSel === index ? popup.entryColor : popup.dimColor
                    font.bold: popup.targetSel === index
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 14
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      popup.targetSel = index;
                      popup.applyTarget();
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // is this file currently painted on any monitor
  function inUse(path) {
    const a = Picasso.assignment;
    for (const k in a) if (a[k] === path) return true;
    return false;
  }
}
