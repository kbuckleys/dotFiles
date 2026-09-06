// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// The setter. Pick a wallpaper in the grid, then pick where it goes from the
// strip along the bottom — the same two-step shape ideo uses to choose an
// icon and then its format.

import QtQuick
import QtQuick.Window
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
  // Math.min, not morphFade alone. Handing the pill straight to another
  // layer leaves morphFade pinned at 1 — the pill never un-morphs, so there
  // is nothing to ease it down — and this layer stayed fully opaque until its
  // window simply blinked out. Its own closeAnim is already easing
  // showFactor to 0, so taking the lower of the two fades it out on the way
  // between layers while leaving the normal open schedule untouched.
  readonly property real contentFade: popup.morphMode
    ? Math.min(popup.morphFade, popup.showFactor) : popup.showFactor

  property var statusbar: null

  readonly property color bgColor: Zenon.layerBg
  readonly property color borderColor: Zenon.surface
  readonly property color msgColor: Zenon.headBg
  readonly property color msgBorder: Zenon.msgBorder
  readonly property color fgColor: Zenon.white
  readonly property color headColor: Zenon.cyan
  readonly property color keyColor: Zenon.keyInk
  readonly property color dimColor: Zenon.muted
  readonly property color entryColor: Zenon.pink
  readonly property color selColor: Zenon.selBg

  property string query: ""
  property int sel: 0

  // second step: which monitor the picked wallpaper goes to
  property bool targetMode: false
  property int targetSel: 0

  // Filter first, then order: the sort only has to touch what survived, and
  // the two are separate questions the user changes independently.
  readonly property var filtered: Art.sortRows(
    Art.filter(Picasso.files, popup.query, Picasso.dir),
    Picasso.sortMode, Picasso.dir)

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
    if (popup.filtered.length === 0)
      return popup.query === "" ? [["esc", "close"]] : [["esc", "clear"]];
    return [["type", "filter"], ["alt s", "sort"],
            ["return", "choose target"], ["esc", "clear · close"]];
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
            Strings.escapeHtml(modelData[0]) + "</span></b> <span style=\"color:" +
            popup.dimColor + ";\">" + Strings.escapeHtml(modelData[1]) + "</span>"
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
    const path = popup.filtered[Math.min(popup.sel, popup.filtered.length - 1)].path;
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

    LayerShadow {
      panel: bgRoot
      cornerRadius: bgRoot.radius
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

        if (event.key === Qt.Key_S && (event.modifiers & Qt.AltModifier)) {
          event.accepted = true;
          Picasso.cycleSort();
          // the row under the cursor is meaningless once the order changes
          popup.sel = 0;
          popup.followSelection();
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
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
                color: Zenon.surface

                Image {
                  id: thumb
                  anchors.fill: parent
                  // The cached thumbnail, not the original: these are ~70KB
                  // against 8MB, and the grid rebuilds on every keystroke.
                  // Falls back to the original if a thumbnail could not be
                  // generated, so a picker that cannot thumbnail still works.
                  property bool thumbFailed: false
                  readonly property string thumbPath: cell.modelData.thumb ?? ""
                  source: (thumb.thumbPath !== "" && !thumb.thumbFailed)
                    ? "file://" + thumb.thumbPath
                    : "file://" + cell.modelData.path
                  onStatusChanged: {
                    if (status === Image.Error && !thumb.thumbFailed)
                      thumb.thumbFailed = true;
                  }
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  // Decoded at the size of the box it is drawn in, not at the
                  // size of the file. The thumbnails are 480px square and this
                  // box is 222x98, so without this every cell carries about
                  // five times the pixels it can show — measured over the whole
                  // library that is 193MB of grid against 105MB, and the grid
                  // does not give it back when it scrolls away.
                  //
                  // It matters far more on the fallback line above. A wallpaper
                  // whose thumbnail is missing is shown FROM THE ORIGINAL, and
                  // the originals here run to 7276x4895 — 135MB of RGBA for one
                  // cell 222 pixels wide.
                  //
                  // Both axes, which is safe on Image: it scales to cover the
                  // box with the aspect ratio intact. (AnimatedImage does not —
                  // see the Wall component in PicassoDaemon.qml.)
                  sourceSize.width: Math.ceil(thumbBox.width * thumb.Screen.devicePixelRatio)
                  sourceSize.height: Math.ceil(thumbBox.height * thumb.Screen.devicePixelRatio)
                  // Safe to cache now. The cache filename carries the source's
                  // mtime and size, so a replaced wallpaper is a different URL
                  // — Qt can no longer pin a stale decode failure to it.
                  cache: true
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
                visible: popup.inUse(cell.modelData.path)
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
                text: Art.label(cell.modelData.path)
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
              // Doubles as the input, since there is no field — the same shape
              // howler uses. What you type lands here, and esc empties it.
              text: popup.query !== "" ? popup.query
                : (Picasso.scanning ? "scanning…"
                    : popup.filtered.length + (popup.filtered.length === 1
                        ? " Wallpaper" : " Wallpapers")
                      + "  󰇘  " + Picasso.sortMode)
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
