// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
// ICARUS — desktop context menu, tray-menu styled, floating on focused monitor

import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "../morpheus"
import "icarus.js" as Icarus

Item {
  id: root

  // shell passes focusedScreen here (like other popups)
  property var screen: null
  property point anchorPos: Qt.point(0, 0)
  property bool shown: false
  property string cwd: Quickshell.env("HOME") || "/home/buck"
  property var fileRows: []
  property string pendingConfirmId: ""
  property string childMenu: "" // "" | "file" | "session"
  property var sessionEntries: [
    { id: "lockscreen", text: "Lock",  icon: "", cmd: "sleep 0.35 && qs ipc call Cerberus lock", confirm: false },
    { id: "logout",     text: "Logout",      icon: "󰍃", cmd: "hyprshutdown -p 'loginctl terminate-session " + (Quickshell.env("XDG_SESSION_ID") || "") + "'", confirm: true },
    { id: "suspend",    text: "Suspend",     icon: "󰤄", cmd: "systemctl suspend", confirm: true },
    { id: "reboot",     text: "Reboot",      icon: "", cmd: "hyprshutdown -p 'systemctl reboot'", confirm: true },
    { id: "shutdown",   text: "Shutdown",    icon: "⏻", cmd: "hyprshutdown -p 'systemctl poweroff'", confirm: true }
  ]

  // for grab
  readonly property var grabWindows: {
    const out = [rootMenu];
    if (fileMenu.visible) out.push(fileMenu);
    if (sessionMenu.visible) out.push(sessionMenu);
    if (confirmMenu.visible) out.push(confirmMenu);
    return out;
  }

   // centred model for root: home, separator, session
   readonly property var rootModel: [
    { text: "Home", icon: "", hasChildren: true, kind: "file", isSeparator: false, enabled: true },
    { text: "", icon: "", hasChildren: false, isSeparator: true, enabled: false },
    { text: "Session",      icon: "󰐥", hasChildren: true, kind: "session", isSeparator: false, enabled: true }
  ]

  function openAt(pos, clickedScreen) {
    // clickedScreen is the monitor where the right-click landed. The spec
    // says "on focused monitor" — the click focuses that monitor, so by the
    // time the handler fires focusedScreen === clickedScreen. Honour the
    // explicit screen to avoid a one-frame race where the binding hasn't
    // caught up yet.
    if (clickedScreen) root.screen = clickedScreen;
    root.anchorPos = pos;
    // keep cwd fresh
    root.cwd = Quickshell.env("HOME") || root.cwd;
    root.pendingConfirmId = "";
    root.childMenu = "";
    root.shown = true;
    fileHoverTimer.stop();
    sessionHoverTimer.stop();
    refreshFiles();
  }

  function closeAll() {
    root.shown = false;
    root.childMenu = "";
    root.pendingConfirmId = "";
  }

  function execCmd(cmd) {
    Quickshell.execDetached(["sh", "-c", cmd + " >/dev/null 2>&1 &"]);
  }

  function refreshFiles() {
    listProc.command = ["sh", "-c", Icarus.listCommand(root.cwd)];
    listProc.running = true;
  }

  function goParent() {
    const p = Icarus.dirname(root.cwd);
    if (p !== root.cwd) {
      root.cwd = p;
      root.pendingConfirmId = "";
    }
  }

  function onFileChosen(entry) {
    if (entry.isParent) {
      goParent();
      return;
    }
    if (entry.isDir) {
      root.cwd = entry.path;
      return;
    }
    // file → open
    root.execCmd(Icarus.openCommand(entry.path));
    root.closeAll();
  }

  function onSessionChosen(entry) {
    if (!entry) return;
    if (entry.confirm) {
      root.pendingConfirmId = entry.id;
      // keep session menu open, show confirm as its child
      return;
    }
    root.execCmd(entry.cmd);
    root.closeAll();
  }

  function sessionEntryById(id) {
    for (let i = 0; i < root.sessionEntries.length; ++i)
      if (root.sessionEntries[i].id === id) return root.sessionEntries[i];
    return null;
  }

  // ── autofit + directional placement helpers ──────────────────────────
  function availBelow(anchor, screenH, pad) { return Math.max(0, screenH - anchor - pad); }
  function availAbove(anchor, pad) { return Math.max(0, anchor - pad); }
  function chooseY(anchor, bgH, screenH, pad) {
    const below = availBelow(anchor, screenH, pad);
    const above = availAbove(anchor, pad);
    if (bgH <= below) return anchor;
    if (bgH <= above) return anchor - bgH;
    // not enough space either side — clamp to screen and reduce height elsewhere
    return Math.max(pad, Math.min(anchor, screenH - bgH - pad));
  }
  function chooseX(anchor, bgW, screenW, pad) {
    const right = Math.max(0, screenW - anchor - pad);
    const left = Math.max(0, anchor - pad);
    if (bgW <= right) return anchor;
    if (bgW <= left) return anchor - bgW;
    return Math.max(pad, Math.min(anchor, screenW - bgW - pad));
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const rows = Icarus.parseLsOutput(text, root.cwd);
        // prepend ".." parent entry
        const parentEntry = { name: "..", path: Icarus.dirname(root.cwd), isDir: true, isParent: true, isHidden: false };
        root.fileRows = [parentEntry].concat(rows);
      }
    }
  }

  onCwdChanged: refreshFiles()

  // ── root menu ────────────────────────────────────────────────────────
  PanelWindow {
    id: rootMenu
    visible: root.shown
    focusable: true
    aboveWindows: true
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region { item: rootBg }
    anchors { top: true; left: true }
    screen: root.screen
    implicitWidth: 220 + Zenon.shadowPad * 2
    implicitHeight: {
      if (!root.screen) return 220 + Zenon.shadowPad * 2;
      const contentH = rootContent.implicitHeight + 12;
      const maxH = root.screen.height - Zenon.shadowPad * 2;
      return Math.min(contentH, maxH) + Zenon.shadowPad * 2;
    }

    margins.left: {
      if (!root.screen) return 0;
      const bgW = 220;
      const bgX = root.chooseX(root.anchorPos.x, bgW, root.screen.width, Zenon.shadowPad);
      return bgX - Zenon.shadowPad;
    }
    margins.top: {
      if (!root.screen) return 0;
      const bgH = Math.min(rootContent.implicitHeight + 12, root.screen.height - Zenon.shadowPad * 2);
      const bgY = root.chooseY(root.anchorPos.y, bgH, root.screen.height, Zenon.shadowPad);
      return bgY - Zenon.shadowPad;
    }

    // focus grab covering all open menus
    HyprlandFocusGrab {
      windows: root.grabWindows
      active: root.shown
      onCleared: root.closeAll()
    }

    onVisibleChanged: {
      if (visible) rootMenuContent.forceActiveFocus();
    }

    LayerShadow {
      panel: rootBg
      cornerRadius: 6
      morphed: false
    }

    ClippingRectangle {
      id: rootBg
      anchors.fill: parent
      anchors.margins: Zenon.shadowPad
      color: Zenon.panelBg
      border.color: Zenon.surface
      border.width: 1
      radius: 6
      topLeftRadius: 6
      topRightRadius: root.childMenu !== "" ? 0 : 6
      bottomLeftRadius: 6
      bottomRightRadius: root.childMenu !== "" ? 0 : 6

      Column {
        id: rootContent
        anchors.fill: parent
        anchors.margins: 4
        spacing: 1

        Repeater {
          model: root.rootModel
          delegate: Item {
            id: rootEntry
            required property var modelData
            required property int index
            width: rootContent.width
            height: (modelData.isSeparator || false) ? 8 : Math.max(28, rootLabel.implicitHeight + 12)

            // keep refs for submenu anchoring
            property bool isFileRow: !(modelData.isSeparator || false) && modelData.kind === "file"
            property bool isSessionRow: !(modelData.isSeparator || false) && modelData.kind === "session"

            Rectangle {
              id: rootHighlight
              anchors.fill: parent
              radius: 0
              color: rootHover.containsMouse && !(modelData.isSeparator || false) ? Zenon.hoverTint : "transparent"
              Behavior on color { ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: Zenon.surface
              visible: (modelData.isSeparator || false)
            }

            Item {
              id: rootRow
              anchors.fill: parent
              anchors.leftMargin: 8
              anchors.rightMargin: 8
              visible: !(modelData.isSeparator || false)

              Text {
                id: rootIcon
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: 16
                text: modelData.icon || ""
                visible: (modelData.icon || "") !== ""
                color: Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 13
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                id: rootLabel
                anchors.left: rootIcon.visible ? rootIcon.right : parent.left
                anchors.leftMargin: 8
                anchors.right: rootArrow.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignLeft
                text: modelData.text || ""
                elide: Text.ElideRight
                color: Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: Font.Medium
                font.pixelSize: 15
              }

              Text {
                id: rootArrow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: 16
                visible: (modelData.hasChildren || false)
                text: ""
                color: Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 13
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
              }
            }

            MouseArea {
              id: rootHover
              anchors.fill: parent
              hoverEnabled: true
              enabled: !(modelData.isSeparator || false)
              onEntered: {
                if (modelData.kind === "file") {
                  sessionHoverTimer.stop();
                  fileHoverTimer.restart();
                } else if (modelData.kind === "session") {
                  fileHoverTimer.stop();
                  sessionHoverTimer.restart();
                }
              }
              onClicked: {
                if (modelData.kind === "file") {
                  root.childMenu = "file";
                } else if (modelData.kind === "session") {
                  root.childMenu = "session";
                }
              }
            }
          }
        }
      }

      // keyboard: Esc closes, arrows switch child menus
      Item {
        id: rootMenuContent
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: (e) => { e.accepted = true; root.closeAll(); }
        Keys.onLeftPressed: (e) => { e.accepted = true; root.childMenu = ""; }
        Keys.onRightPressed: (e) => {
          e.accepted = true;
          if (root.childMenu === "") root.childMenu = "file";
        }
      }
    }

    Timer { id: fileHoverTimer; interval: 80; onTriggered: root.childMenu = "file" }
    Timer { id: sessionHoverTimer; interval: 80; onTriggered: root.childMenu = "session" }
  }

  // ── file browser submenu ──────────────────────────────────────────
  PanelWindow {
    id: fileMenu
    visible: root.shown && root.childMenu === "file"
    focusable: false
    aboveWindows: true
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region { item: fileBg }
    anchors { top: true; left: true }
    screen: root.screen
    implicitWidth: 300 + Zenon.shadowPad * 2
    implicitHeight: {
      if (!root.screen) return 300 + Zenon.shadowPad * 2;
      const maxBgH = root.screen.height - Zenon.shadowPad * 2;
      return Math.min(fileContent.implicitHeight + 12, maxBgH) + Zenon.shadowPad * 2;
    }

    // autofit + no gap — try right of parent, else left; also shift up if off-screen bottom
    margins.left: {
      if (!root.screen || !rootMenu.visible) return 0;
      const pad = Zenon.shadowPad;
      const parentBgX = rootMenu.margins.left + pad;
      const parentBgW = 220;
      const bgW = 300;
      const gap = 0;
      const rightBgX = parentBgX + parentBgW + gap;
      const leftBgX = parentBgX - bgW - gap;
      let bgX;
      if (rightBgX + bgW <= root.screen.width - pad) bgX = rightBgX;
      else if (leftBgX >= pad) bgX = leftBgX;
      else bgX = Math.max(pad, Math.min(rightBgX, root.screen.width - bgW - pad));
      return bgX - pad;
    }
    margins.top: {
      if (!root.screen || !rootMenu.visible) return 0;
      const pad = Zenon.shadowPad;
      const parentBgY = rootMenu.margins.top + pad;
      const bgH = fileMenu.implicitHeight - pad * 2;
      let bgY = parentBgY;
      if (bgY + bgH > root.screen.height - pad) bgY = root.screen.height - bgH - pad;
      if (bgY < pad) bgY = pad;
      return bgY - pad;
    }

    LayerShadow {
      panel: fileBg
      cornerRadius: 6
      morphed: false
    }

    ClippingRectangle {
      id: fileBg
      anchors.fill: parent
      anchors.margins: Zenon.shadowPad
      color: Zenon.panelBg
      border.color: Zenon.surface
      border.width: 1
      radius: 6
      topLeftRadius: 0
      topRightRadius: 6
      bottomLeftRadius: 0
      bottomRightRadius: 6

      Column {
        id: fileContent
        anchors.fill: parent
        anchors.margins: 4
        spacing: 1

        // file list — autofit, 5.6× scroll speed (2×), aware of available space
        Flickable {
          id: fileFlick
          width: parent.width
          height: {
            if (!root.screen) return Math.min(500, fileRepeaterHolder.childrenRect.height);
            const maxH = root.screen.height - Zenon.shadowPad * 2 - 12;
            return Math.min(fileRepeaterHolder.childrenRect.height, Math.max(120, maxH - 6));
          }
          clip: false
          contentWidth: width
          contentHeight: fileRepeaterHolder.childrenRect.height
          boundsBehavior: Flickable.StopAtBounds
          flickDeceleration: 1800
          maximumFlickVelocity: 2800
          WheelHandler {
            onWheel: function(event) {
              if (event.angleDelta.y !== 0) {
                const delta = event.angleDelta.y > 0 ? -90 : 90
                fileFlick.contentY = Math.max(0, Math.min(fileFlick.contentHeight - fileFlick.height, fileFlick.contentY + delta * 5.6))
                event.accepted = true
              } else if (event.angleDelta.x !== 0) {
                event.accepted = true
              }
            }
          }

          Column {
            id: fileRepeaterHolder
            width: parent.width
            spacing: 1

            Repeater {
              id: fileRepeater
              model: root.fileRows

              delegate: Item {
                id: fileEntry
                required property var modelData
                required property int index
                width: fileRepeaterHolder.width
                height: Math.max(28, fileLabel.implicitHeight + 12)

                // drag support for both files and dirs (not parent)
                Drag.active: dragHandler.active
                Drag.source: fileEntry
                Drag.keys: ["text/uri-list"]
                Drag.mimeData: {"text/uri-list": "file://" + modelData.path + "\r\n"}
                Drag.supportedActions: Qt.CopyAction
                Drag.dragType: Drag.Automatic
                Drag.hotSpot.x: width / 2
                Drag.hotSpot.y: height / 2
                Drag.onDragFinished: function(dropAction) { if (dropAction === Qt.CopyAction) root.closeAll() }

                Rectangle {
                  anchors.fill: parent
                  radius: 0
                  color: fileHover.containsMouse ? Zenon.hoverTint : "transparent"
                  Behavior on color { ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
                }

                Item {
                  anchors.fill: parent
                  anchors.leftMargin: 8
                  anchors.rightMargin: 8

                  Text {
                    id: fileIcon
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16
                    height: 16
                    text: modelData.isDir ? "󰉋" : ""
                    color: Zenon.white
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 13
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                    visible: !modelData.isParent
                  }

                  Text {
                    id: fileLabel
                    anchors.left: fileIcon.visible ? fileIcon.right : parent.left
                    anchors.leftMargin: fileIcon.visible ? 8 : 0
                    anchors.right: fileArrow.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignLeft
                    text: modelData.isParent ? "" : modelData.name
                    elide: Text.ElideMiddle
                    color: Zenon.white
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.weight: Font.Medium
                    font.pixelSize: 15
                  }

                  Text {
                    id: fileArrow
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16
                    height: 16
                    visible: (modelData.isDir || false) && !modelData.isParent
                    text: ""
                    color: Zenon.white
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 13
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                  }
                }

                DragHandler {
                  id: dragHandler
                  enabled: !modelData.isParent
                  target: null
                  onActiveChanged: if (active) fileEntry.Drag.active = true
                }

                MouseArea {
                  id: fileHover
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.onFileChosen(modelData)
                }
              }
            }
          }
        }
      }
    }
  }

  // ── session submenu ───────────────────────────────────────────────
  PanelWindow {
    id: sessionMenu
    visible: root.shown && root.childMenu === "session"
    focusable: false
    aboveWindows: true
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region { item: sessionBg }
    anchors { top: true; left: true }
    screen: root.screen
    implicitWidth: 220 + Zenon.shadowPad * 2
    implicitHeight: {
      if (!root.screen) return 220 + Zenon.shadowPad * 2;
      const maxBgH = root.screen.height - Zenon.shadowPad * 2;
      return Math.min(sessionContent.implicitHeight + 12, maxBgH) + Zenon.shadowPad * 2;
    }

    margins.left: {
      if (!root.screen || !rootMenu.visible) return 0;
      const pad = Zenon.shadowPad;
      const parentBgX = rootMenu.margins.left + pad;
      const parentBgW = 220;
      const bgW = 220;
      const gap = 0;
      const rightBgX = parentBgX + parentBgW + gap;
      const leftBgX = parentBgX - bgW - gap;
      let bgX;
      if (rightBgX + bgW <= root.screen.width - pad) bgX = rightBgX;
      else if (leftBgX >= pad) bgX = leftBgX;
      else bgX = Math.max(pad, Math.min(rightBgX, root.screen.width - bgW - pad));
      return bgX - pad;
    }
    margins.top: {
      if (!root.screen || !rootMenu.visible) return 0;
      const pad = Zenon.shadowPad;
      const parentBgY = rootMenu.margins.top + pad;
      const offset = 4 + 30 + 1 + 8 + 1;
      const bgH = sessionMenu.implicitHeight - pad * 2;
      let bgY = parentBgY + offset;
      if (bgY + bgH > root.screen.height - pad) bgY = root.screen.height - bgH - pad;
      if (bgY < pad) bgY = pad;
      return bgY - pad;
    }

    LayerShadow {
      panel: sessionBg
      cornerRadius: 6
      morphed: false
    }

    ClippingRectangle {
      id: sessionBg
      anchors.fill: parent
      anchors.margins: Zenon.shadowPad
      color: Zenon.panelBg
      border.color: Zenon.surface
      border.width: 1
      radius: 6
      topLeftRadius: 0
      topRightRadius: 6
      bottomLeftRadius: 0
      bottomRightRadius: 6

      Column {
        id: sessionContent
        anchors.fill: parent
        anchors.margins: 4
        spacing: 1

        Repeater {
          model: root.sessionEntries
          delegate: Item {
            id: sessEntry
            required property var modelData
            required property int index
            width: sessionContent.width
            height: Math.max(28, sessLabel.implicitHeight + 12)

            readonly property bool isConfirmPending: root.pendingConfirmId === modelData.id

            Rectangle {
              anchors.fill: parent
              radius: 0
              color: (sessHover.containsMouse || isConfirmPending) ? Zenon.hoverTint : "transparent"
              Behavior on color { ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
            }

            Item {
              anchors.fill: parent
              anchors.leftMargin: 8
              anchors.rightMargin: 8

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: 16
                text: modelData.icon
                color: Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 13
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                id: sessLabel
                anchors.left: parent.left
                anchors.leftMargin: 24
                anchors.right: sessArrow.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignLeft
                text: modelData.text
                elide: Text.ElideRight
                color: Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: Font.Medium
                font.pixelSize: 15
              }

              Text {
                id: sessArrow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: 16
                visible: (modelData.confirm || false)
                text: ""
                color: Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 13
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
              }
            }

            MouseArea {
              id: sessHover
              anchors.fill: parent
              hoverEnabled: true
              onEntered: {
                if (modelData.confirm) {
                  // keep confirm menu ready
                }
              }
              onClicked: {
                if (modelData.confirm) {
                  root.pendingConfirmId = modelData.id;
                } else {
                  root.onSessionChosen(modelData);
                }
              }
            }
          }
        }
      }
    }
  }

  // ── confirm submenu (tertiary, to the right of session) ──────────
  PanelWindow {
    id: confirmMenu
    visible: root.shown && root.childMenu === "session" && root.pendingConfirmId !== ""
    focusable: false
    aboveWindows: true
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region { item: confirmBg }
    anchors { top: true; left: true }
    screen: root.screen
    implicitWidth: 160 + Zenon.shadowPad * 2
    implicitHeight: {
      if (!root.screen) return 160 + Zenon.shadowPad * 2;
      const maxBgH = root.screen.height - Zenon.shadowPad * 2;
      return Math.min(confirmContent.implicitHeight + 12, maxBgH) + Zenon.shadowPad * 2;
    }

    property var pendingEntry: root.sessionEntryById(root.pendingConfirmId)

    margins.left: {
      if (!root.screen || !sessionMenu.visible) return 0;
      const pad = Zenon.shadowPad;
      const parentBgX = sessionMenu.margins.left + pad;
      const parentBgW = 220;
      const bgW = 160;
      const gap = 0;
      const rightBgX = parentBgX + parentBgW + gap;
      const leftBgX = parentBgX - bgW - gap;
      let bgX;
      if (rightBgX + bgW <= root.screen.width - pad) bgX = rightBgX;
      else if (leftBgX >= pad) bgX = leftBgX;
      else bgX = Math.max(pad, Math.min(rightBgX, root.screen.width - bgW - pad));
      return bgX - pad;
    }
    margins.top: {
      if (!root.screen || !sessionMenu.visible) return 0;
      const pad = Zenon.shadowPad;
      const parentBgY = sessionMenu.margins.top + pad;
      let idx = -1;
      for (let i = 0; i < root.sessionEntries.length; ++i) if (root.sessionEntries[i].id === root.pendingConfirmId) { idx = i; break; }
      const rowH = 31;
      const bgH = confirmMenu.implicitHeight - pad * 2;
      let bgY = parentBgY + 4 + idx * rowH;
      if (bgY + bgH > root.screen.height - pad) bgY = root.screen.height - bgH - pad;
      if (bgY < pad) bgY = pad;
      return bgY - pad;
    }

    LayerShadow {
      panel: confirmBg
      cornerRadius: 6
      morphed: false
    }

    ClippingRectangle {
      id: confirmBg
      anchors.fill: parent
      anchors.margins: Zenon.shadowPad
      color: Zenon.panelBg
      border.color: Zenon.surface
      border.width: 1
      radius: 6
      topLeftRadius: 0
      topRightRadius: 6
      bottomLeftRadius: 0
      bottomRightRadius: 6

      Column {
        id: confirmContent
        anchors.fill: parent
        anchors.margins: 4
        spacing: 1

        Item {
          width: parent.width
          height: Math.max(28, confirmLabel.implicitHeight + 12)
          Rectangle {
            anchors.fill: parent
            radius: 0
            color: confirmHover.containsMouse ? Zenon.hoverTint : "transparent"
          }
          Text {
            id: confirmLabel
            anchors.centerIn: parent
            text: " Confirm"
            color: Zenon.white
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: Font.Medium
            font.pixelSize: 15
          }
          MouseArea {
            id: confirmHover
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
              const e = confirmMenu.pendingEntry;
              if (e) root.execCmd(e.cmd);
              root.closeAll();
            }
          }
        }

        Item {
          width: parent.width
          height: Math.max(28, cancelLabel.implicitHeight + 12)
          Rectangle {
            anchors.fill: parent
            radius: 0
            color: cancelHover.containsMouse ? Zenon.hoverTint : "transparent"
          }
          Text {
            id: cancelLabel
            anchors.centerIn: parent
            text: " Cancel"
            color: Zenon.white
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: Font.Medium
            font.pixelSize: 15
          }
          MouseArea {
            id: cancelHover
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.pendingConfirmId = ""
          }
        }
      }
    }
  }

  // clicking outside root but inside screen should also be caught by grab;
  // fallback transparent catcher when no menu child
  // (grab handles it — no extra MouseArea needed)

  IpcHandler {
    target: "Icarus"
    function toggle(): void { if (root.shown) root.closeAll(); else root.openAt(Qt.point(root.screen ? root.screen.width/2 : 200, root.screen ? root.screen.height/2 : 200), root.screen); }
    function openAt(x: int, y: int): void { root.openAt(Qt.point(x, y), root.screen); }
    function hide(): void { root.closeAll(); }
  }
}
