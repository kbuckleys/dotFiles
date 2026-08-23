// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "scout.js" as Scout
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
  readonly property real contentFade: popup.morphMode ? popup.morphFade : popup.showFactor

  property string query: ""
  property var entries: []
  property var rows: []
  property int sel: 0
  property var statusbar: null
  property string searchRoot: Quickshell.env("HOME")
  property int maxDepth: 8
  property string lastAction: ""
  property string flashSrc: ""
  property int flashSeq: 0

  readonly property color bgColor: "#cc000000"
  readonly property color borderColor: "#20242a"
  readonly property color selColor: "#4d45505c"
  readonly property color msgColor: "#66282f36"
  readonly property color msgBorder: "#4d45505c"
  readonly property color fgColor: "#DFDFDD"
  readonly property color hintColor: "#6a707f"

  readonly property int textCellH: 32
  readonly property int textCols: 1
  readonly property int textRows: 12
  readonly property int msgH: 28
  readonly property int textColsUsed: 1
  readonly property int textRowsNeeded: Math.min(Math.max(1, Math.ceil(popup.rows.length / popup.textColsUsed)), popup.textRows)
  readonly property real textCellHeight: popup.textCellH
  readonly property real bodyH: popup.textRowsNeeded * popup.textCellHeight + popup.msgH + (popup.query.length > 0 ? 36 : 0)

  TextMetrics {
    id: textMetrics
    font.family: "JetBrainsMono Nerd Font Propo"
    font.pixelSize: 16
    font.weight: 600
    text: "M"
  }

  function cellText(preview) {
    const cellW = popup.implicitWidth
    const avail = Math.max(1, Math.floor((cellW - 32) / textMetrics.advanceWidth))
    const p = preview.length > avail ? preview.slice(0, Math.max(0, avail - 1)) + "…" : preview
    return Scout.highlightedPreview(p, popup.query)
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
    target: "Scout"
    function toggle() {
      popup.toggle();
    }
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      id: out
      waitForEnd: true
      onStreamFinished: popup.onSearch(out.text)
    }
  }

  Process {
    id: actionProc
    onExited: popup.onActionDone()
  }

  Process {
    id: logProc
  }

  function log(msg) {
    logProc.command = ["sh", "-c", "printf '%s\\n' " + Scout.shellQuote(Qt.formatTime(new Date(), "hh:mm:ss") + " " + msg) + " >> /tmp/scout_state.txt"]
    logProc.running = true
  }

  function openPopup() {
    popup.shown = true
    popup.collapsing = false
    popup.query = ""
    searchInput.text = ""
    popup.sel = 0
    popup.reload()
    focusRetry.counter = 0
    focusRetry.restart()
    closeAnim.stop()
    popup.showFactor = 0
    openAnim.restart()
    popup.log("open")
  }

  function closePopup() {
    popup.collapsing = true
    openAnim.stop()
    closeAnim.restart()
    popup.log("close")
  }

  function toggle() {
    if (popup.shown) popup.closePopup()
    else popup.openPopup()
  }

  function reload() {
    const root = popup.searchRoot || Quickshell.env("HOME")
    const cmd = Scout.searchCommand(root, popup.maxDepth, "")
    searchProc.command = ["sh", "-c", cmd]
    searchProc.running = true
  }

  function doSearch() {
    const root = popup.searchRoot || Quickshell.env("HOME")
    const cmd = Scout.searchCommand(root, popup.maxDepth, popup.query)
    if (searchProc.running) searchProc.running = false
    searchProc.command = ["sh", "-c", cmd]
    searchProc.running = true
  }

  function onSearch(text) {
    popup.entries = Scout.parseResults(text)
    popup.applyFilter()
  }

  function applyFilter() {
    if (popup.query.trim() !== "") {
      popup.rows = Scout.filterEntries(popup.entries, popup.query)
    } else {
      popup.rows = popup.entries.slice(0, 200)
    }
    popup.clampSel()
  }

  function runAction(cmd, kind) {
    popup.lastAction = kind
    actionProc.command = ["sh", "-c", cmd]
    actionProc.running = true
  }

  function onActionDone() {
    popup.log("action=" + popup.lastAction)
    popup.closePopup()
    popup.lastAction = ""
  }

  function confirm() {
    if (popup.rows.length === 0) return
    const path = popup.rows[popup.sel].path
    popup.runAction(Scout.openCommand(path), "open")
  }

  function rowCount() {
    return popup.rows.length
  }

  function stepSel(delta) {
    const len = popup.rowCount()
    if (len === 0) return
    popup.sel = ((popup.sel + delta) % len + len) % len
    popup.followSelection()
  }

  function moveVert(delta) {
    const len = popup.rowCount()
    if (len === 0) return
    const cols = popup.textColsUsed
    const rows = Math.ceil(len / cols)
    const row = Math.floor(popup.sel / cols)
    const col = popup.sel % cols
    let newRow = (row + delta) % rows
    if (newRow < 0) newRow += rows
    const rowValid = (newRow === rows - 1) ? (len - newRow * cols) : cols
    const newCol = Math.min(col, rowValid - 1)
    popup.sel = newRow * cols + newCol
    popup.followSelection()
  }

  function moveHoriz(delta) {
    const len = popup.rowCount()
    if (len === 0) return
    const cols = popup.textColsUsed
    if (cols <= 1) {
      popup.stepSel(delta)
      return
    }
    const row = Math.floor(popup.sel / cols)
    const col = popup.sel % cols
    const rowStart = row * cols
    const rowLen = Math.min(cols, len - rowStart)
    const newCol = (col + delta) % rowLen
    const adjCol = newCol < 0 ? newCol + rowLen : newCol
    popup.sel = rowStart + adjCol
    popup.followSelection()
  }

  function pageMove(delta) {
    const len = popup.rowCount()
    if (len === 0) return
    const page = popup.textRowsNeeded * popup.textColsUsed
    popup.sel = Math.max(0, Math.min(len - 1, popup.sel + delta * page))
    popup.followSelection()
  }

  function goHome() {
    if (popup.rowCount() > 0) popup.sel = 0
    popup.followSelection()
  }

  function goEnd() {
    const len = popup.rowCount()
    if (len > 0) popup.sel = len - 1
    popup.followSelection()
  }

  function clampSel() {
    const len = popup.rowCount()
    if (len === 0) popup.sel = 0
    else if (popup.sel >= len) popup.sel = len - 1
    else if (popup.sel < 0) popup.sel = 0
    popup.followSelection()
  }

  function followSelection() {
    Qt.callLater(() => {
      fileGrid.positionViewAtIndex(popup.sel, GridView.Contain)
    })
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

        Rectangle {
          id: inputBar
          width: parent.width
          height: searchInput.text.length > 0 ? 36 : 0
          visible: height > 0.5
          clip: true
          color: "transparent"
          Behavior on height { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

          Row {
            anchors.fill: parent
            anchors.leftMargin: 10
            spacing: 0

            Text {
              id: promptText
              width: 30
              height: parent.height
              text: ""
              visible: searchInput.text.length > 0
              color: "#c8a4e0"
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 18
              verticalAlignment: Text.AlignVCenter
            }

            TextInput {
              id: searchInput
              width: parent.width - promptText.width
              height: parent.height
              color: "#c8a4e0"
              selectionColor: "#c8a4e0"
              selectedTextColor: "#000000"
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 18
              verticalAlignment: Text.AlignVCenter
              focus: true
              cursorVisible: false
              cursorDelegate: Item {}
              clip: true
              Keys.forwardTo: bg
              onTextChanged: {
                popup.query = searchInput.text
                popup.sel = 0
                if (popup.query.trim() === "") {
                  popup.applyFilter()
                } else {
                  searchDebounce.restart()
                }
              }

              Rectangle {
                id: pulseCursor
                anchors.left: parent.left
                anchors.leftMargin: Math.min(searchInput.contentWidth, searchInput.width - pulseCursor.width)
                anchors.verticalCenter: searchInput.verticalCenter
                width: 3
                height: 20
                radius: 1
                color: "#c8a4e0"
                opacity: 0.25
                visible: searchInput.text.length > 0
                SequentialAnimation on opacity {
                  running: searchInput.activeFocus && searchInput.text.length > 0
                  loops: Animation.Infinite
                  NumberAnimation { to: 1; duration: 550; easing.type: Easing.InOutSine }
                  NumberAnimation { to: 0.25; duration: 550; easing.type: Easing.InOutSine }
                }
              }
            }
          }
        }

        Item {
          id: body
          width: parent.width
          height: parent.height - inputBar.height - msgBar.height

          Text {
            id: emptyLabel
            anchors.centerIn: parent
            text: "No matches found"
            color: popup.hintColor
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: 600
            font.pixelSize: 15
            visible: popup.shown && popup.rows.length === 0
          }

          GridView {
            id: fileGrid
            anchors.fill: parent
            clip: true
            flow: GridView.FlowTopToBottom
            cellWidth: fileGrid.width
            cellHeight: popup.textCellHeight
            model: popup.rows
            highlightMoveDuration: 120

            delegate: Item {
              required property var modelData
              required property int index
              width: fileGrid.cellWidth
              height: fileGrid.cellHeight

              Rectangle {
                anchors.fill: parent
                color: index === popup.sel ? popup.selColor : "transparent"
              }

              Text {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                text: {
                  const p = modelData.preview
                  const cellW = fileGrid.cellWidth
                  const avail = Math.max(1, Math.floor((cellW - 32) / textMetrics.advanceWidth))
                  const t = p.length > avail ? p.slice(0, Math.max(0, avail - 1)) + "…" : p
                  return Scout.highlightedPreview(t, popup.query)
                }
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

              Item {
                anchors.fill: parent
                clip: true
                visible: swoop.opacity > 0
                Rectangle {
                  id: swoop
                  width: parent.width
                  height: parent.height
                  opacity: 0
                  gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Qt.rgba(200/255, 164/255, 224/255, 0) }
                    GradientStop { position: 0.55; color: Qt.rgba(200/255, 164/255, 224/255, 0.55) }
                    GradientStop { position: 0.78; color: Qt.rgba(223/255, 221/255, 221/255, 0.75) }
                    GradientStop { position: 1.0; color: Qt.rgba(223/255, 221/255, 221/255, 0) }
                  }
                  ParallelAnimation {
                    id: swoopAnim
                    NumberAnimation { target: swoop; property: "x"; from: -swoop.width; to: swoop.width; duration: 440; easing.type: Easing.OutCubic }
                    SequentialAnimation {
                      NumberAnimation { target: swoop; property: "opacity"; from: 0; to: 1; duration: 90 }
                      NumberAnimation { target: swoop; property: "opacity"; to: 0; duration: 350; easing.type: Easing.InCubic }
                    }
                  }
                }
                Connections {
                  target: popup
                  function onFlashSeqChanged() {
                    if (popup.flashSrc === modelData.path) swoopAnim.restart()
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  popup.sel = index
                  popup.confirm()
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
              model: Scout.hintText()
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

      Keys.onEscapePressed: (event) => {
        event.accepted = true;
        if (searchInput.text !== "") {
          searchInput.text = "";
        } else {
          popup.closePopup();
        }
      }
      Keys.onReturnPressed: (event) => {
        event.accepted = true
        popup.confirm()
      }
      Keys.onLeftPressed: (event) => { event.accepted = true; popup.moveHoriz(-1) }
      Keys.onRightPressed: (event) => { event.accepted = true; popup.moveHoriz(1) }
      Keys.onUpPressed: (event) => { event.accepted = true; popup.moveVert(-1) }
      Keys.onDownPressed: (event) => { event.accepted = true; popup.moveVert(1) }
      Keys.onPressed: (event) => {
        if (event.key === Qt.Key_PageUp) {
          event.accepted = true
          popup.pageMove(-1)
        } else if (event.key === Qt.Key_PageDown) {
          event.accepted = true
          popup.pageMove(1)
        } else if (event.key === Qt.Key_Home) {
          event.accepted = true
          popup.goHome()
        } else if (event.key === Qt.Key_End) {
          event.accepted = true
          popup.goEnd()
        } else if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_C) {
          // copy only. Clearing the search box is esc's job in every layer,
          // and overloading alt c meant the hint bar could only ever describe
          // half of what the key did.
          event.accepted = true
          if (popup.rows.length > 0) {
            const path = popup.rows[popup.sel].path
            Quickshell.execDetached(["sh", "-c", "printf '%s' " + Scout.shellQuote(path) + " | wl-copy 2>/dev/null"])
            popup.flashSrc = path
            popup.flashSeq++
            popup.log("copy " + path)
          }
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
        stop()
        return
      }
      searchInput.forceActiveFocus()
      if (searchInput.activeFocus) stop()
      if (focusRetry.counter++ > 12) stop()
    }
    property int counter: 0
  }

  Timer {
    id: searchDebounce
    interval: 200
    repeat: false
    onTriggered: popup.doSearch()
  }
}
