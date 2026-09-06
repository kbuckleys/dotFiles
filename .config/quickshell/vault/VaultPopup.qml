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
import "vault.js" as Vault
import "../morpheus/helpers.js" as Helpers
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

  property var statusbar: null

  readonly property color bgColor: Zenon.layerBg
  readonly property color borderColor: Zenon.surface
  readonly property color fgColor: Zenon.white
  readonly property color headColor: Zenon.cyan
  readonly property color keyColor: Zenon.keyInk
  readonly property color dimColor: Zenon.muted
  readonly property color entryColor: Zenon.pink
  readonly property color errColor: Zenon.red
  readonly property color selColor: "#4de78284"

  // mode: list · actions · unlock · error
  property string mode: "list"

  // ── the passphrase ───────────────────────────────────────────────────
  // Held the way cerberus holds it: a plain string, filled by a raw key
  // handler, never a TextInput. There is no masked-input type anywhere in this
  // shell and there does not need to be — the dots are drawn from the LENGTH,
  // so the characters themselves never reach the scene graph.
  property string pw: ""
  // input · checking · fail · success
  property string phase: "input"

  // The private channel to the pinentry helper. Vault creates this immediately
  // before an unlock and removes it immediately after; its existence is also
  // what tells the helper to answer instead of drawing a window, so a stale one
  // would hijack `rbw` in a terminal — hence the sweep in ensureRbwConfig.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string fifoPath: popup.runtimeDir + "/vault-pinentry"
  readonly property string pinentryPath: Helpers.script("vault-pinentry.sh")
  readonly property string rbwConfigPath:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
      + "/rbw/config.json"

  // rbw cannot be used at all without an account address, and vault cannot
  // invent one — this drives a plain instruction in the unlock view rather
  // than an empty list nobody can explain.
  property bool emailSet: true

  // which question the in-flight `rbw unlocked` is answering
  property string checkFor: ""

  property string query: ""
  property var entries: []
  property var filtered: []
  property int sel: 0

  // the entry whose action strip is open
  property var activeEntry: null
  property string pendingKind: ""
  property int actionSel: 0
  readonly property var actionTypes: [
    { kind: "both",     label: "Type both" },
    { kind: "user",     label: "Type user" },
    { kind: "pass",     label: "Type pass" },
    { kind: "totp",     label: "Type TOTP" },
    { kind: "copypass", label: "Copy pass" },
    { kind: "copyuser", label: "Copy user" },
    { kind: "copytotp", label: "Copy TOTP" },
  ]

  // the "vault locked" bar. Named because calcHeight() does arithmetic with
  // it, and a literal in both places is a literal that drifts.
  readonly property int lockBarH: 34
  readonly property int lockFieldH: 44

  readonly property int cols: 2
  // results that fit one visible column span the whole window
  readonly property int effCols:
    (popup.filtered.length >= 1 && popup.filtered.length <= popup.visibleRows)
      ? 1 : popup.cols
  readonly property int visibleRows: 7
  readonly property int cellH: 34

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
    target: "Vault"

    function toggle() { popup.toggle(); }
  }

  // ------------------------------------------------- rbw's own config --
  //
  // Vault points rbw at its helper itself, so the suite works on a new machine
  // with no manual rbw setup. `rbw config set` is the supported API and
  // preserves every other field, so this never clobbers an account.
  //
  // The path comes from Quickshell.shellDir, so it is right wherever the config
  // is checked out and gets rewritten if it moves.

  FileView {
    id: rbwCfgFile
    path: popup.rbwConfigPath
    blockLoading: true
    printErrors: false
  }

  Process { id: rbwCfgProc }
  Process { id: prepProc }

  function ensureRbwConfig() {
    // make the helper runnable from a fresh checkout, and sweep any fifo a
    // crashed session left behind before it can capture a terminal's rbw
    prepProc.command = ["sh", "-c",
      "chmod +x " + Strings.shellQuote(popup.pinentryPath)
        + (popup.runtimeDir !== "" ? "; rm -f " + Strings.shellQuote(popup.fifoPath)
            + " " + Strings.shellQuote(popup.fifoPath + ".spent") : "")];
    prepProc.running = true;

    let cfg = {};
    try { cfg = JSON.parse(rbwCfgFile.text() || "{}"); } catch (e) {}
    popup.emailSet = typeof cfg.email === "string" && cfg.email !== "";
    if (cfg.pinentry !== popup.pinentryPath) {
      rbwCfgProc.command = ["rbw", "config", "set", "pinentry", popup.pinentryPath];
      rbwCfgProc.running = true;
    }
  }

  Component.onCompleted: popup.ensureRbwConfig()

  // ------------------------------------------------------------- procs --

  Process {
    id: lsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: popup.onEntries(text)
    }
  }

  Process {
    id: syncProc
    onExited: popup.loadEntries()
  }

  // exit code tells us whether the agent is unlocked
  Process {
    id: unlockedCheck
    onExited: (exitCode) => popup.onUnlockedCheck(exitCode)
  }

  // runs the actual rbw fetch + consume pipeline; secrets stay in pipes
  // (only the failure sentinel ever reaches stdout)
  Process {
    id: actionProc
    stdout: StdioCollector {
      id: actionCol
      waitForEnd: true
    }
    onExited: popup.onActionDone()
  }

  property string errorMsg: ""
  property bool busy: false

  function loadEntries() {
    lsProc.command = ["rbw", "ls", "--raw"];
    lsProc.running = true;
  }

  function onEntries(text) {
    popup.entries = Vault.parseEntries(text);
    popup.applyFilter();
  }

  // ---------------------------------------------------------- actions --

  function currentEntry() {
    return popup.filtered[popup.sel] || null;
  }

  function openActions() {
    const e = currentEntry();
    if (!e) return;
    popup.activeEntry = e;
    popup.actionSel = 0;
    popup.query = "";
    filterInput.text = "";
    popup.applyFilter();
    popup.mode = "actions";
    popup.syncFocus();
  }

  function rbwFetch(kind, entry) {
    const id = Strings.shellQuote(entry.id);
    if (kind === "user")
      return "u=$(rbw get --field user " + id + "); ";
    if (kind === "pass")
      return "p=$(rbw get " + id + "); ";
    if (kind === "totp")
      return "t=$(rbw code " + id + "); ";
    return "";
  }

  function execute(kind) {
    const entry = popup.activeEntry;
    if (!entry) return;

    popup.pendingKind = kind;

    // consume pipelines: rbw output flows through pipes only — secrets
    // never appear in argv, env, files, or logs
    if (kind === "both") {
      actionProc.command = ["bash", "-c",
        "{ " + rbwFetch("user", entry) + "} && { " + rbwFetch("pass", entry) + "}" +
        " && sleep 0.3 && wtype \"$u\" -k Tab \"$p\""];
    } else if (kind === "user") {
      actionProc.command = ["bash", "-c",
        rbwFetch("user", entry) + "sleep 0.3 && wtype \"$u\"" +
        " || echo VAULT_ACTION_FAILED"];
    } else if (kind === "pass") {
      actionProc.command = ["bash", "-c",
        rbwFetch("pass", entry) + "sleep 0.3 && wtype \"$p\"" +
        " || echo VAULT_ACTION_FAILED"];
    } else if (kind === "totp") {
      actionProc.command = ["bash", "-c",
        rbwFetch("totp", entry) + "sleep 0.3 && wtype \"$t\"" +
        " || echo VAULT_ACTION_FAILED"];
    } else if (kind === "copypass") {
      actionProc.command = ["bash", "-c",
        rbwFetch("pass", entry) +
        "printf '%s' \"$p\" | wl-copy >/dev/null 2>&1" +
        " && sleep 30" +
        " && if [ \"$(wl-paste)\" = \"$p\" ]; then printf '' | wl-copy >/dev/null 2>&1; fi" +
        " || echo VAULT_ACTION_FAILED"];
    } else if (kind === "copyuser") {
      actionProc.command = ["bash", "-c",
        rbwFetch("user", entry) +
        "printf '%s' \"$u\" | wl-copy >/dev/null 2>&1" +
        " && sleep 30" +
        " && if [ \"$(wl-paste)\" = \"$u\" ]; then printf '' | wl-copy >/dev/null 2>&1; fi" +
        " || echo VAULT_ACTION_FAILED"];
    } else if (kind === "copytotp") {
      actionProc.command = ["bash", "-c",
        rbwFetch("totp", entry) +
        "printf '%s' \"$t\" | wl-copy >/dev/null 2>&1" +
        " && sleep 30" +
        " && if [ \"$(wl-paste)\" = \"$t\" ]; then printf '' | wl-copy >/dev/null 2>&1; fi" +
        " || echo VAULT_ACTION_FAILED"];
    } else {
      return;
    }

    // gate everything behind the agent's lock state
    checkLock("action");
  }

  // One `rbw unlocked` runner for three different questions. It used to be
  // shared implicitly between the action gate and the unlock poll, so a poll
  // tick landing during a pending action fired that action a second time.
  function checkLock(reason) {
    popup.checkFor = reason;
    unlockedCheck.command = ["rbw", "unlocked"];
    unlockedCheck.running = true;
  }

  function onUnlockedCheck(code) {
    const reason = popup.checkFor;
    popup.checkFor = "";
    const unlocked = (code === 0);

    // Asked on open, BEFORE listing. `rbw ls` on a locked vault makes the agent
    // spawn a pinentry on its own and returns nothing, which parseEntries
    // swallows — so vault used to open on "No matches found" with an invisible
    // prompt behind it, which is exactly the first-run symptom.
    if (reason === "open") {
      if (unlocked) popup.loadEntries();
      else { popup.mode = "unlock"; popup.syncFocus(); }
      return;
    }

    if (reason === "unlock") {
      if (unlocked) {
        popup.phase = "success";
        popup.mode = "list";
        popup.loadEntries();
        popup.syncFocus();
      } else {
        popup.phase = "fail";
        failReset.restart();
      }
      return;
    }

    if (!unlocked) {
      popup.mode = "unlock";
      popup.syncFocus();
      return;
    }
    popup.busy = true;
    actionProc.running = true;
    closeTimer.restart();
  }

  function onActionDone() {
    closeTimer.stop();
    popup.busy = false;
    if (actionCol.text.indexOf("VAULT_ACTION_FAILED") >= 0) {
      popup.errorMsg = popup.pendingKind === "totp"
        ? "no TOTP configured for this entry" : "action failed";
      popup.mode = "error";
      popup.syncFocus();
      return;
    }
    popup.closePopup();
  }

  Timer {
    id: closeTimer
    interval: 700
    repeat: false
    onTriggered: {
      if (popup.mode !== "actions") return;
      popup.closePopup();
    }
  }

  function detach(script) {
    if (script) Quickshell.execDetached(["bash", "-c", script]);
  }

  // The passphrase goes over this process's STDIN and nowhere else — not argv,
  // not the environment, and not disk, since a fifo has no contents. `cat`
  // forwards it into the fifo the helper is waiting on.
  Process {
    id: unlockProc
    stdinEnabled: true
    onExited: {
      // whatever happened, the fifo must not outlive the attempt
      popup.checkLock("unlock");
    }
  }

  function submitUnlock() {
    if (popup.phase !== "input") return;
    if (popup.pw === "") return;
    if (popup.runtimeDir === "") return;   // nowhere private to put the fifo
    popup.phase = "checking";
    unlockProc.command = ["bash", "-c",
      'f="$1"; rm -f "$f" "$f.spent"; mkfifo -m 600 "$f" || exit 9; ' +
      // exec 3<&0 is load-bearing. POSIX assigns /dev/null to the stdin of a
      // backgrounded job, so `cat > "$f" &` was reading nothing at all and the
      // password never reached the fifo — the helper saw an empty read and
      // reported a cancelled prompt, so EVERY unlock failed regardless of what
      // was typed. Duplicating stdin onto fd 3 first survives that assignment.
      'exec 3<&0; cat <&3 > "$f" & w=$!; rbw unlock; s=$?; ' +
      'kill "$w" 2>/dev/null; rm -f "$f" "$f.spent"; exit "$s"',
      "vault-unlock", popup.fifoPath];
    unlockProc.running = true;
    unlockProc.write(popup.pw + "\n");
    // held no longer than it takes to hand over, as cerberus does
    popup.clearPassword();
  }

  function clearPassword() { popup.pw = ""; }

  Timer {
    id: failReset
    interval: 1400
    onTriggered: popup.phase = "input"
  }

  // ------------------------------------------------------------- open --

  // fills down each column first:  1 3
  //                                2 4
  property var displayOrder: []

  function rebuildDisplayOrder() {
    const len = popup.filtered.length;
    const c = popup.effCols;
    const r = Math.max(1, Math.ceil(len / c));
    const order = [];
    for (let col = 0; col < c; ++col)
      for (let row = 0; row < r; ++row) {
        const i = col * r + row;
        if (i < len) order.push(i);
      }
    popup.displayOrder = order;
  }

  function applyFilter() {
    popup.filtered = Vault.filterEntries(popup.entries, popup.query);
    if (popup.sel >= popup.filtered.length) popup.sel = popup.filtered.length - 1;
    if (popup.sel < 0) popup.sel = 0;
    rebuildDisplayOrder();
    Qt.callLater(() => list.positionViewAtIndex(popup.sel, GridView.Contain));
  }

  function syncFocus() {
    Qt.callLater(() => {
      if (!popup.shown) return;
      if (popup.mode === "list") filterInput.forceActiveFocus();
      else bgRoot.forceActiveFocus();
    });
  }

  function openPopup() {
    popup.shown = true;
    popup.collapsing = false;
    popup.mode = "list";
    popup.query = "";
    filterInput.text = "";
    popup.sel = 0;
    popup.entries = [];
    popup.filtered = [];
    popup.pw = "";
    popup.phase = "input";
    popup.checkLock("open");

    focusRetry.counter = 0;
    focusRetry.restart();
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

  function goBack() {
    popup.mode = "list";
    popup.clearPassword();
    popup.applyFilter();
    popup.syncFocus();
  }

  // ----------------------------------------------------------- hints --

  // The caret every other input in this shell blinks. Defined once and placed
  // twice — leading an empty field, trailing the dots once there are any — so
  // it reads as one caret that moves rather than two that blink in sync.
  component Caret: Rectangle {
    id: caret
    property bool on: true
    anchors.verticalCenter: parent.verticalCenter
    width: 3
    height: 20
    radius: 1
    color: popup.entryColor
    opacity: 0.25
    visible: caret.on
    SequentialAnimation on opacity {
      running: caret.on
      loops: Animation.Infinite
      NumberAnimation { to: 1; duration: 550; easing.type: Easing.InOutSine }
      NumberAnimation { to: 0.25; duration: 550; easing.type: Easing.InOutSine }
    }
  }

  component HintBar: Item {
    id: hintBarRoot
    height: 26
    property var rows: popup.hints()
    Row {
      anchors.centerIn: parent
      spacing: 20
      Repeater {
        model: hintBarRoot.rows
        Text {
          required property var modelData
          text: "<b><span style=\"color:" + popup.keyColor + ";\">" +
            Strings.escapeHtml(modelData[0]) + "</span></b> <b><span style=\"color:" +
            popup.dimColor + ";\">" + Strings.escapeHtml(modelData[1]) + "</span></b>"
          textFormat: Text.RichText
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 13
        }
      }
    }
  }

  function hints() {
    if (popup.mode === "actions")
      return [["backspace", "back"], ["return", "execute"]];
    if (popup.mode === "unlock")
      // "return unlock" was advertised here before anything handled Return in
      // this mode; it does now. Esc clears a typed passphrase, then closes.
      return [["return", "unlock"], ["esc", "clear \u00b7 close"]];
    if (popup.mode === "error")
      return [["esc / return", "back"]];
    return [["type", "filter"], ["return", "actions"], ["alt s", "sync"],
            ["alt l", "lock"]];
  }

  // ----------------------------------------------------------- keys --

  // ---------------------------------------------------------- panel --

  MouseArea {
    anchors.fill: parent
    z: 0
    onClicked: popup.closePopup()
  }

  Item {
    id: panel
    width: 1000
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
      topLeftRadius: Zenon.pillRadius
      topRightRadius: Zenon.pillRadius
      bottomLeftRadius: Zenon.pillRadius
      bottomRightRadius: Zenon.pillRadius
      border.color: popup.morphMode ? "transparent" : popup.borderColor
      border.width: 1
      focus: true

      // ---------------------------------------------------- list view --

      Item {
        id: listView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "list" ? 1 : 0
        x: popup.mode === "list" ? 0 : -24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Item {
            id: inputBar
            width: parent.width
            height: popup.query.length > 0 ? 50 : 0
            Behavior on height { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
            clip: true

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: popup.borderColor
            }

            Row {
              anchors.fill: parent
              visible: inputBar.height > 2
              leftPadding: 16
              spacing: 12

              Text {
                text: "\uF023"
                color: popup.headColor
                anchors.verticalCenter: parent.verticalCenter
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 500
                font.pixelSize: 17
              }

              Item {
                width: parent.width - 60
                height: parent.height

                TextInput {
                  id: filterInput
                  anchors.fill: parent
                  verticalAlignment: TextInput.AlignVCenter
                  color: popup.entryColor
                  selectionColor: popup.errColor
                  selectedTextColor: "#000000"
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.weight: 500
                  font.pixelSize: 17
                  cursorVisible: activeFocus
                  cursorDelegate: Item {}
                  clip: true
                  Keys.forwardTo: bgRoot

                  Rectangle {
                    id: pulseCursor
                    anchors.left: parent.left
                    anchors.leftMargin: Math.min(filterInput.contentWidth + 2,
                                                 filterInput.width - 5)
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3
                    height: 22
                    radius: 1
                    color: popup.entryColor
                    opacity: 0.25
                    visible: filterInput.activeFocus
                    SequentialAnimation on opacity {
                      running: filterInput.activeFocus
                      loops: Animation.Infinite
                      NumberAnimation { to: 1; duration: 550; easing.type: Easing.InOutSine }
                      NumberAnimation { to: 0.25; duration: 550; easing.type: Easing.InOutSine }
                    }
                  }

                  onTextChanged: {
                    popup.query = filterInput.text;
                    popup.sel = 0;
                    popup.applyFilter();
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            height: popup.filtered.length === 0 ? 40 : 0
            Text {
              anchors.centerIn: parent
              visible: popup.filtered.length === 0
              text: "No matches found"
              color: popup.dimColor
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 600
              font.pixelSize: 15
            }
          }

          GridView {
            id: list
            width: parent.width
            height: popup.listHeight()
            clip: true
            flow: GridView.FlowLeftToRight
            cellWidth: width / popup.effCols
            cellHeight: popup.cellH
            model: popup.displayOrder
            highlightMoveDuration: 120

            delegate: Item {
              required property var modelData   // index into filtered
              required property int index
              readonly property var entry: popup.filtered[modelData]
              width: list.cellWidth
              height: list.cellHeight

              Rectangle {
                anchors.fill: parent
                color: modelData === popup.sel ? popup.selColor : "transparent"
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.right: parent.right
                anchors.rightMargin: 8
                text: {
                  if (!entry) return "";
                  const pref = entry.folder
                    ? "<span style=\"color:" + popup.dimColor + ";\">" +
                      Strings.escapeHtml(entry.folder) + "  ›  </span>" : "";
                  const usr = entry.user
                    ? "<span style=\"color:" + popup.dimColor + ";\">" +
                      Strings.escapeHtml(entry.user) + "  ·  </span>" : "";
                  return pref + usr + "<b>" +
                    Vault.highlight(entry.name, popup.query) + "</b>";
                }
                color: index === popup.sel ? popup.entryColor : popup.fgColor
                textFormat: Text.RichText
                elide: Text.ElideRight
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 16
              }

              MouseArea {
                anchors.fill: parent
                onClicked: {
                  popup.sel = index;
                  popup.openActions();
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            height: 58
            color: Zenon.headBg

            Rectangle {
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: Zenon.msgBorder
            }

            Column {
              anchors.fill: parent
              topPadding: 8
              bottomPadding: 10
              spacing: -3

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: popup.filtered.length + " Credentials"
                color: popup.headColor
                font.bold: true
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 600
                font.pixelSize: 16
              }

              HintBar { width: parent.width }
            }
          }
        }
      }

      // ------------------------------------------------- actions view --

      Item {
        id: actionsView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "actions" ? 1 : 0
        x: popup.mode === "actions" ? 0 : 24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Item { width: 1; height: 2 }

          Rectangle {
            width: parent.width
            height: 56
            color: Zenon.headBg

            Column {
              anchors.centerIn: parent
              spacing: 3

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: popup.activeEntry ? Strings.escapeHtml(popup.activeEntry.name) : ""
                color: popup.fgColor
                font.bold: true
                elide: Text.ElideMiddle
                width: Math.min(implicitWidth + 8, popup.width - 60)
                horizontalAlignment: Text.AlignHCenter
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 700
                font.pixelSize: 17
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: popup.activeEntry && popup.activeEntry.user !== ""
                text: popup.activeEntry ? popup.activeEntry.user : ""
                color: popup.dimColor
                elide: Text.ElideMiddle
                width: Math.min(implicitWidth + 8, popup.width - 80)
                horizontalAlignment: Text.AlignHCenter
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 14
              }
            }
          }

          Item { width: 1; height: 2 }

          Row {
            id: actionButtons
            width: parent.width

            Repeater {
              model: popup.actionTypes

              delegate: Item {
                required property var modelData
                required property int index
                width: actionButtons.width / popup.actionTypes.length
                height: 48

                Rectangle {
                  anchors.fill: parent
                  color: popup.actionSel === index
                    ? popup.selColor : "transparent"
                }

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: popup.actionSel === index
                    ? popup.entryColor : popup.dimColor
                  font.bold: popup.actionSel === index
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.pixelSize: 14
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: {
                    popup.actionSel = index;
                    popup.execute(modelData.kind);
                  }
                }
              }
            }
          }

          HintBar { width: parent.width }
        }
      }

      // ---------------------------------------------------- error view --

      Item {
        id: errorView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "error" ? 1 : 0
        x: popup.mode === "error" ? 0 : -24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Item { width: 1; height: 12 }

          Rectangle {
            width: parent.width
            height: 56
            color: popup.errColor

            Text {
              anchors.centerIn: parent
              text: popup.errorMsg
              color: "#000000"
              font.bold: true
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 700
              font.pixelSize: 16
            }
          }

          Item { width: 1; height: 12 }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "press esc to go back"
            color: popup.dimColor
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 14
          }
        }
      }

      // -------------------------------------------------- unlock view --

      Item {
        id: unlockView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.mode === "unlock" ? 1 : 0
        x: popup.mode === "unlock" ? 0 : 24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Rectangle {
            width: parent.width
            height: popup.lockBarH
            // A wash rather than a slab. At full strength this was the loudest
            // thing in the shell for a state that is merely normal.
            color: Qt.rgba(popup.errColor.r, popup.errColor.g,
                           popup.errColor.b, 0.22)
            topLeftRadius: 10
            topRightRadius: 10

            Text {
              anchors.centerIn: parent
              text: "vault locked"
              // black read fine on a solid slab; on a wash over a dark panel
              // it disappears, so the ink becomes the accent itself
              color: popup.errColor
              font.bold: true
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 700
              font.pixelSize: 15
            }
          }


          // ── the passphrase field ─────────────────────────────────────
          // No external prompt any more. rbw's pinentry is pointed at vault's
          // own helper (ensureRbwConfig), so the password is typed here and
          // handed straight to the agent.
          Item {
            id: field
            width: parent.width
            height: popup.lockFieldH

            // rbw cannot do anything at all without an account address, and
            // that is the one thing vault cannot fill in for you.
            Text {
              anchors.centerIn: parent
              visible: !popup.emailSet
              text: "no account set \u2014 run:  rbw config set email <you>"
              color: popup.dimColor
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 14
            }

            Item {
              id: entry
              anchors.fill: parent
              visible: popup.emailSet

              Rectangle {
                anchors.fill: parent
                color: popup.phase === "fail" ? popup.selColor : "transparent"
                Behavior on color {
                  ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
                }
              }

              // Message-or-dots and the caret ride in ONE row so the caret
              // always sits just after whatever is there, instead of two
              // centred children fighting for the same middle. A Row skips
              // invisible children, so the placeholder simply drops out once
              // there is a password to draw.
              Row {
                id: fieldRow
                anchors.centerIn: parent
                spacing: 5
                opacity: popup.phase === "checking" ? 0.45 : 1
                Behavior on opacity { NumberAnimation { duration: Zenon.fast } }

                // The lock carries the glow: it is the thing telling you the
                // field is live and waiting, in place of a caret parked on an
                // empty field.
                //
                // A REAL blurred copy stacked behind, not layer.effect with a
                // scaled shadow. A layer's texture is exactly the item's
                // bounds, so a shadow scaled past them is clipped off and all
                // that survives is the glyph itself — which reads as the glyph
                // pulsing, not as anything radiating.
                // The lock carries the glow: it is the thing telling you the
                // field is live and waiting, in place of a caret parked on an
                // empty field.
                Item {
                  id: glyphBox
                  anchors.verticalCenter: parent.verticalCenter
                  visible: popup.pw.length === 0
                  implicitWidth: lockGlyph.implicitWidth + 9
                  implicitHeight: lockGlyph.implicitHeight

                  readonly property bool lit:
                    popup.phase === "input" && popup.pw.length === 0

                  Text {
                    id: lockGlyph
                    // left-anchored, so glyphBox's extra 9px falls entirely on
                    // the right as the gap before the message
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\uF456"
                    color: popup.phase === "input" || popup.phase === "fail"
                      ? popup.errColor : popup.dimColor
                    font.family: "JetBrainsMono Nerd Font Propo"
                    // Bound to the message beside it rather than set to a
                    // number, so the two cannot drift apart later
                    font.pixelSize: fieldMsg.font.pixelSize
                  }

                  // Wide wrapper, small disc, big blur — the three together
                  // are what make it a spread glow rather than a tight ring:
                  // the disc supplies the light, the blur spreads it, and the
                  // wrapper is the room it is allowed to spread into.
                  Glow {
                    z: -1
                    anchors.centerIn: lockGlyph
                    width: lockGlyph.implicitHeight * 4.2
                    height: width
                    ink: popup.errColor
                    // square source on a square wrapper — a round bloom, which
                    // is what a glyph wants
                    sourceW: lockGlyph.implicitHeight * 1.09
                    sourceH: lockGlyph.implicitHeight * 1.09
                    soft: 48
                    visible: glyphBox.lit
                    opacity: glyphBox.glowPulse
                  }

                  // Slower than the caret's blink on purpose: this is a thing
                  // breathing, not a cursor ticking.
                  property real glowPulse: 0.40
                  SequentialAnimation on glowPulse {
                    running: glyphBox.lit
                    loops: Animation.Infinite
                    NumberAnimation { to: 1.0; duration: 1300; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 0.40; duration: 1300; easing.type: Easing.InOutSine }
                  }
                }

                Text {
                  id: fieldMsg
                  anchors.verticalCenter: parent.verticalCenter
                  visible: popup.pw.length === 0
                  text: popup.phase === "checking" ? "unlocking\u2026"
                    : popup.phase === "fail" ? "wrong master password"
                    : popup.phase === "success" ? "unlocked"
                    : "input your master password"
                  color: popup.phase === "fail" ? popup.errColor : popup.dimColor
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.pixelSize: 14
                }

                // The COUNT is the model — the characters never reach the
                // scene graph. Straight out of cerberus.
                Repeater {
                  model: popup.phase === "success" ? 0 : popup.pw.length
                  delegate: Text {
                    anchors.verticalCenter: parent.verticalCenter
                    // U+F09DE, past the BMP, so it is written as the surrogate
                    // pair a QML string literal needs
                    text: "\uDB82\uDDDE"
                    color: popup.entryColor
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 15
                  }
                }

                Caret { on: popup.phase === "input" && popup.pw.length > 0 }
              }

              // a wrong passphrase should be felt, not just read
              SequentialAnimation {
                id: shake
                running: popup.phase === "fail"
                NumberAnimation { target: entry; property: "x"; to:  9; duration: 55 }
                NumberAnimation { target: entry; property: "x"; to: -7; duration: 90 }
                NumberAnimation { target: entry; property: "x"; to:  4; duration: 80 }
                NumberAnimation { target: entry; property: "x"; to:  0; duration: 70 }
              }
            }
          }

          HintBar { width: parent.width }

        }
      }

  Keys.onEscapePressed: (event) => {
    event.accepted = true;
    if (popup.mode === "list" && filterInput.text !== "") {
      filterInput.text = "";
    } else if (popup.mode === "list") popup.closePopup();
    else if (popup.mode === "error") popup.openActions();
    else if (popup.mode === "unlock") {
      // there is nothing behind a locked vault to go back TO — going "back"
      // used to land on an empty list with no explanation
      if (popup.pw !== "") popup.clearPassword();
      else popup.closePopup();
    }
    else popup.goBack();
  }

  Keys.onPressed: (event) => {
    if (popup.mode === "list") {
      if ((event.key === Qt.Key_S) && (event.modifiers & Qt.AltModifier)) {
        event.accepted = true;
        syncProc.command = ["rbw", "sync"];
        syncProc.running = true;
        return;
      }
      if ((event.key === Qt.Key_L) && (event.modifiers & Qt.AltModifier)) {
        event.accepted = true;
        popup.closePopup();
        popup.detach("rbw lock");
        return;
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        event.accepted = true;
        popup.openActions();
        return;
      }
      if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
        event.accepted = true;
        popup.moveSel(event.key === Qt.Key_PageUp
          ? -popup.visibleRows * popup.effCols : popup.visibleRows * popup.effCols);
        return;
      }
      if (event.key === Qt.Key_Up) {
        event.accepted = true; popup.moveVert(-1); return;
      }
      if (event.key === Qt.Key_Down) {
        event.accepted = true; popup.moveVert(1); return;
      }
      if (event.key === Qt.Key_Left) {
        event.accepted = true; popup.moveHoriz(-1); return;
      }
      if (event.key === Qt.Key_Right) {
        event.accepted = true; popup.moveHoriz(1); return;
      }
    } else if (popup.mode === "unlock") {
      // The whole field, in one place. Backspace deletes a character here
      // rather than leaving the mode — escape is how you leave.
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        event.accepted = true;
        popup.submitUnlock();
      } else if (event.key === Qt.Key_Backspace) {
        event.accepted = true;
        if (popup.pw.length > 0) {
          // Array.from, not slice(0,-1): a codepoint outside the BMP is two
          // UTF-16 units and slicing would leave half of one behind
          const chars = Array.from(popup.pw);
          chars.pop();
          popup.pw = chars.join("");
        }
      } else if (event.text && event.text.length > 0 &&
                 !(event.modifiers & Qt.ControlModifier) &&
                 !(event.modifiers & Qt.MetaModifier)) {
        event.accepted = true;
        if (popup.phase === "input") popup.pw += event.text;
      }
    } else if (event.key === Qt.Key_Backspace && popup.mode === "actions") {
      event.accepted = true;
      popup.goBack();
    } else if (popup.mode === "actions") {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        event.accepted = true;
        popup.execute(popup.actionTypes[popup.actionSel].kind);
        return;
      }
      if (event.key === Qt.Key_Left || event.key === Qt.Key_Tab) {
        event.accepted = true;
        popup.actionSel = (popup.actionSel + popup.actionTypes.length - 1) %
          popup.actionTypes.length;
        return;
      }
      if (event.key === Qt.Key_Right) {
        event.accepted = true;
        popup.actionSel = (popup.actionSel + 1) % popup.actionTypes.length;
        return;
      }
    } else if (popup.mode === "error") {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter ||
          event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace) {
        event.accepted = true;
        popup.openActions();
        return;
      }
    }
  }
    }
  }

  // -------------------------------------------------------- helpers --

  function listHeight() {
    if (popup.filtered.length === 0) return 0;
    const needed = Math.ceil(popup.filtered.length / popup.effCols);
    return Math.max(1, Math.min(needed, popup.visibleRows)) * popup.cellH;
  }

  function calcHeight() {
    if (popup.mode === "list")
      return (popup.query.length > 0 ? 50 : 0) + (popup.filtered.length === 0 ? 40 : popup.listHeight()) + 58;
    if (popup.mode === "actions")
      return 2 + 56 + 2 + 48 + 26;
    if (popup.mode === "error")
      return 12 + 56 + 12 + 24;
    return popup.lockBarH + popup.lockFieldH + 26;
  }

  // column-major display: down = next credential, right = next column
  function moveVert(delta) {
    moveSel(delta);
  }

  function moveHoriz(delta) {
    popup.moveSel(delta * popup.effCols);
  }

  function moveSel(delta) {
    const len = popup.filtered.length;
    if (len === 0) return;
    popup.sel = ((popup.sel + delta) % len + len) % len;
    Qt.callLater(() => list.positionViewAtIndex(popup.sel, GridView.Contain));
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
      popup.syncFocus();
      if ((popup.mode === "list" && filterInput.activeFocus) ||
          (popup.mode !== "list" && bgRoot.activeFocus)) stop();
      if (focusRetry.counter++ > 12) stop();
    }
    property int counter: 0
  }
}
