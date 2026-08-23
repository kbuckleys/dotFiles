// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "../morpheus"
import "folio.js" as Folio

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
  property string mode: "text"
  property string query: ""
  property var entries: []
  property var imageIds: []
  property var rows: []
  property var imgRows: []
  property var thumbsReady: ({})
  property int thumbStamp: 0
  property int sel: 0
  property bool hasText: false
  property bool hasImg: false
  property string lastAction: ""

  property var statusbar: null

  readonly property color bgColor: "#cc000000"
  readonly property color borderColor: "#20242a"
  readonly property color selColor: "#4d45505c"
  readonly property color msgColor: "#66282f36"
  readonly property color msgBorder: "#4d45505c"
  readonly property color fgColor: "#DFDFDD"
  readonly property color hintColor: "#6a707f"

  readonly property int textCellH: 32
  readonly property int textCols: 3
  readonly property int textRows: 12
  readonly property int imgCell: 200
  readonly property int imgRowsVisible: 3
  readonly property int msgH: 28

  readonly property int imgPerRow: Math.max(1, Math.floor(1000 / popup.imgCell))

  readonly property int textColsUsed: popup.query.length > 0 ? 1 : 2
  readonly property int textRowsNeeded: Math.min(Math.max(1, Math.ceil(popup.rows.length / popup.textColsUsed)), popup.textRows)
  readonly property int imgRowsNeeded: Math.min(Math.ceil(popup.imgRows.length / popup.imgPerRow), popup.imgRowsVisible)

  function cellText(preview) {
    const cellW = popup.textColsUsed === 1 ? panel.width : textGrid.cellWidth;
    const avail = Math.max(1, Math.floor((cellW - 32) / textMetrics.advanceWidth));
    const p = preview.length > avail ? preview.slice(0, Math.max(0, avail - 1)) + "…" : preview;
    return Folio.highlightedPreview(p, popup.query);
  }
  readonly property real textCellHeight: popup.textCellH

  readonly property real bodyH: popup.mode === "image"
    ? popup.imgRowsNeeded * popup.imgCell + popup.msgH
    : popup.textRowsNeeded * popup.textCellHeight + popup.msgH

  TextMetrics {
    id: textMetrics
    font.family: "JetBrainsMono Nerd Font Propo"
    font.pixelSize: 16
    font.weight: 600
    text: "M"
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
    onCleared: {
      popup.log("grab cleared");
      popup.closePopup();
    }
  }

  IpcHandler {
    target: "Folio"
    function toggle() {
      popup.toggle();
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      id: out
      waitForEnd: true
      onStreamFinished: popup.onList(out.text)
    }
  }

  Process {
    id: thumbProc
    onExited: popup.onThumbsDone()
  }

  Process {
    id: actionProc
    onExited: popup.onActionDone()
  }

  Process {
    id: logProc
  }

  function log(msg) {
    logProc.command = ["sh", "-c",
      "printf '%s\\n' " + Folio.shellQuote(Qt.formatTime(new Date(), "hh:mm:ss") + " " + msg) +
      " >> /tmp/folio_state.txt"];
    logProc.running = true;
  }

  function openPopup() {
    popup.shown = true;
    popup.collapsing = false;
    popup.mode = "text";
    popup.query = "";
    filter.text = "";
    popup.sel = 0;
    popup.reload();
    focusRetry.counter = 0;
    focusRetry.restart();
    closeAnim.stop();
    popup.showFactor = 0;
    openAnim.restart();
    popup.log("open");
  }

  function closePopup() {
    popup.collapsing = true;
    openAnim.stop();
    closeAnim.restart();
    popup.log("close");
  }

  function toggle() {
    if (popup.shown) popup.closePopup();
    else popup.openPopup();
  }

  function reload() {
    listProc.command = ["cliphist", "-preview-width", "10000", "list"];
    listProc.running = true;
  }

  function onList(text) {
    const parsed = Folio.parseList(text);
    popup.entries = parsed.entries;
    popup.imageIds = parsed.imageIds;
    popup.hasText = parsed.entries.length > 0;
    popup.hasImg = parsed.imageIds.length > 0;

    if (popup.mode === "text" && !popup.hasText && popup.hasImg) popup.mode = "image";
    else if (popup.mode === "image" && !popup.hasImg && popup.hasText) popup.mode = "text";

    popup.rebuildImageRows();
    popup.applyFilter();
    popup.generateThumbs();
    popup.clampSel();
  }

  function rebuildImageRows() {
    const tdir = Folio.thumbDir();
    const arr = [];
    for (let i = 0; i < popup.imageIds.length; ++i) {
      arr.push({ id: popup.imageIds[i], path: tdir + "/" + popup.imageIds[i] + ".png" });
    }
    popup.imgRows = arr;
  }

  function applyFilter() {
    popup.rows = Folio.filterEntries(popup.entries, popup.query);
    popup.clampSel();
  }

  function generateThumbs() {
    if (thumbProc.running) return;
    const cmd = Folio.thumbCommand(popup.imageIds, Folio.thumbDir());
    if (!cmd) return;
    thumbProc.command = ["sh", "-c", cmd];
    thumbProc.running = true;
  }

