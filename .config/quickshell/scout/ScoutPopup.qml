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
  // Math.min, not morphFade alone. Handing the pill straight to another
  // layer leaves morphFade pinned at 1 — the pill never un-morphs, so there
  // is nothing to ease it down — and this layer stayed fully opaque until its
  // window simply blinked out. Its own closeAnim is already easing
  // showFactor to 0, so taking the lower of the two fades it out on the way
  // between layers while leaving the normal open schedule untouched.
  readonly property real contentFade: popup.morphMode
    ? Math.min(popup.morphFade, popup.showFactor) : popup.showFactor

  property string query: ""
  property var entries: []
  property var rows: []
  property int sel: 0
  property var statusbar: null
  property string searchRoot: Quickshell.env("HOME")

  // ── the index ────────────────────────────────────────────────────────
  // Where the walk gets written, and when it last happened. The file itself
  // is never read into QML — only fzf opens it — so its size costs the
  // engine nothing.
  readonly property string indexPath: Quickshell.cachePath("scout-index")
  readonly property int indexMaxAge: 5 * 60 * 1000
  property double indexedAt: 0
  property bool indexing: false
  property bool searching: false

  // Folders are in the index too; this narrows to them.
  property bool dirsOnly: false

  // Results can arrive out of order — a search is a process, killing one is
  // asynchronous, and a slow reply could otherwise land on top of a newer
  // one. Only the newest generation is allowed to write rows.
  property int searchGen: 0

  // The query the DELEGATES highlight against, updated on the debounce
  // rather than on the keystroke. `query` still moves immediately (the field
  // has to feel live), but every visible row re-runs highlightedPreview and
  // a full RichText reparse whenever this changes, and doing that against
  // results that have not arrived yet was pure waste.
  property string highlightQuery: ""

  property var freq: ({})
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
  readonly property color dirColor: "#9fcbfc"

  // shell.qml reads this for the morphed pill's width; it used to be the
  // literal 1000 in both files, with nothing keeping them equal.
  readonly property int panelWidth: 1000

  readonly property int textCellH: 32
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


  visible: popup.showFactor > 0.01
  color: "transparent"
  anchors { left: true; right: true; top: true; bottom: true }
  focusable: true
  exclusionMode: ExclusionMode.Ignore

  // ── why a row could not be dragged out ───────────────────────────────
  // This surface covers the WHOLE screen (all four anchors, plus closeArea
  // filling it), so the pointer never leaves scout during a drag and the
  // compositor resolved every drop back to scout itself. The file had
  // nowhere to land.
  //
  // Icarus drags fine from inside a Flickable, so the Flickable was never
  // the problem — its menus just mask down to their own background
  // (Region { item: fileBg }) and are click-through everywhere else.
  //
  // Rather than mask permanently, which would let clicks outside the panel
  // fall through to whatever is underneath, the input region is dropped only
  // while a drag is actually in flight. Wayland's drag grab is separate from
  // the surface input region, so letting go of the region mid-drag does not
  // cancel the drag — it only changes who the drop resolves to.
  property bool dragging: false
  // Explicitly the whole surface when idle, explicitly nothing while dragging,
  // rather than leaning on what an unset mask means — getting that backwards
  // would leave scout permanently click-through. closeArea already fills the
  // window, so it is the full-screen region.
  mask: Region { item: popup.dragging ? null : closeArea }

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
    // Not while dragging: the pointer is over another application by design
    // at that point, and closing here would destroy the row the drag is
    // sourced from, mid-drag.
    active: popup.shown && !popup.dragging
    onCleared: popup.closePopup()
  }

  IpcHandler {
    target: "Scout"
    function toggle() {
      popup.toggle();
    }
    // Same shape as Picasso's rescan(): the index is a cache, and there has to
    // be a way to rebuild it without waiting for it to go stale.
    function reindex(): string {
      popup.reindex();
      return "indexing";
    }
    function status(): string {
      return "index=" + popup.indexPath
        + " age=" + (popup.indexedAt > 0
            ? Math.round((Date.now() - popup.indexedAt) / 1000) + "s" : "never")
        + " indexing=" + popup.indexing
        + " known=" + Object.keys(popup.freq).length;
    }
  }

  Process {
    id: searchProc
    property int generation: 0
    stdout: StdioCollector {
      id: out
      waitForEnd: true
      onStreamFinished: popup.onSearch(out.text, searchProc.generation)
    }
  }

  Process {
    id: actionProc
    onExited: popup.onActionDone()
  }

  // The walk. Runs detached from anything the user is waiting on: an open
  // shows whatever index is already on disk and lets this refresh it
  // underneath, which is picasso's "scan once and keep it warm" rather than
  // scout's old "scan again on every keystroke".
  Process {
    id: indexProc
    onExited: {
      popup.indexing = false
      popup.indexedAt = Date.now()
      popup.saveState()
      // The first index of all: nothing could be shown until it existed.
      if (popup.shown) popup.refresh()
    }
  }

  function reindex() {
    if (popup.indexing) return
    popup.indexing = true
    indexProc.command = ["sh", "-c",
      Scout.indexCommand(popup.searchRoot || Quickshell.env("HOME"), popup.indexPath)]
    indexProc.running = true
  }

  readonly property bool indexFresh:
    popup.indexedAt > 0 && (Date.now() - popup.indexedAt) < popup.indexMaxAge

  function openPopup() {
    popup.shown = true
    popup.collapsing = false
    popup.query = ""
    searchInput.text = ""
    popup.sel = 0
    popup.highlightQuery = ""
    popup.dragging = false
    // Show something immediately off the existing index, and only then go and
    // freshen it. The old open() blocked on a 518k-file traversal to produce a
    // list of 200 arbitrary files.
    popup.refresh()
    if (!popup.indexFresh) popup.reindex()
    focusRetry.counter = 0
    focusRetry.restart()
    closeAnim.stop()
    popup.showFactor = 0
    openAnim.restart()
  }

  function closePopup() {
    // A drag that ends without onDragFinished would otherwise leave this
    // surface permanently input-transparent, i.e. unusable.
    popup.dragging = false
    popup.collapsing = true
    openAnim.stop()
    closeAnim.restart()
  }

  function toggle() {
    if (popup.shown) popup.closePopup()
    else popup.openPopup()
  }

  // ── what to show ─────────────────────────────────────────────────────
  //
  // One entry point, because "no query" and "a query" are the same question
  // asked of the same index — they only differ in whether fzf is involved.
  function refresh() {
    const q = popup.query.trim()
    if (q === "") {
      popup.searching = false
      searchProc.running = false
      // What you actually open, most-used first. The old opening view was
      // `fd --max-results 200 | sort`, which bails after the first 200 hits
      // in nondeterministic traversal order — so it opened on 200 essentially
      // random files. runner.js already ranks its own list this way.
      const ranked = Scout.freqRanked(popup.freq, 200)
      if (ranked.length > 0 && !popup.dirsOnly) {
        popup.setRows(ranked)
      } else {
        popup.run(Scout.browseCommand(popup.indexPath, popup.dirsOnly))
      }
      return
    }
    popup.run(Scout.filterCommand(popup.indexPath, q, popup.dirsOnly))
  }

  // Every result-producing command goes through here so the generation
  // bookkeeping cannot be forgotten at one of the call sites.
  function run(cmd) {
    popup.searchGen++
    const gen = popup.searchGen
    popup.searching = true
    // Killing a process is asynchronous, so the old reply may still be in
    // flight; the generation check in onSearch is what actually protects us.
    searchProc.running = false
    searchProc.generation = gen
    searchProc.command = ["sh", "-c", cmd]
    searchProc.running = true
  }

  function onSearch(text, gen) {
    // A slower earlier search landing after a newer one used to clobber it.
    if (gen !== popup.searchGen) return
    popup.searching = false
    popup.setRows(Scout.parseResults(text))
  }

  function setRows(rows) {
    popup.rows = rows
    popup.highlightQuery = popup.query
    popup.clampSel()
  }

  // fzf --filter has ALREADY fuzzy-matched and ranked by the time we see it.
  // What used to sit here was a second pass that re-filtered that output with
  // a contiguous-substring test — which threw away every non-contiguous match
  // fzf had just found. Scout was paying for a fuzzy finder and shipping
  // substring search. There is nothing to do here but show what came back.

  function runAction(cmd, kind) {
    popup.lastAction = kind
    actionProc.command = ["sh", "-c", cmd]
    actionProc.running = true
  }

  function onActionDone() {
    popup.closePopup()
    popup.lastAction = ""
  }

  function confirm() {
    if (popup.rows.length === 0) return
    const row = popup.rows[popup.sel]
    popup.freq = Scout.bumpFreq(popup.freq, row.path)
    popup.saveState()
    popup.runAction(Scout.openCommand(row.path, row.isDir), row.isDir ? "cd" : "open")
  }

  // ── what survives a restart ──────────────────────────────────────────
  // Scout was the only interactive layer in the shell persisting nothing.
  // Same FileView + debounced setText shape as chronos and picasso.
  FileView {
    id: stateFile
    path: Quickshell.statePath("scout.json")
    blockLoading: true
    printErrors: false
  }

  Timer {
    id: stateSave
    interval: 400
    onTriggered: stateFile.setText(JSON.stringify({
      freq: popup.freq, indexedAt: popup.indexedAt
    }))
  }

  function saveState() { stateSave.restart() }

  Component.onCompleted: {
    try {
      const j = JSON.parse(stateFile.text() || "{}")
      popup.freq = j.freq ?? ({})
      popup.indexedAt = j.indexedAt ?? 0
    } catch (e) {}
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
    width: popup.panelWidth
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

    LayerShadow {
      panel: bg
      cornerRadius: Zenon.pillRadius
      morphed: popup.morphMode
    }

    // ClippingRectangle, not Rectangle + clip: true. Qt's own clip is
    // RECTANGULAR — it clips to the bounding box and knows nothing about the
    // radius — so every square child painted to the panel's edge (the bottom
    // strip most visibly) filled in the rounded corners behind it. This one
    // clips to the rounded shape itself.
    ClippingRectangle {
      id: bg
      anchors.fill: parent
      // Grown by its own border. A ClippingRectangle insets its children by
      // border.width on every side, so the content box came out 2px smaller
      // than the panel and every layout measured against the panel's size was
      // short by one row or one column. Expanding the clipper by the border
      // hands the content its full box back; the outline simply sits a pixel
      // further out, which is invisible.
      anchors.margins: -bg.border.width
      color: popup.morphMode ? "transparent" : popup.bgColor
      radius: Zenon.pillRadius
      topLeftRadius: Zenon.pillRadius
      topRightRadius: Zenon.pillRadius
      bottomLeftRadius: Zenon.pillRadius
      bottomRightRadius: Zenon.pillRadius
      border.color: popup.morphMode ? "transparent" : popup.borderColor
      border.width: 1

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
              opacity: popup.searching ? 0.45 : 1
              Behavior on opacity { NumberAnimation { duration: Zenon.fast } }
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
                // Clearing the field is instant — there is no process to
                // debounce, the frecency list is already in hand.
                if (popup.query.trim() === "") popup.refresh()
                else searchDebounce.restart()
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
            // There was no loading state at all: a first open sat on
            // "No matches found" until the walk came back.
            text: popup.indexing && popup.rows.length === 0 ? "building index\u2026"
              : popup.query.trim() === "" ? "type to search"
              : "No matches found"
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
            // Each row carries a Rectangle, a RichText, a clipped Item, a
            // 4-stop Gradient, a ParallelAnimation, a Connections and a
            // MouseArea. Handing the view a fresh array used to destroy and
            // rebuild every one of them on every search — the same trap
            // Tooltip.qml and ZeusPopup.qml both already carry a scar from.
            reuseItems: true
            cacheBuffer: 4000

            delegate: Item {
              id: row
              required property var modelData
              required property int index
              width: fileGrid.cellWidth
              height: fileGrid.cellHeight

              // Drag a result straight into another application, the same way
              // icarus drags a file out of its browser. encodeURI rather than
              // raw concatenation: half the paths in this index have spaces in
              // them, and text/uri-list wants them percent-encoded.
              Drag.active: rowDrag.active
              Drag.source: row
              Drag.keys: ["text/uri-list"]
              Drag.mimeData: ({ "text/uri-list": "file://" + encodeURI(row.modelData.path) + "\r\n" })
              Drag.supportedActions: Qt.CopyAction
              Drag.dragType: Drag.Automatic
              Drag.hotSpot.x: width / 2
              Drag.hotSpot.y: height / 2
              Drag.onDragFinished: function(dropAction) {
                popup.dragging = false
                if (dropAction === Qt.CopyAction) popup.closePopup()
              }

              Rectangle {
                anchors.fill: parent
                color: row.index === popup.sel ? popup.selColor
                  : (rowMa.containsMouse ? Zenon.hoverTint : "transparent")
              }

              Text {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                text: {
                  const avail = Math.max(1, Math.floor(
                    (fileGrid.cellWidth - 32) / textMetrics.advanceWidth))
                  return Scout.highlightedPreview(
                    Scout.fitPath(modelData.preview, avail), popup.highlightQuery)
                }
                color: modelData.isDir ? popup.dirColor : popup.fgColor
                textFormat: Text.RichText
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 600
                font.pixelSize: 16
                clip: true
                // No `elide` here: RichText is measured after the markup is
                // parsed, so eliding fights the manual fit above and the
                // manual one always won anyway.
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

              DragHandler {
                id: rowDrag
                target: null
                onActiveChanged: {
                  if (active) {
                    // region first, so the surface is already transparent by
                    // the time the drag is offered
                    popup.dragging = true
                    row.Drag.active = true
                  }
                }
              }

              MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // A single click only moves the caret — opening on one click
                // meant there was no way to point at a row without launching
                // it, and no way to start a drag from one either.
                onClicked: popup.sel = row.index
                onDoubleClicked: {
                  popup.sel = row.index
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
              model: Scout.hintText(popup.dirsOnly)
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
        } else if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_D) {
          event.accepted = true
          popup.dirsOnly = !popup.dirsOnly
          popup.sel = 0
          popup.refresh()
        } else if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_R) {
          event.accepted = true
          popup.reindex()
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
    onTriggered: popup.refresh()
  }
}
