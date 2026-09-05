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
import "../morpheus"
import "icarus.js" as Icarus

Item {
  id: root

  // shell passes focusedScreen here (like other popups)
  property var screen: null
  property point anchorPos: Qt.point(0, 0)
  property bool shown: false
  property string cwd: Quickshell.env("HOME") || "/"
  property var fileRows: []
  property string pendingConfirmId: ""
  property string childMenu: "" // "" | "apps" | "file" | "session" | "trash"

  // ── the trash ─────────────────────────────────────────────────────────
  // XDG's trash, wherever XDG_DATA_HOME points — not a path written out here.
  readonly property string trashDir:
    (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")) + "/Trash"
  property int trashCount: 0
  // Emptying is not undoable, so it takes two clicks: the row arms first and
  // says so. The confirm submenu this menu already has is wired to the session
  // entries by index, and generalising it was more surgery than one red row.
  property bool trashArmed: false
  // where the trash row sits inside the root menu, read off the row itself
  // rather than guessed from a row height — its menu lines up with it
  property real trashRowY: 0
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
    if (appsMenu.visible) out.push(appsMenu);
    if (fileMenu.visible) out.push(fileMenu);
    if (sessionMenu.visible) out.push(sessionMenu);
    if (trashMenu.visible) out.push(trashMenu);
    if (confirmMenu.visible) out.push(confirmMenu);
    return out;
  }

   // centred model for root: apps, home, separator, session
   readonly property var rootModel: [
    // First, because it is the thing this menu is most often opened to reach.
    // No children: it opens a window, so there is no menu level to walk into.
    { text: "Files", icon: "\uF07C", hasChildren: false, kind: "terminus",
      isSeparator: false, enabled: true },
    { text: "Apps",  icon: "", hasChildren: true, kind: "apps", isSeparator: false, enabled: true },
    { text: "Home", icon: "", hasChildren: true, kind: "file", isSeparator: false, enabled: true },
    // Muted when there is nothing in it — an empty trash is still worth
    // SEEING, so you know where it is and that it is empty, but there is
    // nothing to open and nothing to empty, and a row offering both would
    // be lying about what it can do.
    { text: root.trashCount > 0 ? "Trash (" + root.trashCount + ")" : "Trash",
      icon: "\uF1F8", hasChildren: false, kind: "trash", isSeparator: false,
      enabled: root.trashCount > 0 },
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
    appsHoverTimer.stop();
    fileHoverTimer.stop();
    sessionHoverTimer.stop();
    refreshFiles();
    refreshTrash();
  }

  // Where the pointer actually is, for the keybind path. The desktop catcher
  // hands over its own click point; opening from IPC had nothing to hand over
  // and used the middle of the screen — the one place a context menu should
  // never appear.
  //
  // hyprctl rather than a cursor property: quickshell's Hyprland module does
  // not expose one. A subprocess, but only on the open, and nothing is drawn
  // until the answer is back.
  function openAtCursor() {
    cursorProc.running = true;
  }

  Process {
    id: cursorProc
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // "2186, 774", in hyprland's global logical space
        const m = String(text).trim().match(/(-?\d+)\s*,\s*(-?\d+)/);
        if (!m) {
          root.openAt(Qt.point(root.screen ? root.screen.width / 2 : 200,
                               root.screen ? root.screen.height / 2 : 200), root.screen);
          return;
        }
        const gx = parseInt(m[1], 10);
        const gy = parseInt(m[2], 10);
        // which monitor that global point is on, and where it sits inside it
        const screens = Quickshell.screens;
        for (let i = 0; i < screens.length; ++i) {
          const sc = screens[i];
          if (gx >= sc.x && gx < sc.x + sc.width && gy >= sc.y && gy < sc.y + sc.height) {
            root.openAt(Qt.point(gx - sc.x, gy - sc.y), sc);
            return;
          }
        }
        root.openAt(Qt.point(gx, gy), root.screen);
      }
    }
  }

  function onAppChosen(entry) {
    if (!entry || !entry.id) return;
    Quickshell.execDetached(["sh", "-c", "gtk-launch '" + entry.id.replace(/'/g, "'\\''") + "' >/dev/null 2>&1 &"]);
    root.closeAll();
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

  function refreshTrash() {
    root.trashArmed = false;
    trashProc.command = ["sh", "-c",
      "ls -A1 " + Strings.shellQuote(root.trashDir + "/files") + " 2>/dev/null | wc -l"];
    trashProc.running = true;
  }

  function openTrash() {
    root.execCmd(Icarus.openCommand(root.trashDir + "/files"));
    root.closeAll();
  }

  // Both halves: the files themselves and the .trashinfo records pointing at
  // them. Deleting only one leaves a trash no file manager agrees about.
  function emptyTrash() {
    const files = Strings.shellQuote(root.trashDir + "/files");
    const info = Strings.shellQuote(root.trashDir + "/info");
    root.execCmd("rm -rf -- " + files + "/* " + files + "/.[!.]* "
      + info + "/* " + info + "/.[!.]* 2>/dev/null; true");
    root.trashCount = 0;
    root.closeAll();
  }

  Process {
    id: trashProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.trashCount = parseInt(String(text).trim(), 10) || 0
    }
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

            // The trash row reports where it sits, so its menu lines up with it
            // whatever the rows happen to measure — no row-height constant to keep
            // in step with the delegate.
            Binding {
              target: root
              property: "trashRowY"
              value: rootEntry.y
              when: modelData.kind === "trash"
            }


            Rectangle {
              id: rootHighlight
              anchors.fill: parent
              radius: 0
              color: ((rootHover.containsMouse
                  || (modelData.kind === "apps" && root.childMenu === "apps")
                  || (modelData.kind === "file" && root.childMenu === "file")
                  || (modelData.kind === "session" && root.childMenu === "session")
                  || (modelData.kind === "trash" && root.childMenu === "trash"))
                && !(modelData.isSeparator || false)
                && modelData.enabled !== false) ? Zenon.headBg : "transparent"
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
                color: modelData.enabled === false ? Zenon.muted : Zenon.white
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
                color: modelData.enabled === false ? Zenon.muted : Zenon.white
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
              enabled: !(modelData.isSeparator || false) && modelData.enabled !== false
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onEntered: {
                if (modelData.kind === "trash") {
                  // a target, not a branch: hovering opens nothing, but it does
                  // put away whatever else was open
                  appsHoverTimer.stop();
                  fileHoverTimer.stop();
                  sessionHoverTimer.stop();
                  if (root.childMenu !== "trash") root.childMenu = "";
                } else if (modelData.kind === "apps") {
                  fileHoverTimer.stop();
                  sessionHoverTimer.stop();
                  appsHoverTimer.restart();
                } else if (modelData.kind === "file") {
                  appsHoverTimer.stop();
                  sessionHoverTimer.stop();
                  fileHoverTimer.restart();
                } else if (modelData.kind === "session") {
                  appsHoverTimer.stop();
                  fileHoverTimer.stop();
                  sessionHoverTimer.restart();
                } else if (modelData.kind === "terminus") {
                  // a target, not a branch — same as trash
                  appsHoverTimer.stop();
                  fileHoverTimer.stop();
                  sessionHoverTimer.stop();
                  root.childMenu = "";
                }
              }
              onClicked: (event) => {
                if (modelData.kind === "trash") {
                  // right-click is the whole point of this row; a left click does
                  // the obvious thing and opens it
                  if (event.button === Qt.RightButton) {
                    root.trashArmed = false;
                    root.childMenu = "trash";
                  } else {
                    root.openTrash();
                  }
                  return;
                }
                if (event.button !== Qt.LeftButton) return;
                if (modelData.kind === "apps") {
                  root.childMenu = "apps";
                } else if (modelData.kind === "file") {
                  root.childMenu = "file";
                } else if (modelData.kind === "session") {
                  root.childMenu = "session";
                } else if (modelData.kind === "terminus") {
                  // opens where this menu was opened, which is the directory
                  // the desktop is showing rather than a blind fallback to home
                  root.execCmd("qs ipc call Terminus open "
                    + Strings.shellQuote(root.cwd) + " >/dev/null 2>&1 &");
                  root.closeAll();
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

    Timer { id: appsHoverTimer; interval: 80; onTriggered: root.childMenu = "apps" }
    Timer { id: fileHoverTimer; interval: 80; onTriggered: root.childMenu = "file" }
    Timer { id: sessionHoverTimer; interval: 80; onTriggered: root.childMenu = "session" }
  }

  // ── trash context menu ──────────────────────────────────────────
  // The trash's own menu, on right-click. Placed against the trash ROW rather
  // than the pointer, the way every other submenu here is placed against the
  // row it belongs to.
  PanelWindow {
    id: trashMenu
    visible: root.shown && root.childMenu === "trash"
    focusable: false
    aboveWindows: true
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region { item: trashBg }
    anchors { top: true; left: true }
    screen: root.screen

    readonly property int bgW: 180
    implicitWidth: trashMenu.bgW + Zenon.shadowPad * 2
    implicitHeight: {
      if (!root.screen) return 80 + Zenon.shadowPad * 2;
      const maxBgH = root.screen.height - Zenon.shadowPad * 2;
      return Math.min(trashContent.implicitHeight + 12, maxBgH) + Zenon.shadowPad * 2;
    }

    // to the right of the root menu where there is room, to its left otherwise
    margins.left: {
      if (!root.screen) return 0;
      const pad = Zenon.shadowPad;
      const parentBgX = rootMenu.margins.left + pad;
      const rightBgX = parentBgX + 220;
      const leftBgX = parentBgX - trashMenu.bgW;
      let bgX;
      if (rightBgX + trashMenu.bgW <= root.screen.width - pad) bgX = rightBgX;
      else if (leftBgX >= pad) bgX = leftBgX;
      else bgX = Math.max(pad, Math.min(rightBgX, root.screen.width - trashMenu.bgW - pad));
      return bgX - pad;
    }
    margins.top: {
      if (!root.screen) return 0;
      const pad = Zenon.shadowPad;
      const bgH = trashMenu.implicitHeight - pad * 2;
      // the row's own offset inside the root menu, plus that menu's own inset
      let bgY = rootMenu.margins.top + pad + 4 + root.trashRowY;
      if (bgY + bgH > root.screen.height - pad) bgY = root.screen.height - bgH - pad;
      if (bgY < pad) bgY = pad;
      return bgY - pad;
    }

    LayerShadow {
      panel: trashBg
      cornerRadius: 6
      morphed: false
    }

    ClippingRectangle {
      id: trashBg
      anchors.fill: parent
      anchors.margins: Zenon.shadowPad
      color: Zenon.panelBg
      border.color: Zenon.surface
      border.width: 1
      radius: 6

      Column {
        id: trashContent
        anchors.fill: parent
        anchors.margins: 4
        spacing: 1

        Repeater {
          model: [
            { id: "open", text: "Open" },
            { id: "empty", text: "Empty Trash" }
          ]

          delegate: Item {
            id: trashEntry
            required property var modelData
            width: trashContent.width
            height: Math.max(28, trashLabel.implicitHeight + 12)

            // the destructive row says so once it is armed, and only then
            readonly property bool danger:
              trashEntry.modelData.id === "empty" && root.trashArmed

            Rectangle {
              anchors.fill: parent
              color: trashEntry.danger
                ? Qt.rgba(Zenon.red.r, Zenon.red.g, Zenon.red.b, 0.22)
                : (trashRowHover.containsMouse ? Zenon.headBg : "transparent")
            }

            Text {
              id: trashLabel
              anchors.left: parent.left
              anchors.leftMargin: 8
              anchors.right: parent.right
              anchors.rightMargin: 8
              anchors.verticalCenter: parent.verticalCenter
              text: trashEntry.danger
                ? "Click again to empty" : trashEntry.modelData.text
              elide: Text.ElideRight
              color: trashEntry.danger ? Zenon.red : Zenon.white
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Medium
              font.pixelSize: 15
            }

            MouseArea {
              id: trashRowHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (trashEntry.modelData.id === "open") {
                  root.openTrash();
                  return;
                }
                // arm, then do — emptying cannot be undone
                if (!root.trashArmed) root.trashArmed = true;
                else root.emptyTrash();
              }
              // moving off the armed row disarms it, so it cannot sit primed
              // waiting for a stray click later
              onExited: if (trashEntry.modelData.id === "empty") root.trashArmed = false;
            }
          }
        }
      }
    }
  }

  // ── apps submenu ────────────────────────────────────────────────
  PanelWindow {
    id: appsMenu
    visible: root.shown && root.childMenu === "apps"
    focusable: false
    aboveWindows: true
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region { item: appsBg }
    anchors { top: true; left: true }
    screen: root.screen
    implicitWidth: 300 + Zenon.shadowPad * 2
    implicitHeight: {
      if (!root.screen) return 300 + Zenon.shadowPad * 2;
      const maxBgH = root.screen.height - Zenon.shadowPad * 2;
      return Math.min(appsContent.implicitHeight + 12, maxBgH) + Zenon.shadowPad * 2;
    }

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
      const bgH = appsMenu.implicitHeight - pad * 2;
      let bgY = parentBgY;
      if (bgY + bgH > root.screen.height - pad) bgY = root.screen.height - bgH - pad;
      if (bgY < pad) bgY = pad;
      return bgY - pad;
    }

    LayerShadow {
      panel: appsBg
      cornerRadius: 6
      morphed: false
    }

    ClippingRectangle {
      id: appsBg
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
        id: appsContent
        anchors.fill: parent
        anchors.margins: 4
        spacing: 1

        Flickable {
          id: appsFlick
          width: parent.width
          height: {
            if (!root.screen) return Math.min(500, appsRepeaterHolder.childrenRect.height);
            const maxH = root.screen.height - Zenon.shadowPad * 2 - 12;
            return Math.min(appsRepeaterHolder.childrenRect.height, Math.max(120, maxH - 6));
          }
          clip: false
          contentWidth: width
          contentHeight: appsRepeaterHolder.childrenRect.height
          boundsBehavior: Flickable.StopAtBounds
          flickDeceleration: 1800
          maximumFlickVelocity: 2800
          WheelHandler {
            onWheel: function(event) {
              if (event.angleDelta.y !== 0) {
                const delta = event.angleDelta.y > 0 ? -90 : 90
                appsFlick.contentY = Math.max(0, Math.min(appsFlick.contentHeight - appsFlick.height, appsFlick.contentY + delta * 5.6))
                event.accepted = true
              } else if (event.angleDelta.x !== 0) {
                event.accepted = true
              }
            }
          }

          Column {
            id: appsRepeaterHolder
            width: parent.width
            spacing: 1

            Repeater {
              id: appsRepeater
              model: DesktopEntries.applications

              delegate: Item {
                id: appEntry
                required property var modelData
                required property int index
                width: appsRepeaterHolder.width
                height: Math.max(28, appLabel.implicitHeight + 12)

                Rectangle {
                  anchors.fill: parent
                  radius: 0
                  color: appHover.containsMouse ? Zenon.headBg : "transparent"
                }

                Item {
                  anchors.fill: parent
                  anchors.leftMargin: 8
                  anchors.rightMargin: 8

                  Text {
                    id: appIcon
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16
                    height: 16
                    text: "󰀻"
                    color: Zenon.white
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 13
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                  }

                  Text {
                    id: appLabel
                    anchors.left: appIcon.right
                    anchors.leftMargin: 8
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignLeft
                    text: modelData.name || ""
                    elide: Text.ElideRight
                    color: Zenon.white
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.weight: Font.Medium
                    font.pixelSize: 15
                  }
                }

                MouseArea {
                  id: appHover
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.onAppChosen(modelData)
                }
              }
            }
          }
        }
      }
    }
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
                  color: fileHover.containsMouse ? Zenon.headBg : "transparent"
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
              color: (sessHover.containsMouse || isConfirmPending) ? Zenon.headBg : "transparent"
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
            color: confirmHover.containsMouse ? Zenon.headBg : "transparent"
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
            color: cancelHover.containsMouse ? Zenon.headBg : "transparent"
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
    function toggle(): void { if (root.shown) root.closeAll(); else root.openAtCursor(); }
    function openAt(x: int, y: int): void { root.openAt(Qt.point(x, y), root.screen); }
    function hide(): void { root.closeAll(); }
  }
}