function onThumbsDone() {

  const ready = {};
  for (const r of popup.imgRows) ready[r.id] = true;
  popup.thumbsReady = ready;
  popup.thumbStamp++;
  popup.followSelection();
}

  function runAction(cmd, kind) {
    popup.lastAction = kind;
    actionProc.command = ["sh", "-c", cmd];
    actionProc.running = true;
  }

  function onActionDone() {
    popup.log("action=" + popup.lastAction);
    if (popup.lastAction === "delete") popup.reload();
    else popup.closePopup();
    popup.lastAction = "";
  }

  function confirm() {
    const len = popup.mode === "image" ? popup.imgRows.length : popup.rows.length;
    if (len === 0) return;
    const id = popup.mode === "image"
      ? popup.imgRows[popup.sel].id
      : popup.rows[popup.sel].id;
    popup.runAction(Folio.copyCommand(id), "copy");
  }

  function openSelected() {
    if (popup.mode !== "image" || popup.imgRows.length === 0) return;
    popup.runAction(Folio.openCommand(popup.imgRows[popup.sel].id, Folio.openDir()), "open");
  }

  function deleteSelected() {
    const len = popup.mode === "image" ? popup.imgRows.length : popup.rows.length;
    if (len === 0) return;
    const id = popup.mode === "image"
      ? popup.imgRows[popup.sel].id
      : popup.rows[popup.sel].id;
    popup.runAction(Folio.deleteCommand(id, Folio.thumbDir()), "delete");
  }

  function toggleMode() {
    const target = popup.mode === "image" ? "text" : "image";
    const avail = target === "text" ? popup.hasText : popup.hasImg;
    popup.log("toggle target=" + target + " avail=" + avail);
    if (!avail || popup.mode === target) return;
    popup.mode = target;
    popup.query = "";
    filter.text = "";
    popup.sel = 0;
    popup.applyFilter();
    popup.followSelection();
    focusRetry.restart();
  }

  function rowCount() {
    return popup.mode === "image" ? popup.imgRows.length : popup.rows.length;
  }

  function stepSel(delta) {
    const len = popup.rowCount();
    if (len === 0) return;
    popup.sel = ((popup.sel + delta) % len + len) % len;
    popup.followSelection();
  }

  function moveVert(delta) {
    const len = popup.rowCount();
    if (len === 0) return;
    const cols = popup.mode === "image" ? popup.imgPerRow : popup.textColsUsed;
    const rows = Math.ceil(len / cols);
    const row = Math.floor(popup.sel / cols);
    const col = popup.sel % cols;
    let newRow = (row + delta) % rows;
    if (newRow < 0) newRow += rows;
    const rowValid = (newRow === rows - 1) ? (len - newRow * cols) : cols;
    const newCol = Math.min(col, rowValid - 1);
    popup.sel = newRow * cols + newCol;
    popup.followSelection();
  }

  function moveHoriz(delta) {
    const len = popup.rowCount();
    if (len === 0) return;
    const cols = popup.mode === "image" ? popup.imgPerRow : popup.textColsUsed;
    const row = Math.floor(popup.sel / cols);
    const col = popup.sel % cols;
    const rowStart = row * cols;
    const rowLen = Math.min(cols, len - rowStart);
    const newCol = (col + delta) % rowLen;
    const adjCol = newCol < 0 ? newCol + rowLen : newCol;
    popup.sel = rowStart + adjCol;
    popup.followSelection();
  }

  function pageMove(delta) {
    const len = popup.rowCount();
    if (len === 0) return;

    const page = popup.mode === "image"
      ? popup.imgPerRow * popup.imgRowsVisible
      : popup.textRowsNeeded * popup.textColsUsed;
    popup.sel = Math.max(0, Math.min(len - 1, popup.sel + delta * page));
    popup.followSelection();
  }

  function goHome() {
    if (popup.rowCount() > 0) popup.sel = 0;
    popup.followSelection();
  }

  function goEnd() {
    const len = popup.rowCount();
    if (len > 0) popup.sel = len - 1;
    popup.followSelection();
  }

  function clampSel() {
    const len = popup.rowCount();
    if (len === 0) popup.sel = 0;
    else if (popup.sel >= len) popup.sel = len - 1;
    else if (popup.sel < 0) popup.sel = 0;
    popup.followSelection();
  }

  function followSelection() {
    Qt.callLater(() => {
      textGrid.positionViewAtIndex(popup.sel, ListView.Contain);
      imgGrid.positionViewAtIndex(popup.sel, ListView.Contain);
    });
  }

  MouseArea {
    id: closeArea
    anchors.fill: parent
    z: 0
    onClicked: popup.closePopup()
  }

  // shell.qml sizes the morphed pill from this; without it the pill fell back
  // to a hardcoded 320px and the panel floated free of its own background
  function calcHeight() {
    return popup.bodyH;
  }

  Item {
    id: panel
    width: 1000
    height: popup.bodyH
    // Zenon.slow is the pill's own height easing in shell.qml; if these drift
    // apart the panel visibly detaches from its background mid-resize
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
      id: bg
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

      Column {
      anchors.fill: parent

      Item {
        id: body
        width: parent.width
        height: parent.height - msgBar.height

          Text {
            id: emptyLabel
            anchors.centerIn: parent
            text: "No clipboard entries"
            color: popup.hintColor
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: 600
            font.pixelSize: 13
            visible: popup.shown && !popup.hasText && !popup.hasImg
          }

          Text {
            anchors.centerIn: parent
            text: "No matches found"
            color: popup.hintColor
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: 600
            font.pixelSize: 15
            visible: popup.shown && popup.mode === "text" && popup.rows.length === 0 && popup.hasText
          }

        Item {
          id: textPane
          anchors.fill: parent
          visible: opacity > 0.01
          opacity: popup.mode === "text" ? 1 : 0
          x: popup.mode === "text" ? 0 : -24
          Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
          Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

          GridView {
            id: textGrid
            anchors.fill: parent
            clip: true
            flow: GridView.FlowLeftToRight
            cellWidth: textGrid.width / popup.textColsUsed
            cellHeight: popup.textCellHeight
            model: popup.rows
            highlightMoveDuration: 120

            delegate: Item {
              required property var modelData
              required property int index
              width: textGrid.cellWidth
              height: textGrid.cellHeight

              Rectangle {
                anchors.fill: parent
                color: index === popup.sel ? popup.selColor : "transparent"
              }

              Text {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                text: popup.cellText(modelData.preview)
                color: popup.fgColor
                textFormat: Text.RichText
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 600
                font.pixelSize: 16
                clip: true
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                horizontalAlignment: Text.AlignLeft
                verticalAlignment: Text.AlignVCenter
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  popup.sel = index;
                  popup.confirm();
                }
              }
            }
          }
        }

        Item {
          id: imgPane
          anchors.fill: parent
          visible: opacity > 0.01
          opacity: popup.mode === "image" ? 1 : 0
          x: popup.mode === "image" ? 0 : 24
          Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
          Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

          GridView {
            id: imgGrid
            anchors.fill: parent
            clip: true
            flow: GridView.FlowLeftToRight
            cellWidth: popup.imgCell
            cellHeight: popup.imgCell
            model: popup.imgRows
            highlightMoveDuration: 120

            delegate: Item {
              required property var modelData
              required property int index
              width: imgGrid.cellWidth
              height: imgGrid.cellHeight

              Rectangle {
                anchors.fill: parent
                anchors.margins: 2
                radius: 10
                color: "transparent"
                border.color: index === popup.sel ? "#6a707f" : "transparent"
                border.width: index === popup.sel ? 2 : 0

                Image {
                  anchors.fill: parent
                  anchors.margins: 4
                  source: popup.thumbsReady[modelData.id]
                    ? "file://" + modelData.path + "?v=" + popup.thumbStamp
                    : ""
                  asynchronous: true
                  fillMode: Image.PreserveAspectFit
                  sourceSize.width: popup.imgCell
                  sourceSize.height: popup.imgCell
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  popup.sel = index;
                  popup.confirm();
                }
              }
            }
          }
        }
      }

      Rectangle {
        id: msgBar
        width: parent.width
        height: popup.msgH
        color: popup.msgColor

        Rectangle {
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: 1
          color: popup.msgBorder
        }

        Row {
          anchors.centerIn: parent
          spacing: 32

          Repeater {
            model: Folio.hintText(popup.mode)
            Text {
              required property var modelData
              text: modelData
              color: popup.hintColor
              textFormat: Text.RichText
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 600
              font.pixelSize: 14
              verticalAlignment: Text.AlignVCenter
            }
          }
        }
      }
    }

    TextInput {
      id: filter
      width: 1
      height: 1
      x: -1
      y: -1
      opacity: 0
      focus: true
      color: "transparent"
      Keys.forwardTo: bg
      onTextChanged: {
        if (popup.mode === "text") {
          popup.query = filter.text;
          popup.sel = 0;
          popup.applyFilter();
        }
      }
    }

    Keys.onEscapePressed: (event) => {
      event.accepted = true;
      if (filter.text !== "") {
        filter.text = "";
        popup.query = "";
      } else {
        popup.closePopup();
      }
    }

    Keys.onReturnPressed: (event) => {
      event.accepted = true;
      if (event.modifiers & Qt.ShiftModifier) popup.openSelected();
      else popup.confirm();
    }

    Keys.onTabPressed: (event) => {
      event.accepted = true;
      popup.toggleMode();
    }

    Keys.onBacktabPressed: (event) => {
      event.accepted = true;
      popup.toggleMode();
    }

    Keys.onLeftPressed: (event) => { event.accepted = true; popup.moveHoriz(-1); }
    Keys.onRightPressed: (event) => { event.accepted = true; popup.moveHoriz(1); }
    Keys.onUpPressed: (event) => { event.accepted = true; popup.moveVert(-1); }
    Keys.onDownPressed: (event) => { event.accepted = true; popup.moveVert(1); }

    Keys.onPressed: (event) => {
      if ((event.key === Qt.Key_C) && (event.modifiers & Qt.AltModifier)) {
        event.accepted = true;
        filter.text = "";
        popup.query = "";
      } else if (event.key === Qt.Key_Delete) {
        event.accepted = true;
        popup.deleteSelected();
      } else if (event.key === Qt.Key_Backspace) {
        event.accepted = true;
        if (filter.text.length > 0) {
          const chars = Array.from(filter.text);
          chars.pop();
          filter.text = chars.join("");
        }
      } else if (event.key === Qt.Key_Home) {
        event.accepted = true;
        popup.goHome();
      } else if (event.key === Qt.Key_End) {
        event.accepted = true;
        popup.goEnd();
      } else if (event.key === Qt.Key_PageUp) {
        event.accepted = true;
        popup.pageMove(-1);
      } else if (event.key === Qt.Key_PageDown) {
        event.accepted = true;
        popup.pageMove(1);
      }
    }
    }
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
      filter.forceActiveFocus();
      if (filter.activeFocus) stop();
      if (focusRetry.counter++ > 12) stop();
    }
    property int counter: 0
  }
}
