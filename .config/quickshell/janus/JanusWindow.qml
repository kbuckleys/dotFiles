// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// JANUS — the file manager. God of doorways and thresholds, which is what a
// directory is, and two-faced, which is where a second pane would go.
//
// A FloatingWindow, NOT a PanelWindow. Every other surface in this shell is
// layer-shell: it floats above the desktop, hyprland cannot tile it, and it
// owns the keyboard through a focus grab until it closes. That is right for a
// launcher you use for four seconds and wrong for a window you work in — so
// this one is an ordinary xdg-toplevel. Hyprland tiles it, floats it, moves it
// between workspaces and applies window rules to it exactly as it would to a
// terminal, because from the compositor's side there is nothing to tell them
// apart. It carries a title so a rule can find it:
//
//     windowrulev2 = float, title:^(janus)$
//
// Consequences of not being a layer, all deliberate: no morph into the pill,
// no HyprlandFocusGrab, no bottomLift, and no entry in shell.qml's height
// switch. It opens, it sits where the compositor puts it, and it closes.

import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import QtQuick.Effects
import "../morpheus"
import "../picasso"
import "janus.js" as Janus
import "icons.js" as Icons

FloatingWindow {
  id: root

  title: "janus"
  // The manager that made this window, so a window can ask for another one
  // without knowing how they are kept.
  property var mgr: null
  property int winId: 0

  // The manager reaches in through these rather than through ids. An id is
  // private to the document that declares it — `w.content` from outside is
  // undefined, and reading `.activeFocus` off undefined is what made every
  // ipc call that touched focus return nothing at all.
  function takeFocus() { content.forceActiveFocus(); }
  function focusSaveField() { saveField.forceActiveFocus(); }
  // Ask for the keyboard and keep asking. The right entry point for anything
  // that has just made this window visible: a bare forceActiveFocus() on that
  // frame is dropped, because the surface has not been mapped yet.
  function claimFocus() { focusClaim.restart(); }

  // The context menu, reached through the root object.
  //
  // An INLINE COMPONENT cannot see the ids of the document that declares it —
  // only the root object, which is why everything in here goes through `root`.
  // EntryRow called `menu.openAt` directly, so right-clicking a row in list or
  // columns view threw ReferenceError and no menu ever came up; the grid's own
  // tiles are written at document scope, so the same gesture worked there and
  // the two halves disagreed for no visible reason.
  //
  // The bookmark sidebar had the identical bug against `bookmarkFile`, which
  // is what made removed bookmarks come back. One wrapper per id that a
  // delegate needs, and the trap is closed.
  function openMenuAt(item, mouse) { menu.openAt(item, mouse); }
  function openMenuHere(item, mouse) { menu.openHere(item, mouse); }
  function setSaveName(n) { saveField.text = n; }
  readonly property bool hasFocus: content.activeFocus

  color: Zenon.layerBg
  minimumSize: Qt.size(560, 320)
  // An explicit size, because nothing else supplies one. Every item inside is
  // anchored to its parent, so no implicit size propagates up from the content
  // and the surface is created 0x0 — which a compositor is free to simply not
  // show. Tiled, hyprland overrides both of these immediately; floating, they
  // are the size it opens at.
  implicitWidth: 1100
  implicitHeight: 680

  // `shown` and `visible` are kept in step BOTH WAYS, and neither is a binding.
  //
  // Two bugs live here, and the second one hid behind the first.
  //
  // Writing `visible` directly did not stick: `visible: false` on the window is
  // a constant binding, and an imperative write races whatever re-evaluates it,
  // so toggle() answered "closed" having just set it true.
  //
  // Binding it the other way — `visible: root.shown` — fixed opening but broke
  // reopening. When the COMPOSITOR closes the window it writes `visible` itself,
  // and an imperative write to a bound property destroys the binding. `shown`
  // was then stuck true against a window that was gone, so the next `shown =
  // true` changed nothing at all and no surface was ever created. That is why
  // the portal accepted a request, reported picking=true, and showed nothing.
  //
  // Handlers in both directions, with no binding to break: setting `shown`
  // shows the window, and the window being closed by anything else puts `shown`
  // back. Neither can loop, because QML does not re-emit a change that did not
  // change anything.
  property bool shown: false
  onVisibleChanged: {
    if (root.shown !== root.visible) root.shown = root.visible;
    if (root.visible) focusClaim.restart();
  }

  // ── where we are ────────────────────────────────────────────────────────
  property string cwd: Paths.home()
  property var rows: []
  property string query: ""
  property bool showHidden: true
  property string sortKey: "name"
  property bool sortDesc: false
  property int sel: 0
  // path -> true. A map rather than a list so a row can ask about itself in
  // constant time while the list is being drawn.
  property var marked: ({})
  // what y or d put down, waiting for a p somewhere else
  // What y or d put down, waiting for a p somewhere else — and "somewhere
  // else" now includes ANOTHER WINDOW. The buffer belongs to the manager, so
  // copying in one janus and pasting in another is the same gesture it always
  // was. A binding rather than a copy, so both windows' status lines and menus
  // notice the moment either of them yanks. Written through setPending.
  readonly property var pending: root.mgr ? root.mgr.clipboard : null
  function setPending(v) { if (root.mgr) root.mgr.clipboard = v; }
  property string status: ""

  // ── watching the directory ──────────────────────────────────────────────
  // Until now the listing only changed when JANUS changed it: navigate, or
  // finish an action, and it re-read. Anything done by another program — a
  // download landing, a build writing output, a file removed in a terminal —
  // went unnoticed until you left the directory and came back.
  //
  // inotifywait, because there is no alternative in reach: quickshell exposes
  // no QFileSystemWatcher to QML, and FileView's `watchChanges` watches a
  // single named file rather than a directory's contents. inotify is the
  // kernel's own answer and inotify-tools is already installed.
  //
  // -m keeps it running and prints a line per event; -q drops the startup
  // banner so the only output is events. One directory, not recursive: this
  // is about the listing on screen, and -r on a deep tree costs a watch
  // descriptor per directory underneath it.
  Process {
    id: watchProc
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: (line) => watchSettle.restart()
    }
  }

  // Coalesced. A single `cp` of a large file emits create, then a stream of
  // close_write/attrib events; re-reading the directory for each one would be
  // a find per event. One re-read once the noise stops is the same answer for
  // a fraction of the work.
  Timer {
    id: watchSettle
    interval: 250
    onTriggered: if (root.searchMode === "") root.refresh()
  }

  function watch() {
    watchProc.running = false;
    // nothing to watch while hidden, and nothing to watch while showing search
    // results, which are not a directory
    if (!root.shown || root.cwd === "" || root.searchMode !== "") return;
    watchProc.command = ["inotifywait", "-m", "-q",
      "-e", "create", "-e", "delete", "-e", "moved_to", "-e", "moved_from",
      "-e", "close_write", "-e", "attrib", "--", root.cwd];
    watchProc.running = true;
  }

  onCwdChanged: {
    root.watch();
    // one handler per signal: remembering the open tabs lives here too
    viewSave.restart();
  }
  onSearchModeChanged: root.watch()
  onShownChanged: {
    root.visible = root.shown;
    root.watch();
  }

  // ── the sidebar ─────────────────────────────────────────────────────────
  // Bookmarks and disks, in a column you can put away. It replaces the strip
  // of bookmark chips that used to sit across the top: chips were fine for
  // four and useless for twenty, and there was nowhere to put a disk.
  property bool sidebar: false
  // How wide it is when open. Dragged by the divider, kept between sessions
  // with the other view preferences, and clamped so it can be neither a sliver
  // nor most of the window.
  property real sidebarWidth: 200
  // A shade under the list, and the number is small because it COMPOSITES.
  //
  // The sidebar is painted over the window's own ground, which is layerBg —
  // 80% black over the blurred desktop. An alpha of 0.90 here does not mean
  // "90% black on screen", it means 0.90 laid over 0.80, which comes out at
  // 0.98: near enough solid, and the reason the sidebar read as a hole cut in
  // the window. 0.25 over 0.80 lands at 0.85 — a shade under the listing,
  // which is all that was wanted, and the blur still carries through.
  readonly property color sidebarBg: Qt.rgba(0, 0, 0, 0.25)
  readonly property real sidebarMin: 130
  readonly property real sidebarMax: 420

  property var disks: []
  property string diskKey: ""
  // false until the first poll has landed, so the machine's own disks are not
  // mistaken for something you just plugged in
  property bool diskSeen: false

  Process {
    id: diskProc
    stdout: StdioCollector {
      id: diskOut
      waitForEnd: true
      onStreamFinished: {
        const found = Janus.parseDisks(diskOut.text);
        const key = Janus.diskKey(found);
        if (key === root.diskKey) return;
        // Something appeared or was mounted. Opening the sidebar unasked is
        // justified exactly once — when a disk shows up that was NOT THERE A
        // MOMENT AGO, which is the moment you want to see it.
        //
        // `seen` is what makes that "a moment ago" real. Without it the first
        // poll of the session counted every disk in the machine as newly
        // arrived and threw the sidebar open on startup, every time.
        const grew = root.diskSeen && found.length > root.disks.length;
        root.disks = found;
        root.diskKey = key;
        root.diskSeen = true;
        if (grew && root.visible) root.sidebar = true;
      }
    }
  }

  // Polled rather than watched. udisks has a D-Bus signal for this and
  // quickshell can listen to D-Bus — but the polling costs one lsblk every
  // four seconds and needs no service to be running, and a file manager that
  // notices a USB stick three seconds late has still noticed it.
  Timer {
    interval: 4000
    running: root.visible
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!diskProc.running) {
      diskProc.command = ["sh", "-c", Janus.disksCommand()];
      diskProc.running = true;
    }
  }

  Process {
    id: mountProc
    stdout: StdioCollector {
      id: mountOut
      waitForEnd: true
      onStreamFinished: {
        const t = String(mountOut.text || "").trim();
        root.status = t.split("\n")[0];
        // re-read straight away rather than waiting for the next tick, so the
        // row stops saying "mount" the instant it is mounted
        root.diskKey = "";
        diskProc.command = ["sh", "-c", Janus.disksCommand()];
        diskProc.running = true;
      }
    }
  }

  function mountDisk(d) {
    mountProc.command = ["sh", "-c", d.mount === ""
      ? Janus.mountCommand(d.path) : Janus.unmountCommand(d.path)];
    mountProc.running = true;
  }

  // ── thumbnails ──────────────────────────────────────────────────────────
  // Generated for the whole directory at once when the grid is what is on
  // screen, and only then: a folder you are looking at as a list does not need
  // 256px PNGs of everything in it. `thumbTick` is what tells the tiles to
  // look again once the batch has finished.
  // path -> true once a batch has actually produced its thumbnail. A tile
  // points at the original until its entry appears here.
  //
  // Without this the tiles guessed, and every guess that lost printed
  // "Cannot open: …/thumbs/xxxx.png" into the log — one line per image per
  // visit, for a file that was about to exist. Asking the batch what it made
  // is the difference between a fallback and a warning.
  property var thumbReady: ({})
  property var thumbJobs: []

  Process {
    id: thumbProc
    onExited: {
      const next = Object.assign({}, root.thumbReady);
      for (const j of root.thumbJobs) next[j.src] = true;
      root.thumbReady = next;
      root.thumbJobs = [];
    }
  }

  function makeThumbs() {
    if (root.viewMode !== "grid" || thumbProc.running) return;
    const jobs = [];
    for (const r of root.view) {
      if (r.isDir) continue;
      const vid = Janus.isVideo(r.name);
      if (!vid && !Janus.isImage(r.name)) continue;
      if (root.thumbReady[r.path]) continue;
      jobs.push({ src: r.path, out: Janus.thumbPath(r.path, r.mtime),
                  kind: vid ? "v" : "i" });
    }
    if (jobs.length === 0) return;
    root.thumbJobs = jobs;
    thumbProc.command = ["sh", "-c", Janus.thumbBatch(jobs)];
    thumbProc.running = true;
  }

  // ── history ─────────────────────────────────────────────────────────────
  // Back and forward, on the two side buttons every browser and file manager
  // has put them on. A branch clears the forward stack, which is what makes it
  // a history rather than a ring.
  property var back: []
  property var forward: []

  function goBack() {
    if (root.back.length === 0) return;
    const b = root.back.slice();
    const to = b.pop();
    // if we are stepping up into an ancestor, mark where we came from so the
    // cursor lands on it — the same courtesy `h` gets
    if (root.cwd.indexOf(to) === 0 && to !== root.cwd) root.wantSel = root.cwd;
    const f = root.forward.slice(); f.push(root.cwd);
    root.back = b; root.forward = f;
    root.enter(to);
  }

  function goForward() {
    if (root.forward.length === 0) return;
    const f = root.forward.slice();
    const to = f.pop();
    const b = root.back.slice(); b.push(root.cwd);
    root.back = b; root.forward = f;
    root.enter(to);
  }

  // ── searching ───────────────────────────────────────────────────────────
  // "" while browsing, "find" or "grep" while showing results. Results replace
  // the listing rather than opening a pane: they ARE what you are looking at,
  // and every verb should act on them exactly as it acts on a directory.
  property string searchMode: ""
  property string searchQuery: ""

  Process {
    id: searchProc
    stdout: StdioCollector {
      id: searchOut
      waitForEnd: true
      onStreamFinished: {
        const paths = String(searchOut.text || "").split("\u0000")
          .map((x) => x.replace(/\/+$/, ""))
          .filter((x) => x !== "");
        if (paths.length === 0) {
          root.rows = [];
          root.status = "no matches";
          return;
        }
        statProc.command = ["sh", "-c", Janus.statCommand(paths)];
        statProc.running = true;
      }
    }
  }

  Process {
    id: statProc
    stdout: StdioCollector {
      id: statOut
      waitForEnd: true
      onStreamFinished: {
        root.rows = root.enrich(Janus.parseStat(statOut.text));
        root.sel = 0;
        root.status = root.rows.length + " matches";
        Qt.callLater(root.positionSel);
      }
    }
  }

  function search(mode, query) {
    if (query === "") return;
    root.searchMode = mode;
    root.searchQuery = query;
    root.rows = [];
    root.status = "searching…";
    searchProc.command = ["sh", "-c", mode === "grep"
      ? Janus.grepCommand(root.cwd, query) : Janus.findCommand(root.cwd, query)];
    searchProc.running = true;
  }

  function clearSearch() {
    if (root.searchMode === "") return;
    root.searchMode = "";
    root.searchQuery = "";
    root.refresh(true);
  }

  // ── tabs ────────────────────────────────────────────────────────────────
  // `cwd` and `sel` stay the live values rather than being read out of the tab
  // array, because every binding in this window already reads them. A switch
  // saves the pair into the tab being left and loads the pair from the tab
  // being entered — so tabs cost one array and two assignments, and nothing
  // downstream has to know they exist.
  property var tabs: [{ cwd: Paths.home(), sel: 0 }]
  property int tab: 0

  // `tabs` only learns the current tab's cwd when you switch away from it, so
  // the live one is folded in here rather than trusting the stored copy.
  function tabList() {
    const out = [];
    for (let i = 0; i < root.tabs.length; ++i) {
      out.push(i === root.tab ? { cwd: root.cwd, sel: root.sel }
                              : { cwd: root.tabs[i].cwd, sel: root.tabs[i].sel });
    }
    return out;
  }

  function saveTab() {
    const next = root.tabs.slice();
    next[root.tab] = { cwd: root.cwd, sel: root.sel };
    root.tabs = next;
  }

  onTabsChanged: viewSave.restart()
  onTabChanged: viewSave.restart()

  function switchTab(i) {
    if (i === root.tab || i < 0 || i >= root.tabs.length) return;
    root.saveTab();
    root.tab = i;
    const t = root.tabs[i];
    root.cwd = t.cwd;
    root.query = "";
    filterField.text = "";
    root.marked = {};
    root.sel = t.sel;
    root.refresh(true);
  }

  // A new tab opens where you are, not at home: you split a tab off because
  // you want a second view of the thing you are already looking at.
  // A directory in a tab of its own, without leaving the one you are in —
  // which is the difference between this and `t`.
  function openInNewTab(path) {
    root.saveTab();
    const next = root.tabs.slice();
    next.push({ cwd: path, sel: 0 });
    root.tabs = next;
    root.tab = next.length - 1;
    root.cwd = path;
    root.query = "";
    filterField.text = "";
    root.marked = {};
    root.sel = 0;
    root.refresh(true);
  }

  function newTab() {
    root.saveTab();
    const next = root.tabs.slice();
    next.push({ cwd: root.cwd, sel: root.sel });
    root.tabs = next;
    root.tab = next.length - 1;
  }

  function closeTab() {
    if (root.tabs.length < 2) return;   // the last tab is just the window
    const next = root.tabs.slice();
    next.splice(root.tab, 1);
    const land = Math.min(root.tab, next.length - 1);
    root.tabs = next;
    root.tab = -1;          // force switchTab to do the load
    root.tab = land;
    const t = next[land];
    root.cwd = t.cwd;
    root.sel = t.sel;
    root.query = "";
    filterField.text = "";
    root.marked = {};
    root.refresh(true);
  }

  // ── zoom ────────────────────────────────────────────────────────────────
  // One number, applied to the sizes that carry information — row height, the
  // glyph, the name, and the grid's cell. Not a scale transform on the whole
  // window: that would blur the text and enlarge the chrome, and the chrome is
  // not what you are trying to see more of.
  // TWO zooms, because they are two different questions.
  //
  // `zoom` scales the rows and the type in list and columns view — how much
  // text fits. `thumbZoom` scales the tiles in the grid — how big the pictures
  // are. One shared number meant sizing your thumbnails up to look at a photo
  // also blew up every row in the other two views, and each had to be undone
  // separately on the way back.
  //
  // Which one a zoom gesture moves is decided by the view you are in, so
  // ctrl+= means "more of what I am looking at" wherever you are.
  property real zoom: 1.0
  property real thumbZoom: 1.0
  readonly property real zoomMin: 0.7
  readonly property real zoomMax: 2.4

  // The zoom that the view on screen is actually using.
  readonly property real activeZoom: root.viewMode === "grid" ? root.thumbZoom : root.zoom

  function zoomClamp(v) {
    return Math.max(root.zoomMin, Math.min(root.zoomMax, v));
  }

  function zoomBy(step) {
    if (root.viewMode === "grid") root.thumbZoom = root.zoomClamp(root.thumbZoom + step);
    else root.zoom = root.zoomClamp(root.zoom + step);
    Qt.callLater(root.positionSel);
  }

  function zoomReset() {
    if (root.viewMode === "grid") root.thumbZoom = 1.0;
    else root.zoom = 1.0;
    Qt.callLater(root.positionSel);
  }

  // ── bookmarks ───────────────────────────────────────────────────────────
  // Kept in the shell's own state directory, not next to the config: it is
  // something you accumulate by using janus, not something you write by hand.
  property var bookmarks: []

  FileView {
    id: bookmarkFile
    path: Quickshell.statePath("janus-bookmarks")
    blockLoading: true
    printErrors: false
    // FileView can watch its own file, which is the one kind of watching
    // quickshell does offer — so a bookmark added in another janus window, or
    // edited by hand, shows up here without a restart
    watchChanges: true
    // reload() FIRST, and this is the whole bug that was here.
    //
    // `fileChanged` says the file on disk is not what we have; it does not
    // refresh anything by itself, and text() kept answering with the cached
    // copy. So every window held whatever the list was when it was created,
    // and one window's write was the other's snapshot from minutes ago —
    // bookmarks you had already removed reappearing the next time you added
    // one, which is exactly how this was reported.
    onFileChanged: {
      bookmarkFile.reload();
      root.loadBookmarks();
    }
  }

  function loadBookmarks() {
    const raw = String(bookmarkFile.text() || "").split("\n")
      .map((l) => l.trim()).filter((l) => l !== "");
    root.bookmarks = raw;
  }

  function isBookmarked(path) { return root.bookmarks.indexOf(path) >= 0; }

  // Every change goes through here, and it re-reads before it writes.
  //
  // The list is shared by every janus window, so "what I think it is" is not
  // good enough to base a write on — the copy in hand can be stale, and a
  // read-modify-write on a stale copy silently reverts whatever another window
  // did. Re-reading immediately before mutating makes the last write win on
  // the CURRENT list rather than on an old one.
  function editBookmarks(mutate) {
    bookmarkFile.reload();
    root.loadBookmarks();
    const next = root.bookmarks.slice();
    mutate(next);
    root.bookmarks = next;
    bookmarkFile.setText(next.join("\n") + "\n");
  }

  // One key, both directions: bookmarking the folder you are in and removing
  // it again are the same gesture, and a separate "unbookmark" would need you
  // to know which one you had. Takes any folder, not just the one you are
  // standing in.
  function toggleBookmarkFor(path) {
    let removed = false;
    root.editBookmarks((list) => {
      const at = list.indexOf(path);
      removed = at >= 0;
      if (removed) list.splice(at, 1);
      else list.push(path);
    });
    root.status = removed ? "bookmark removed" : "bookmarked";
  }

  function removeBookmark(path) {
    root.editBookmarks((list) => {
      const at = list.indexOf(path);
      if (at >= 0) list.splice(at, 1);
    });
    root.status = "bookmark removed";
  }

  function toggleBookmark() { root.toggleBookmarkFor(root.cwd); }

  // ── taking the keyboard ─────────────────────────────────────────────────
  // forceActiveFocus() on the frame `visible` is set does nothing: the surface
  // has not been mapped yet, so there is no window for the focus to be active
  // IN, and the call is silently dropped. Every caller here used to make it
  // anyway, which is why the window opened and then ignored every key — the
  // compositor had focused it and Qt had no focus item inside it.
  //
  // So it asks until it has it, the same way cerberus does, and stops the
  // moment it does. Twelve tries at 60ms is well past the point a surface that
  // is going to map has mapped.
  Timer {
    id: focusClaim
    interval: 60
    repeat: true
    property int tries: 0
    // A save dialog wants the NAME FIELD, not the listing — you are there to
    // type a filename. Asked each tick rather than latched at restart, because
    // `portal` is assigned in the same breath as `shown`.
    readonly property Item want: (root.portal && root.portal.save) ? saveField : content
    onRunningChanged: if (running) tries = 0
    onTriggered: {
      if (!root.shown || focusClaim.want.activeFocus || focusClaim.tries++ > 12) {
        focusClaim.stop();
        return;
      }
      focusClaim.want.forceActiveFocus();
    }
  }

  // ── portal mode ─────────────────────────────────────────────────────────
  // What xdg-desktop-portal-termfilechooser asks for when an application says
  // "open a file". The portal runs a wrapper script, the wrapper hands the
  // request here over ipc and then waits, and janus answers by writing the
  // chosen paths — one per line — into the file the portal named.
  //
  // Three shapes of request, and they are genuinely different tasks:
  //   open   pick one or more existing things
  //   dir    pick a directory, which means the one you are IN counts
  //   save   type a name for something that does not exist yet
  //
  // A `done` marker is written beside the output file whether the pick was
  // confirmed or cancelled. Without it the wrapper cannot tell "still
  // choosing" from "chose nothing", and a cancel would hang the application
  // that asked until the wrapper's patience ran out.
  property var portal: null   // { multiple, directory, save, out }
  readonly property bool picking: root.portal !== null

  readonly property string portalTitle: {
    if (!root.portal) return "";
    if (root.portal.save) return "Save as";
    if (root.portal.directory) return "Choose a folder";
    return root.portal.multiple ? "Choose files" : "Choose a file";
  }

  // What confirming would hand back, so the button can say how many and refuse
  // when there is nothing to give.
  readonly property var portalChoice: {
    if (!root.portal) return [];
    if (root.portal.save) {
      const n = saveField.text;
      return Janus.nameError(n) === "" ? [Janus.joinPath(root.cwd, n)] : [];
    }
    if (root.portal.directory) {
      // a marked directory if you marked one, otherwise the one you are
      // standing in — which is what "choose this folder" means
      const dirs = root.markedRows().filter((r) => r.isDir);
      if (dirs.length > 0) return dirs.map((r) => r.path);
      const c = root.currentRow();
      if (c && c.isDir) return [c.path];
      return [root.cwd];
    }
    const files = root.acting().filter((r) => !r.isDir);
    if (files.length === 0) return [];
    return root.portal.multiple ? files.map((r) => r.path) : [files[0].path];
  }

  Process {
    id: sizeProc
    stdout: StdioCollector {
      id: sizeOut
      waitForEnd: true
      onStreamFinished: props.walked = parseFloat(String(sizeOut.text).trim()) || 0
    }
  }

  Process {
    id: ownerProc
    stdout: StdioCollector {
      id: ownerOut
      waitForEnd: true
      onStreamFinished: props.owner = String(ownerOut.text || "").trim()
    }
  }

  // The window decides WHAT the answer is; the manager writes it.
  //
  // A picker window is destroyed the moment it answers, and a Process owned by
  // it would be torn down mid-write — leaving the portal waiting forever on a
  // `.done` marker that never arrived. So the reply goes out through the
  // manager, which outlives the dialog.
  Process {
    id: imageProc
    stdout: StdioCollector {
      id: imageOut
      waitForEnd: true
      onStreamFinished: props.imageInfo = Janus.parseImageInfo(imageOut.text)
    }
  }

  Process {
    id: sumProc
    stdout: StdioCollector {
      id: sumOut
      waitForEnd: true
      onStreamFinished: {
        const t = String(sumOut.text || "").trim();
        props.checksum = t === "" ? "unreadable" : t;
      }
    }
  }

  function portalAnswer(paths) {
    if (!root.portal) return;
    const out = root.portal.out;
    root.portal = null;
    if (root.mgr) {
      root.mgr.answerPortal(out, paths);
      // a dedicated dialog is done existing, not merely hidden
      if (root.mgr.pickerWin === root) { root.mgr.retirePicker(); return; }
    }
    root.shown = false;
  }

  function portalConfirm() {
    const c = root.portalChoice;
    if (c.length === 0) return;
    root.portalAnswer(c);
  }

  function portalCancel() { root.portalAnswer([]); }

  // ── which way it is laid out ────────────────────────────────────────────
  //   list    one row per entry, with size and date. What you want when the
  //           question is "how big" or "when did I touch this".
  //   columns yazi's miller layout — parent, here, and a preview of whatever
  //           is under the cursor. What you want while NAVIGATING, because
  //           you can see where you came from and where you are about to go
  //           without moving.
  //   grid    thumbnails. What you want in a folder of pictures, where the
  //           filename is the least useful thing about the file.
  property string viewMode: "columns"
  readonly property var viewRing: ["columns", "list", "grid"]

  function cycleView() {
    const i = root.viewRing.indexOf(root.viewMode);
    root.viewMode = root.viewRing[(i + 1) % root.viewRing.length];
    Qt.callLater(root.positionSel);
  }

  // ── what it opens as ────────────────────────────────────────────────────
  // The view you were last in, not the one the file happens to declare above.
  // Columns is the right DEFAULT — it is what you want while navigating — but
  // it is a poor thing to be dropped back into every single time when you live
  // in thumbnails, and re-pressing `v` twice on every launch is not a setting.
  //
  // The view PREFERENCES travel together because they are one answer to "how
  // do I like looking at files": which layout, how big, sorted how, and
  // whether the dotfiles are in. Where you were is deliberately not in here —
  // a file manager that reopens in last week's directory is a surprise, not a
  // convenience.
  FileView {
    id: viewFile
    path: Quickshell.statePath("janus-view.json")
    blockLoading: true
    printErrors: false
  }

  // Debounced, because zoom arrives as a burst of ctrl-+ and writing the file
  // on every step would be a dozen writes for one gesture.
  Timer {
    id: viewSave
    interval: 400
    onTriggered: {
      // A PICKER is not a preference. pick() forces columns so the dialog is
      // always laid out the way a dialog should be, and letting that overwrite
      // the view you actually chose would mean every save dialog reset it.
      if (root.picking) return;
      // The OPEN TABS travel with the view preferences, because they are the
      // same question: how was this window set up when I left it. Only window 0
      // restores them — a spare window you opened with N is a scratch view, and
      // a picker is not a window you own at all.
      viewFile.setText(JSON.stringify({
        tabs: root.winId === 0 ? root.tabList() : undefined,
        tab: root.winId === 0 ? root.tab : undefined,
        view: root.viewMode,
        zoom: root.zoom,
        sidebar: root.sidebar,
        sidebarWidth: root.sidebarWidth,
        thumbZoom: root.thumbZoom,
        sortKey: root.sortKey,
        sortDesc: root.sortDesc,
        showHidden: root.showHidden
      }) + "\n");
    }
  }

  function loadViewPrefs() {
    const raw = String(viewFile.text() || "").trim();
    if (raw === "") return;
    let s = null;
    // A half-written or hand-edited file must not take the window down with
    // it: bad preferences are worth less than a working file manager.
    try { s = JSON.parse(raw); } catch (e) { return; }
    if (!s) return;
    if (root.viewRing.indexOf(s.view) >= 0) root.viewMode = s.view;
    const z = Number(s.zoom);
    if (!isNaN(z) && z > 0) root.zoom = root.zoomClamp(z);
    const tz = Number(s.thumbZoom);
    if (!isNaN(tz) && tz > 0) root.thumbZoom = root.zoomClamp(tz);
    if (typeof s.sidebar === "boolean") root.sidebar = s.sidebar;
    const sw = Number(s.sidebarWidth);
    if (!isNaN(sw) && sw > 0)
      root.sidebarWidth = Math.max(root.sidebarMin, Math.min(root.sidebarMax, sw));
    if (typeof s.sortKey === "string" && s.sortKey !== "") root.sortKey = s.sortKey;
    if (typeof s.sortDesc === "boolean") root.sortDesc = s.sortDesc;
    if (typeof s.showHidden === "boolean") root.showHidden = s.showHidden;
    root.restoreTabs(s);
  }

  // Reopening where you left off, but only the tabs whose directories are still
  // there — a tab pointing at a removed download or an unmounted disk would be
  // a window that opens on an error. Checked by the caller, which is why this
  // hands the surviving list to a process rather than trusting the file.
  function restoreTabs(st) {
    if (root.winId !== 0) return;
    if (!st.tabs || st.tabs.length === 0) return;
    const want = [];
    for (let i = 0; i < st.tabs.length; ++i) {
      const t = st.tabs[i];
      if (t && typeof t.cwd === "string" && t.cwd !== "") want.push(t);
    }
    if (want.length === 0) return;
    root.pendingTabs = want;
    root.pendingTabIndex = (typeof st.tab === "number") ? st.tab : 0;
    tabCheckProc.command = ["sh", "-c",
      "for d in " + want.map((t) => Strings.shellQuote(t.cwd)).join(" ")
        + "; do [ -d \"$d\" ] && printf '%s\\036' \"$d\"; done"];
    tabCheckProc.running = true;
  }

  property var pendingTabs: []
  property int pendingTabIndex: 0

  Process {
    id: tabCheckProc
    stdout: StdioCollector {
      id: tabCheckOut
      waitForEnd: true
      onStreamFinished: {
        const alive = {};
        for (const d of String(tabCheckOut.text || "").split("\u001e")) {
          if (d !== "") alive[d] = true;
        }
        const kept = root.pendingTabs.filter((t) => alive[t.cwd]);
        root.pendingTabs = [];
        if (kept.length === 0) return;
        root.tabs = kept;
        root.tab = Math.max(0, Math.min(kept.length - 1, root.pendingTabIndex));
        const t = kept[root.tab];
        root.sel = t.sel || 0;
        // enter() rather than goTo(): this is where the window already is as
        // far as history is concerned, not somewhere it navigated to.
        root.enter(t.cwd);
      }
    }
  }

  onZoomChanged: viewSave.restart()
  onSidebarChanged: viewSave.restart()
  onSidebarWidthChanged: viewSave.restart()
  onThumbZoomChanged: viewSave.restart()
  onSortKeyChanged: viewSave.restart()
  onSortDescChanged: viewSave.restart()
  onShowHiddenChanged: viewSave.restart()

  // Every view scrolls its own way, and only one of them is on screen — but
  // telling all three is cheaper than asking which, and means switching view
  // never lands you somewhere other than where the cursor was.
  function positionSel() {
    list.positionViewAtIndex(root.sel, ListView.Contain);
    midList.positionViewAtIndex(root.sel, ListView.Contain);
    grid.positionViewAtIndex(root.sel, GridView.Contain);
  }

  // ── the parent, for the left column ─────────────────────────────────────
  property var parentRows: []

  Process {
    id: parentProc
    stdout: StdioCollector {
      id: parentOut
      waitForEnd: true
      onStreamFinished: {
        const dir = Janus.dirname(root.cwd);
        root.parentRows = root.enrich(Janus.sortEntries(
          Janus.filterEntries(Janus.parseListing(parentOut.text, dir), "", root.showHidden),
          root.sortKey, root.sortDesc));
        Qt.callLater(() => parentList.positionViewAtIndex(root.parentIndex, ListView.Contain));
      }
    }
  }

  // where the directory we are IN sits in its own parent, so the left column
  // can mark it the way the middle column marks the cursor
  readonly property int parentIndex: {
    for (let i = 0; i < root.parentRows.length; ++i)
      if (root.parentRows[i].path === root.cwd) return i;
    return -1;
  }

  // ── the preview, for the right column ───────────────────────────────────
  // What the preview has already produced, keyed by path. Walking back up a
  // list re-selects rows you were just on, and re-running bat and re-laying
  // out its markup to show you the same thing again is the delay you feel.
  // Capped, because a preview of a big file is a big string.
  property var previewCache: ({})
  property var previewOrder: []

  function cachePreview(path, entry) {
    const c = Object.assign({}, root.previewCache);
    const o = root.previewOrder.slice();
    c[path] = entry;
    o.push(path);
    while (o.length > 24) delete c[o.shift()];
    root.previewCache = c;
    root.previewOrder = o;
  }

  property string previewKind: "none"   // none | dir | image | video | pdf | text | archive | binary
  // Where a rendered PDF page lands. One name, reused: only one preview is on
  // screen at a time, so keeping every page ever looked at would be a cache
  // nobody reads. `previewStamp` busts Qt's image cache, which would otherwise
  // show the previous PDF at the same path.
  readonly property string pdfStem: Paths.cacheDir() + "/janus-preview"
  property int previewStamp: 0
  property var previewRows: []
  property string previewText: ""

  // Debounced, not immediate. Holding Down through a directory would otherwise
  // start a process per row and finish them in an order nobody asked for; this
  // way only the row you actually stopped on is ever read.
  Timer {
    id: previewDelay
    // shorter than it was: the work behind a landing is now capped output, a
    // smaller relayout and often a cache hit, so waiting 110ms to start it was
    // most of the delay rather than a guard against it
    interval: 55
    onTriggered: root.loadPreview()
  }

  // The cache is tried SYNCHRONOUSLY, before the debounce. A row you have
  // already looked at needs no process and no parse, so making it wait 55ms
  // behind a timer that exists to avoid spawning things was the one delay with
  // nothing behind it — walking back up a list is now instant.
  onSelChanged: {
    if (root.viewMode !== "columns") return;
    const r = root.currentRow();
    const hit = r ? root.previewCache[r.path] : undefined;
    if (hit !== undefined) {
      previewDelay.stop();
      root.previewKind = hit.kind;
      root.previewRows = hit.rows || [];
      root.previewText = hit.text || "";
      return;
    }
    // an image needs no process either: the pane points Qt at the file
    if (r && !r.isDir && Janus.isImage(r.name)) {
      previewDelay.stop();
      root.previewKind = "image";
      root.previewRows = [];
      root.previewText = "";
      return;
    }
    previewDelay.restart();
  }
  onViewModeChanged: {
    if (root.viewMode === "columns") previewDelay.restart();
    root.makeThumbs();
    // one handler per signal, so remembering the view lives here too
    viewSave.restart();
  }

  Process {
    id: previewProc
    stdout: StdioCollector {
      id: previewOut
      waitForEnd: true
      onStreamFinished: {
        const t = previewOut.text;
        const cur = root.currentRow();
        if (root.previewKind === "dir") {
          const rows = cur
            ? root.enrich(Janus.sortEntries(
                Janus.filterEntries(Janus.parseListing(t, cur.path), "", root.showHidden),
                root.sortKey, root.sortDesc))
            : [];
          root.previewRows = rows;
          if (cur) root.cachePreview(cur.path, { kind: "dir", rows: rows });
        } else if (root.previewKind === "archive") {
          const rich = Janus.archivePreview(t);
          root.previewText = rich;
          // an unreadable or empty archive is still not text
          if (rich === "") root.previewKind = "binary";
          if (cur) root.cachePreview(cur.path,
            { kind: root.previewKind, text: rich });
        } else if (Janus.looksBinary(t)) {
          root.previewKind = "binary";
          root.previewText = "";
          if (cur) root.cachePreview(cur.path, { kind: "binary" });
        } else {
          root.previewKind = "text";
          const rich = Janus.ansiToRich(t);
          root.previewText = rich;
          if (cur) root.cachePreview(cur.path, { kind: "text", text: rich });
        }
      }
    }
  }

  function loadPreview() {
    if (root.viewMode !== "columns") return;
    const r = root.currentRow();
    if (!r) {
      root.previewKind = "none";
      root.previewRows = [];
      root.previewText = "";
      return;
    }

    // already known: no process, no parse, no relayout
    const hit = root.previewCache[r.path];
    if (hit !== undefined) {
      root.previewKind = hit.kind;
      root.previewRows = hit.rows || [];
      root.previewText = hit.text || "";
      return;
    }

    root.previewRows = [];
    root.previewText = "";
    if (r.isDir) {
      root.previewKind = "dir";
      previewProc.command = ["sh", "-c", Janus.peekCommand(r.path)];
      previewProc.running = true;
      return;
    }
    if (Janus.isImage(r.name)) { root.previewKind = "image"; return; }
    if (Janus.isVideo(r.name)) {
      root.previewKind = "video";
      // the same cached frame the grid uses, made on demand if the grid has
      // not already asked for it
      if (!root.thumbReady[r.path]) {
        root.thumbJobs = [{ src: r.path, out: Janus.thumbPath(r.path, r.mtime),
                            kind: "v" }];
        thumbProc.command = ["sh", "-c", Janus.thumbBatch(root.thumbJobs)];
        thumbProc.running = true;
      }
      return;
    }
    // An archive shows what is inside it. "binary" is true of a .tar.zst and
    // tells you nothing you wanted to know before extracting it.
    if (Janus.isArchive(r.name)) {
      root.previewKind = "archive";
      previewProc.command = ["sh", "-c", Janus.archiveListCommand(r.path)];
      previewProc.running = true;
      return;
    }
    if (Janus.isPdf(r.name)) {
      root.previewKind = "pdf";
      pdfProc.command = ["sh", "-c", Janus.pdfCommand(r.path, root.pdfStem)];
      pdfProc.running = true;
      return;
    }
    root.previewKind = "text";
    previewProc.command = ["sh", "-c", Janus.batCommand(r.path)];
    previewProc.running = true;
  }

  Process {
    id: pdfProc
    onExited: (code) => {
      // the stamp is what makes Qt reload a file it has already cached under
      // this exact name
      if (code === 0 && root.previewKind === "pdf") root.previewStamp++;
    }
  }

  // Which yazi flavor to read the glyphs out of. Named rather than written
  // into the path, so switching flavors is one word.
  property string flavor: "ZENON"
  property var iconMaps: ({ conds: {}, files: {}, dirs: {}, exts: {} })

  // Two steps, so a keystroke does not re-sort.
  //
  // `sorted` changes when the directory, the sort or the hidden toggle changes
  // — rarely. `view` is that list filtered by what you have typed, and a
  // filter cannot change the order of what survives it. One expression did
  // both, so every character re-sorted the whole directory.
  readonly property var sorted:
    Janus.sortEntries(Janus.filterEntries(root.rows, "", root.showHidden),
                      root.sortKey, root.sortDesc)

  readonly property var view: Janus.filterQuery(root.sorted, root.query)

  // FUNCTIONS, not bindings. As properties these recomputed whenever `marked`
  // changed — every pointer move of a drag-select — and the context menu's
  // item list depended on `acting`, so it rebuilt its labels each time even
  // while closed. Nothing needs either until something acts.
  function markedRows() {
    const out = [];
    for (let i = 0; i < root.view.length; ++i)
      if (root.marked[root.view[i].path]) out.push(root.view[i]);
    return out;
  }

  // What a verb acts on: everything ticked, or the row under the cursor when
  // nothing is. The same rule zeus' kill list uses, and the reason you can
  // rename a file without marking it first.
  function acting() {
    const m = root.markedRows();
    if (m.length > 0) return m;
    const r = root.view[root.sel];
    return r ? [r] : [];
  }

  function currentRow() { return root.view[root.sel] || null; }

  // The colour and the glyph are worked out ONCE PER LISTING and stored on the
  // row, not asked for every time a delegate is drawn.
  //
  // They used to be functions called from bindings, which means once per row
  // per repaint: categoryOf does string work and glyphFor does map lookups,
  // and in a directory of a couple of thousand entries that is the frame
  // budget spent on answers that cannot change. `enrich` runs over the rows as
  // they arrive and the delegates read a field.
  function inkFor(e) {
    if (!e) return Zenon.muted;
    return e.ink !== undefined ? e.ink : Zenon.white;
  }

  function inkOf(e) {
    if (e.isDir) return Zenon.cyan;
    const cat = Janus.categoryOf(e.name);
    if (cat === "image") return Zenon.green;
    if (cat === "media") return Zenon.sand;
    if (cat === "archive") return Zenon.yellow;
    if (cat === "document") return Zenon.cyan;
    if (e.broken) return Zenon.red;
    if (e.isLink) return Zenon.magenta;
    if (e.isExec) return Zenon.yellow;
    if (e.size === 0) return Zenon.muted;
    return Zenon.white;
  }

  function enrich(rows) {
    for (const r of rows) {
      r.ink = root.inkOf(r);
      r.glyph = Icons.glyphFor(root.iconMaps, r);
    }
    return rows;
  }

  // ── the glyphs ──────────────────────────────────────────────────────────
  FileView {
    id: iconFile
    path: Icons.flavorPath(Paths.configDir(), root.flavor)
    blockLoading: true
    printErrors: false
  }

  Component.onCompleted: {
    root.iconMaps = Icons.parse(iconFile.text());
    root.loadBookmarks();
    // before the first listing: the sort and the hidden-file setting decide
    // what that listing turns into, so reading them afterwards would show one
    // arrangement and then rearrange it in front of you
    root.loadViewPrefs();
    root.refresh(true);
  }

  // ── reading the directory ───────────────────────────────────────────────
  Process {
    id: listProc
    stdout: StdioCollector {
      id: listOut
      waitForEnd: true
      onStreamFinished: {
        // Byte-identical output means nothing in this directory changed, so
        // there is nothing to redraw. inotify fires close_write and attrib for
        // files whose presence, size and mtime are all unchanged, and
        // rebuilding the model for those was pure churn — one string compare
        // makes them free.
        // null, never "", is the "nothing loaded yet" sentinel — see the
        // property's own note. An EMPTY DIRECTORY prints nothing, so an empty
        // string is a perfectly real listing and must not read as "unchanged".
        if (listOut.text === root.lastListing) return;
        root.lastListing = listOut.text;
        root.rows = root.enrich(Janus.parseListing(listOut.text, root.cwd));
        // Land on the directory we just came out of rather than on the first
        // row: walking up and back down a tree should return you to where you
        // were, not to the top of every level on the way.
        if (root.wantSel !== "") {
          const want = root.wantSel;
          root.wantSel = "";
          for (let i = 0; i < root.view.length; ++i) {
            if (root.view[i].path === want) { root.sel = i; root.anchor = i; break; }
          }
        }
        Qt.callLater(root.makeThumbs);
        if (root.sel >= root.view.length) root.sel = Math.max(0, root.view.length - 1);
        Qt.callLater(root.positionSel);
      }
    }
  }

  // `full` means the DIRECTORY changed. A plain refresh — after an action, or
  // when inotify says something moved in the current directory — re-reads only
  // the current listing.
  //
  // It used to do all three every time: current listing, parent listing and a
  // preview reload. The parent cannot have changed unless you moved, and the
  // preview cannot have changed unless the cursor moved, so an event in the
  // current directory cost three processes and three model swaps to answer a
  // question about one of them. That was the redraw in the split view.
  function refresh(full) {
    if (root.searchMode !== "") return;   // results are not a directory
    listProc.command = ["sh", "-c", Janus.listCommand(root.cwd)];
    listProc.running = true;
    if (full) {
      parentProc.command = ["sh", "-c", Janus.listCommand(Janus.dirname(root.cwd))];
      parentProc.running = true;
      previewDelay.restart();
    }
  }

  function goTo(path) {
    if (path === root.cwd) return;
    const b = root.back.slice(); b.push(root.cwd);
    root.back = b;
    root.forward = [];
    root.enter(path);
  }

  // the move itself, with no history bookkeeping — what back and forward use
  function enter(path) {
    root.searchMode = "";
    root.searchQuery = "";
    root.lastListing = null;   // a new directory is always a change
    root.cwd = path;
    root.query = "";
    filterField.text = "";
    root.marked = {};
    root.sel = 0;
    root.refresh(true);
  }

  // The path to put the cursor on once the next listing arrives. A directory
  // is not in the list yet when you ask to leave it, so the wish is recorded
  // and the listing honours it.
  property string wantSel: ""

  // The raw output the current rows were built from, for the comparison above.
  //
  // `var` holding null rather than an empty string, and that is not a style
  // choice. "" was the sentinel for "nothing loaded yet" — but "" is also
  // exactly what `find` prints for an EMPTY DIRECTORY, so walking into one
  // compared "" against "", decided nothing had changed, and left the previous
  // directory's rows on screen under the new breadcrumb. null can never be a
  // listing, so it can never collide with one.
  property var lastListing: null

  function goUp() {
    const from = root.cwd;
    if (from === "/") return;
    root.wantSel = from;
    root.goTo(Janus.dirname(from));
  }

  function activate() {
    const r = root.currentRow();
    if (!r) return;
    if (r.isDir) { root.goTo(r.path); return; }

    // While a portal request is open, opening a FILE means something else.
    // Handing it to xdg-open would launch an application on top of a dialog
    // the caller is still blocked on — the one thing a picker must not do.
    if (root.picking) {
      if (root.portal.save) {
        // saving: the file you opened is the one you mean to replace, so its
        // name goes in the field and the overwrite is yours to confirm
        saveField.text = r.name;
        saveField.forceActiveFocus();
      } else {
        root.portalConfirm();
      }
      return;
    }

    root.run(Janus.openCommand(r.path));
  }

  // ── running things ──────────────────────────────────────────────────────
  // One process with a queue, so two verbs fired in quick succession cannot
  // interleave their output or race each other onto the same directory. Every
  // one of them re-reads the directory when it lands, because all of them
  // change what is in it.
  property var queue: []

  Process {
    id: actProc
    stderr: StdioCollector {
      id: actErr
      waitForEnd: true
      onStreamFinished: {
        const e = String(actErr.text || "").trim();
        if (e !== "") root.status = e.split("\n")[0];
      }
    }
    onExited: (code) => {
      if (code === 0 && root.status !== "") root.status = "";
      // emptying or restoring changes what the trash holds
      if (root.inTrash && !trashSizeProc.running) trashSizeProc.running = true;
      root.refresh();
      root.drain();
    }
  }

  function run(cmd) {
    root.queue.push(cmd);
    root.drain();
  }

  function drain() {
    if (root.queue.length === 0 || actProc.running) return;
    actProc.command = ["sh", "-c", root.queue.shift()];
    actProc.running = true;
  }

  // ── selection ───────────────────────────────────────────────────────────
  // Where a shift-range starts. Moved by a plain click and by nothing else,
  // so shift-clicking twice extends from the same place both times rather
  // than walking the anchor along behind you.
  property int anchor: 0

  // True while the pointer is over a row or a tile. The drag box asks this
  // rather than guessing from coordinates: "was the cursor actually on top of
  // the item" is exactly the question, and the items themselves know.
  property bool hoverRow: false
  // Set by the body's HoverHandler from the view's own hit test. Starts true so
  // a click that arrives before any hover still reaches the empty-space
  // handler rather than falling into a gap.
  property bool overEmpty: true

  // Which row is under a point in the body, or -1 for none.
  //
  // Asked of the VIEW, not of hover state. `hoverRow` is a single flag written
  // by every delegate's HoverHandler, so two of them crossing over write it in
  // an order nobody controls, and anything above the views that consumes hover
  // can leave it false while the pointer is plainly on a row. Routing clicks
  // through it made them land on nothing — items would not open. indexAt is
  // the view's own hit test and cannot disagree with what is drawn.
  //
  // Coordinates are the body's; each view converts to its own content space.
  function rowUnder(x, y) {
    if (root.viewMode === "list")
      return list.indexAt(x + list.contentX, y + list.contentY);
    if (root.viewMode === "grid")
      return grid.indexAt(x + grid.contentX, y + grid.contentY);
    // Miller columns: only the middle pane is the listing. The parent pane and
    // the preview beside it own their own clicks, so anything outside the
    // middle column reports "occupied" and the press is passed straight on.
    if (x < midList.x || x > midList.x + midList.width) return 0;
    return midList.indexAt(x - midList.x + midList.contentX,
                           y + midList.contentY);
  }
  // true for the whole of a row being dragged out, so the overlays that watch
  // hoverRow do not wake up when the pointer leaves the row it picked up
  property bool draggingRow: false

  // Built when the path changes, not when a crumb is drawn. The delegate asked
  // crumbs() for its own length, so rendering n crumbs cost n+1 walks of the
  // path on every repaint.
  readonly property var crumbList: Janus.crumbs(root.cwd)

  // How many are ticked, without building the list of them. The status line
  // wants a number, and markedRows scans the whole view to produce an array —
  // which it was doing on every pointer move of a drag-select.
  readonly property int markedCount: Object.keys(root.marked).length

  function markRange(a, b) {
    const lo = Math.min(a, b), hi = Math.max(a, b);
    const next = Object.assign({}, root.marked);
    for (let i = lo; i <= hi; ++i)
      if (root.view[i]) next[root.view[i].path] = true;
    root.marked = next;
  }

  function markAt(i) {
    const r = root.view[i];
    if (!r) return;
    const next = Object.assign({}, root.marked);
    if (next[r.path]) delete next[r.path];
    else next[r.path] = true;
    root.marked = next;
  }

  // The three clicks every list in every file manager has:
  //   plain  — go here, and drop whatever was selected
  //   ctrl   — add or remove this one, keep the rest
  //   shift  — everything from the anchor to here
  //
  // Right-click is deliberately none of them: you right-click a selection to
  // act on it, so clearing it first would make the menu act on one file.
  function clickRow(i, right, shift, ctrl) {
    if (shift) { root.markRange(root.anchor, i); root.sel = i; }
    else if (ctrl) { root.markAt(i); root.sel = i; }
    else {
      if (!right) root.marked = {};
      root.sel = i;
      root.anchor = i;
    }
    content.forceActiveFocus();
  }

  function toggleMark() {
    const r = root.currentRow();
    if (!r) return;
    const next = Object.assign({}, root.marked);
    if (next[r.path]) delete next[r.path];
    else next[r.path] = true;
    root.marked = next;
  }

  // How many tiles fit across, which is what up and down have to step by.
  // Asked of the view rather than recomputed from targetCell: the cell width
  // is rounded to divide the pane exactly, so dividing the pane by the TARGET
  // gives a different number at some widths.
  function gridCols() {
    return Math.max(1, Math.floor(grid.width / Math.max(1, grid.cellWidth)));
  }

  function moveSel(delta) {
    const n = root.view.length;
    if (n === 0) return;
    root.sel = Math.max(0, Math.min(n - 1, root.sel + delta));
    Qt.callLater(root.positionSel);
  }

  function cycleSort() {
    const ring = ["name", "size", "time"];
    const i = ring.indexOf(root.sortKey);
    if (i < 0 || root.sortDesc) {
      root.sortKey = ring[(Math.max(0, i) + 1) % ring.length];
      root.sortDesc = false;
    } else {
      root.sortDesc = true;
    }
  }

  // ── the verbs ───────────────────────────────────────────────────────────
  function yank(op) {
    const rows = root.acting();
    if (rows.length === 0) return;
    root.setPending({ op: op, paths: rows.map((r) => r.path),
                      names: rows.map((r) => r.name) });
    root.status = rows.length + (op === "copy" ? " to copy" : " to move");
  }

  // Nothing is written until the answer to "what is already there" comes back.
  // cp and mv overwrite in silence, so asking first is the only thing standing
  // between a paste and losing the file that was already in the destination.
  Process {
    id: conflictProc
    stdout: StdioCollector {
      id: conflictOut
      waitForEnd: true
      onStreamFinished: {
        const clash = Janus.parseConflicts(conflictOut.text);
        // The mode is a plain string, not Janus.CLASH.overwrite: a QML .js
        // import does not reliably expose top-level `const` bindings on its
        // namespace, and nothing else in this window reads one that way. The
        // names live in CLASH inside janus.js, where the comparisons are.
        if (clash.length === 0) { root.commitPaste("overwrite"); return; }
        // Three answers, and Overwrite is deliberately NOT the one Enter takes
        // by reflex being listed first — it is, because it is the one you
        // usually mean, but it wears the alarm colour so a blind Enter is at
        // least an informed one. "Keep both" renames the incoming copy; "Skip"
        // keeps what is already there and takes the rest of the selection.
        confirm.askMany(
          (root.pending.op === "copy" ? "Copy" : "Move") + " over "
            + clash.length + (clash.length === 1 ? " item" : " items") + "?",
          clash.join("   "),
          [{ label: "Overwrite", ink: Zenon.red,
             act: () => root.commitPaste("overwrite") },
           { label: "Keep both", ink: Zenon.green,
             act: () => root.commitPaste("keep") },
           { label: "Skip", ink: Zenon.blue,
             act: () => root.commitPaste("skip") }]);
      }
    }
  }

  function paste() {
    if (!root.pending || root.pending.paths.length === 0) return;
    conflictProc.command = ["sh", "-c",
      Janus.conflictCommand(root.pending.names, root.cwd)];
    conflictProc.running = true;
  }

  // ── a transfer in flight ────────────────────────────────────────────────
  // Runs beside you, not in front of you: the panel sits in the corner and
  // nothing is blocked while it works, which is the point of showing progress
  // rather than a modal.
  property var job: null      // { op, names, pct }

  Process {
    id: jobProc
    // rsync writes its progress to stdout and rewrites the line with \r, so
    // this is a stream of one growing line rather than a sequence of them.
    stdout: SplitParser {
      splitMarker: "\r"
      onRead: (line) => {
        if (!root.job) return;
        // "Keep both" copies one item at a time and announces each one, so the
        // panel can say which of them it is on rather than letting the
        // percentage drop to zero once per item with no explanation.
        const item = Janus.parseItem(line);
        if (item > 0) {
          const at = Object.assign({}, root.job);
          at.index = item;
          at.pct = 0;
          root.job = at;
          return;
        }
        const pct = Janus.parseProgress(line);
        if (pct < 0) return;
        const next = Object.assign({}, root.job);
        next.pct = pct;
        root.job = next;
      }
    }
    stderr: StdioCollector {
      id: jobErr
      waitForEnd: true
      onStreamFinished: {
        const e = String(jobErr.text || "").trim();
        if (e !== "") root.status = e.split("\n")[0];
      }
    }
    onExited: (code) => {
      root.job = null;
      // A cancel is a nonzero exit too, and reporting it as "transfer failed"
      // would be telling you something went wrong when you are the thing that
      // went wrong. cancelJob has already set the status line.
      if (code !== 0 && root.status === "") root.status = "transfer failed";
      root.marked = {};
      root.refresh();
      Qt.callLater(root.drainJobs);
    }
  }

  // Transfers QUEUE rather than collide.
  //
  // startJob used to write jobProc.command and running=true unconditionally.
  // Start a second transfer while one is running — trivial now that the yank
  // buffer is shared between windows, so a paste in each — and it overwrote the
  // command of a live Process and replaced the panel's job with the new one,
  // losing sight of the transfer still running underneath.
  //
  // One at a time, in order, for the same reason zeus' mixer serialises its
  // pactl calls: two rsyncs writing the same destination race over the same
  // names, and the conflict answer you gave applies to the state as it was
  // asked, not as the other job is leaving it.
  property var jobQueue: []

  function startJob(op, paths, dest, clash) {
    if (root.job !== null) {
      root.jobQueue = root.jobQueue.concat([
        { op: op, paths: paths, dest: dest, clash: clash }]);
      root.status = "queued " + paths.length;
      return;
    }
    root.runJob(op, paths, dest, clash);
  }

  function runJob(op, paths, dest, clash) {
    root.job = { op: op, names: paths.map((p) => Janus.basename(p)),
                 pct: 0, index: 0, total: paths.length };
    // setsid, so the job gets a process group of its own and CANCELLING it can
    // take the whole tree down. Signalling the Process itself would only reach
    // the shell and leave rsync running orphaned, still writing files.
    jobProc.command = ["setsid", "sh", "-c",
      Janus.transferCommand(paths, dest, op === "move", clash)];
    jobProc.running = true;
  }

  // The next queued transfer, or nothing. Called once the running one exits.
  function drainJobs() {
    if (root.job !== null || root.jobQueue.length === 0) return;
    const next = root.jobQueue[0];
    root.jobQueue = root.jobQueue.slice(1);
    root.runJob(next.op, next.paths, next.dest, next.clash);
  }

  // Kill the job's whole process group. The negative pid is the group, which
  // is why the job was started under setsid in the first place.
  Process { id: killProc }

  function cancelJob() {
    // The queue goes with it. Cancelling the transfer you can see while three
    // more you cannot start up behind it is not what the button says.
    root.jobQueue = [];
    if (!root.job || !jobProc.running) return;
    const pid = jobProc.processId;
    if (pid > 0) {
      killProc.command = ["sh", "-c", "kill -TERM -" + pid + " 2>/dev/null"];
      killProc.running = true;
    }
    root.status = "cancelled";
  }

  function commitPaste(clash) {
    const p = root.pending;
    if (!p) return;
    // A move is recorded as where each item was and where it is about to be,
    // so undo can put it back precisely. A copy is not recorded at all — see
    // the undo stack's own note.
    if (p.op === "move") {
      const pairs = [];
      for (let i = 0; i < p.paths.length; ++i) {
        pairs.push([p.paths[i], Janus.joinPath(root.cwd, Janus.basename(p.paths[i]))]);
      }
      root.pushUndo({ kind: "move", pairs: pairs });
    }
    root.startJob(p.op, p.paths, root.cwd, clash);
    // a move is spent once it lands; a copy can be pasted again elsewhere
    if (p.op === "move") root.setPending(null);
    root.marked = {};
  }

  function trash() {
    const rows = root.acting();
    if (rows.length === 0) return;
    confirm.ask(
      "Trash " + rows.length + (rows.length === 1 ? " item" : " items") + "?",
      rows.map((r) => r.name).join("   "), "Trash", () => {
        const paths = rows.map((r) => r.path);
        root.run(Janus.trashCommand(paths));
        // recorded by where they CAME FROM: that is what undo can look up
        root.pushUndo({ kind: "trash", paths: paths });
        root.marked = {};
      });
  }

  function beginRename() {
    const r = root.currentRow();
    if (!r) return;
    prompt.ask("Rename", r.name, (name) => {
      if (name === r.name) return;
      root.run(Janus.renameCommand(r.path, name));
      root.pushUndo({ kind: "rename", from: r.path,
                      to: Janus.joinPath(Janus.dirname(r.path), name) });
    });
  }

  // wl-copy, the same way folio puts a clip back on the clipboard
  function copyPath() {
    const rows = root.acting();
    if (rows.length === 0) return;
    root.run("printf '%s' " + Strings.shellQuote(rows.map((r) => r.path).join("\n"))
      + " | wl-copy >/dev/null 2>&1");
    root.status = "path copied";
  }

  // Straight into picasso's own store, not a command. It is a singleton in
  // this same shell, so setting a wallpaper from here is a property write and
  // the daemon repaints from the same binding the picker uses — no file to
  // hand over and nothing to keep in step.
  function setWallpaper(screenName) {
    const r = root.currentRow();
    if (!r || r.isDir || !Janus.isImage(r.name)) return;
    if (screenName) Picasso.setFor(screenName, r.path);
    else Picasso.setAll(r.path);
    root.status = "wallpaper set";
  }

  // Which rows a rubber band covers. Worked out from the geometry rather than
  // by asking each delegate whether it intersects: a ListView only realises
  // the delegates near the viewport, so anything scrolled out has no item to
  // ask — but it still has an index, and the index is what the band is really
  // selecting.
  function applyBand(x1, y1, x2, y2, base) {
    const next = Object.assign({}, base);
    let lo = -1, hi = -1;

    if (root.viewMode === "grid") {
      const cols = Math.max(1, Math.floor(grid.width / grid.cellWidth));
      const r1 = Math.floor((y1 + grid.contentY) / grid.cellHeight);
      const r2 = Math.floor((y2 + grid.contentY) / grid.cellHeight);
      const c1 = Math.floor(x1 / grid.cellWidth);
      const c2 = Math.floor(x2 / grid.cellWidth);
      for (let r = Math.max(0, r1); r <= r2; ++r) {
        for (let c = Math.max(0, c1); c <= Math.min(cols - 1, c2); ++c) {
          const i = r * cols + c;
          if (i >= 0 && i < root.view.length) next[root.view[i].path] = true;
        }
      }
      root.marked = next;
      return;
    }

    // both single-column views: the band is a range of rows
    const view = root.viewMode === "list" ? list : midList;
    // In the miller layout the middle column is inset by the parent column, so
    // a drag started over the parent or the preview is not a selection of
    // anything in the middle one and must not act like it.
    if (root.viewMode === "columns") {
      const left = parentList.width + 1;
      const right = left + midList.width;
      if (x2 < left || x1 > right) { root.marked = next; return; }
    }
    lo = Math.floor((y1 + view.contentY) / root.rowH);
    hi = Math.floor((y2 + view.contentY) / root.rowH);
    // a drag that has not crossed a row boundary selects the same rows it
    // already did, and rebuilding the map for that is work with no result
    if (lo === band.lastLo && hi === band.lastHi) return;
    band.lastLo = lo;
    band.lastHi = hi;
    for (let i = Math.max(0, lo); i <= Math.min(root.view.length - 1, hi); ++i)
      next[root.view[i].path] = true;
    root.marked = next;
  }

  // ── dragging in and out ─────────────────────────────────────────────────
  // text/uri-list is the one thing every file-aware application on the desktop
  // agrees on, so dragging a row into Firefox or a terminal hands over the
  // same list a file manager would. Dragging the CURSOR row alone would be
  // wrong when a selection exists — you dragged the selection.
  function dragUris(entry) {
    const rows = (entry && !root.marked[entry.path] && root.markedRows().length === 0)
      ? [entry] : (root.markedRows().length > 0 ? root.markedRows() : [entry]);
    return rows.filter((r) => !!r).map((r) => "file://" + encodeURI(r.path)).join("\r\n");
  }

  // What arrives from elsewhere. A copy unless the source asked for a move,
  // which is what dragging between two directories of the same disk means.
  // A drop ASKS whether it is a copy or a move.
  //
  // The action the drag carries is a guess — it comes from which modifier
  // happened to be held, and between two windows of the same application it is
  // whatever the compositor decided to propose. Copying when you meant to move
  // leaves a duplicate you have to find; moving when you meant to copy takes
  // the original away. Neither is worth inferring, so the drop says what it is
  // about to do and lets you pick. The conflict check still runs afterwards.
  function dropUris(urls, action) {
    const paths = [];
    // A drop with no file URLs at all — a text selection, a colour — is not
    // for us. Now that the DropArea takes everything, this is the filter.
    if (!urls || urls.length === 0) return;
    for (const u of urls) {
      const t = String(u);
      if (t.indexOf("file://") !== 0) continue;
      const path = decodeURIComponent(t.slice(7));
      // dropping a directory into itself is not a move, it is a mistake
      if (path === root.cwd || Janus.dirname(path) === root.cwd) continue;
      paths.push(path);
    }
    if (paths.length === 0) return;
    const names = paths.map((p) => Janus.basename(p));
    const drop = (op) => {
      root.setPending({ op: op, paths: paths, names: names });
      root.paste();
    };
    // The dragged action is offered FIRST, so the modifier you held is still
    // the one Enter takes — the prompt confirms the guess rather than
    // discarding it.
    const moving = action === Qt.MoveAction;
    const copyChoice = { label: "Copy", ink: Zenon.green, act: () => drop("copy") };
    const moveChoice = { label: "Move", ink: Zenon.yellow, act: () => drop("move") };
    confirm.askMany(
      names.length + (names.length === 1 ? " item" : " items") + " here?",
      names.join("   "),
      moving ? [moveChoice, copyChoice] : [copyChoice, moveChoice]);
  }

  // ── undo ────────────────────────────────────────────────────────────────
  // The three things that move a file out from under you, and nothing else.
  //
  // A COPY is not on the list: undoing one means deleting the copies, and a
  // stack that deletes files is a worse hazard than the mistake it fixes.
  // Trash, move and rename all have an exact inverse, which is the test for
  // belonging here.
  property var undoStack: []

  function pushUndo(entry) {
    const next = root.undoStack.slice();
    next.push(entry);
    // deep enough to cover a session's worth of slips, shallow enough that it
    // never becomes a second filesystem held in memory
    while (next.length > 20) next.shift();
    root.undoStack = next;
  }

  readonly property string undoLabel: {
    const n = root.undoStack.length;
    if (n === 0) return "";
    const e = root.undoStack[n - 1];
    if (e.kind === "trash") return "Undo trash";
    if (e.kind === "move") return "Undo move";
    return "Undo rename";
  }

  function undo() {
    if (root.undoStack.length === 0) { root.status = "nothing to undo"; return; }
    const next = root.undoStack.slice();
    const e = next.pop();
    root.undoStack = next;

    if (e.kind === "trash") {
      // by ORIGINAL PATH, not by the name in the trash: gio appends a suffix
      // when the name is already taken there, so the two are not the same
      // string and only the path is something we actually know.
      root.run(Janus.restoreCommand(e.paths, "path"));
      root.status = "restored " + e.paths.length;
      return;
    }
    if (e.kind === "move") {
      let cmd = "";
      for (let i = 0; i < e.pairs.length; ++i) {
        const from = e.pairs[i][1], to = e.pairs[i][0];
        cmd += "mkdir -p -- " + Strings.shellQuote(Janus.dirname(to))
          + " && mv -n -- " + Strings.shellQuote(from) + " "
          + Strings.shellQuote(to) + "\n";
      }
      root.run(cmd);
      root.status = "moved back " + e.pairs.length;
      return;
    }
    root.run(Janus.renameCommand(e.to, Janus.basename(e.from)));
    root.status = "rename undone";
  }

  // ── the trash, in both directions ───────────────────────────────────────
  readonly property bool inTrash: Janus.isTrashDir(root.cwd)

  // How much the trash holds, asked when you are standing in it.
  property string trashSize: ""

  Process {
    id: trashSizeProc
    command: ["sh", "-c", Janus.trashSizeCommand()]
    stdout: StdioCollector {
      id: trashSizeOut
      waitForEnd: true
      onStreamFinished: root.trashSize = String(trashSizeOut.text || "").trim()
    }
  }

  onInTrashChanged: {
    if (!root.inTrash) { root.trashSize = ""; return; }
    if (!trashSizeProc.running) trashSizeProc.running = true;
  }

  function emptyTrash() {
    confirm.ask("Empty the trash?",
      root.trashSize !== "" ? root.trashSize + " will be deleted for good"
                            : "Everything in it is deleted for good",
      "Delete", () => {
        root.run(Janus.emptyTrashCommand());
        root.marked = {};
        root.status = "trash emptied";
      });
  }

  function restoreSelected() {
    const rows = root.acting();
    if (rows.length === 0) return;
    root.run(Janus.restoreCommand(rows.map((r) => r.name), "name"));
    root.marked = {};
    root.status = "restoring " + rows.length;
  }

  // ── archives ────────────────────────────────────────────────────────────
  function extractSelected() {
    const rows = root.acting().filter((r) => !r.isDir && Janus.isArchive(r.name));
    if (rows.length === 0) { root.status = "not an archive"; return; }
    root.run(Janus.extractScript(rows.map((r) => r.path), root.cwd));
    root.marked = {};
    root.status = "extracting " + rows.length;
  }

  // yazi's `c a`. The name carries the format: ".tar.zst", ".zip", ".7z" —
  // bsdtar reads the extension and picks the writer, so there is no format
  // menu to get out of step with what the tools can actually produce.
  // The format is CHOSEN, not typed. It was a single "Compress…" that guessed
  // .tar.zst and left you to retype the extension for anything else — which
  // meant knowing which spellings bsdtar accepts. The name is still yours to
  // edit; only the extension comes from the menu.
  readonly property var archiveFormats: [
    [".tar.zst", "tar · zstd — fast, small"],
    [".tar.gz",  "tar · gzip — most portable"],
    [".tar.xz",  "tar · xz — smallest, slowest"],
    [".zip",     "zip — for other systems"],
    [".7z",      "7z — 7-Zip"]
  ]

  function beginCompress(ext) {
    const rows = root.acting();
    if (rows.length === 0) return;
    const suggested = (rows.length === 1 ? Janus.stem(rows[0].name)
                                         : Janus.basename(root.cwd))
      + (ext && ext !== "" ? ext : ".tar.zst");
    prompt.ask("Compress to", suggested, (name) => {
      if (name === "") return;
      root.run(Janus.compressCommand(rows.map((r) => r.path),
                                     Janus.joinPath(root.cwd, name)));
      root.marked = {};
      root.status = "compressing " + rows.length;
    });
  }

  // ── links ───────────────────────────────────────────────────────────────
  // Paste, but leaving the file where it is. Uses the same yank buffer as a
  // normal paste, because "what am I about to put down" is the same question.
  function pasteLink(symbolic) {
    if (!root.pending || root.pending.paths.length === 0) return;
    root.run(Janus.linkCommand(root.pending.paths, root.cwd, symbolic));
    root.status = symbolic ? "symlinked" : "hard linked";
  }

  // ── bulk rename ─────────────────────────────────────────────────────────
  function beginBulkRename() {
    const rows = root.acting();
    if (rows.length === 0) return;
    root.bulkNames = rows.map((r) => r.name);
    root.bulkDir = root.cwd;
    bulkProc.command = ["sh", "-c", Janus.bulkRenameCommand(root.bulkNames)];
    bulkProc.running = true;
    root.status = "editing " + rows.length + " names…";
  }

  property var bulkNames: []
  property string bulkDir: ""

  Process {
    id: bulkProc
    stdout: StdioCollector {
      id: bulkOut
      waitForEnd: true
      onStreamFinished: {
        const pairs = Janus.bulkPairs(root.bulkNames, bulkOut.text);
        // Refused rather than half-applied. A list that came back the wrong
        // length, with a duplicate, or with a slash in it is a list we cannot
        // act on safely — and renaming the first half of it would leave the
        // directory in a state nobody asked for.
        if (pairs === null) { root.status = "bulk rename refused: list changed shape"; return; }
        if (pairs.length === 0) { root.status = "no names changed"; return; }
        root.run(Janus.bulkRenameApply(root.bulkDir, pairs));
        root.status = "renamed " + pairs.length;
      }
    }
  }

  // ── open with ───────────────────────────────────────────────────────────
  // Filled in when the menu opens, because it costs a process and almost every
  // right-click is not about this.
  property var openWithApps: []

  Process {
    id: appsProc
    stdout: StdioCollector {
      id: appsOut
      waitForEnd: true
      onStreamFinished: root.openWithApps = Janus.parseApps(appsOut.text)
    }
  }

  function findApps(path) {
    root.openWithApps = [];
    if (!path || appsProc.running) return;
    appsProc.command = ["sh", "-c", Janus.appsCommand(path)];
    appsProc.running = true;
  }

  function openWith(id, path) {
    root.run(Janus.openWithCommand(id, path));
  }

  function selectAll() {
    const next = {};
    for (const r of root.view) next[r.path] = true;
    root.marked = next;
  }

  function invertSelection() {
    const next = {};
    for (const r of root.view) if (!root.marked[r.path]) next[r.path] = true;
    root.marked = next;
  }

  function setSort(key) {
    if (root.sortKey === key) root.sortDesc = !root.sortDesc;
    else { root.sortKey = key; root.sortDesc = false; }
  }

  function copyText(text, note) {
    root.run("printf '%s' " + Strings.shellQuote(text) + " | wl-copy >/dev/null 2>&1");
    root.status = note;
  }

  function openShell() { root.run(Janus.shellCommand(root.cwd)); }

  // yazi's `a`. One prompt for both, because the only difference is whether
  // the name ends in a slash — which is how yazi says it too.
  function beginCreate() {
    prompt.ask("New file or folder/", "", (name) => {
      root.run(Janus.createCommand(root.cwd, name));
    });
  }

  // yazi's `D`. Not the trash, and worded so the card cannot be mistaken for
  // the one that is recoverable.
  function deleteForever() {
    const rows = root.acting();
    if (rows.length === 0) return;
    confirm.ask(
      "Delete " + rows.length + (rows.length === 1 ? " item" : " items")
        + " permanently?",
      "This does not go to the trash.  "
        + rows.map((r) => r.name).join("   "),
      "Delete", () => {
        root.run(Janus.deleteCommand(rows.map((r) => r.path)));
        root.marked = {};
      });
  }

  function beginSearch(mode) {
    prompt.ask(mode === "grep" ? "Search contents" : "Search names",
               root.searchQuery, (q) => root.search(mode, q));
  }

  function beginMkdir() {
    prompt.ask("New folder", "", (name) => {
      root.run(Janus.mkdirCommand(root.cwd, name));
    });
  }

  // ── chrome ──────────────────────────────────────────────────────────────
  readonly property int rowH: Math.round(28 * root.zoom)
  // Tight. One line of type, so 40 was leaving a band of air under the text
  // once the separator at the bottom was counted as part of the bar.
  readonly property int headH: 34
  readonly property int hintH: 30

  Item {
    id: content
    anchors.fill: parent
    focus: true

    // Keys land here, not on the filter field: the field only takes them while
    // it has focus, and it only has focus while you are filtering. That is what
    // buys the bare-letter verbs — y, d, p, n — that a permanently focused
    // field would have swallowed. Zeus had to put its sort on Alt+S for exactly
    // that reason; this window does not have to.
    // The side buttons, on the whole surface rather than a row: back and
    // forward are about the window, not about whatever the pointer happens to
    // be over, and over an empty listing there is no row to be over.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.BackButton | Qt.ForwardButton
      onPressed: (m) => {
        // Mouse 4 goes UP a directory, not back through history — the same
        // thing backspace does. Up is where you almost always mean to go, and
        // it is predictable: back depends on the path you took to get here,
        // which you cannot see. Mouse 5 still walks history forward.
        if (m.button === Qt.BackButton) root.goUp();
        else if (m.button === Qt.ForwardButton) root.goForward();
      }
    }

    // ── the keymap ────────────────────────────────────────────────────
    // Yazi's, because that is the muscle memory this replaces. Including its
    // SEQUENCES: g d, c m, b a and so on are two keystrokes, so a pending
    // prefix has to be held between them, and any key that is not a valid
    // continuation cancels it rather than doing something else.
    property string pending: ""

    // The sequences, once. The bar along the bottom renders these and the key
    // handler dispatches them, so a destination cannot be listed without
    // working or work without being listed — they were two lists before, which
    // is two chances to disagree.
    readonly property var sequences: ({
      g: [
        ["g", "top",       () => { root.sel = 0; root.positionSel(); }],
        ["h", "home",      () => root.goTo(Paths.home())],
        ["c", "config",    () => root.goTo(Paths.configDir())],
        ["d", "downloads", () => root.goTo(Paths.home() + "/Downloads")],
        ["D", "documents", () => root.goTo(Paths.home() + "/Documents")],
        ["p", "pictures",  () => root.goTo(Paths.home() + "/Pictures")],
        ["v", "videos",    () => root.goTo(Paths.home() + "/Videos")],
        ["t", "trash",     () => root.goTo(Paths.home() + "/.local/share/Trash/files")],
        ["m", "media",     () => root.goTo("/run/media")],
        ["/", "root",      () => root.goTo("/")],
        [" ", "type a path", () => pathBar.begin()]
      ],
      c: [
        ["c", "copy path",     () => { const r = root.currentRow();
                                       if (r) root.copyText(r.path, "path copied"); }],
        ["d", "copy dirname",  () => { const r = root.currentRow();
                                       if (r) root.copyText(Janus.dirname(r.path), "dirname copied"); }],
        ["f", "copy filename", () => { const r = root.currentRow();
                                       if (r) root.copyText(r.name, "filename copied"); }],
        ["n", "copy name",     () => { const r = root.currentRow();
                                       if (r) root.copyText(Janus.stem(r.name), "name copied"); }],
        ["m", "permissions",   () => perms.ask()],
        ["a", "archive",       () => root.beginCompress("")]
      ],
      b: [
        ["a", "bookmark here",   () => root.toggleBookmark()],
        ["d", "remove bookmark", () => root.toggleBookmark()]
      ],
      ",": [
        ["n", "by name",     () => root.setSort("name")],
        ["s", "by size",     () => root.setSort("size")],
        ["m", "by modified", () => root.setSort("time")],
        ["!", "reverse",     () => root.sortDesc = !root.sortDesc]
      ]
    })

    // No timer. It used to give up after 1200ms, which meant a menu you were
    // still reading closed itself; it now stays until you choose or press
    // escape, and a key that is not one of the choices is ignored rather than
    // taken as a reason to dismiss.
    function seq(prefix) { content.pending = prefix; }
    function done() { content.pending = ""; }

    Keys.onPressed: (event) => {
      if (confirm.open || prompt.open || perms.open || props.open) return;
      if (help.open) {
        event.accepted = true;
        help.open = false;
        return;
      }
      if (menu.open) {
        if (event.key === Qt.Key_Escape) { event.accepted = true; menu.close(); }
        return;
      }

      // A portal request outranks everything: an application is blocked on the
      // answer, so return hands it over and escape tells it no.
      if (root.picking) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          event.accepted = true; root.portalConfirm(); return;
        }
        if (event.key === Qt.Key_Escape) {
          event.accepted = true; root.portalCancel(); return;
        }
      }

      if (event.key === Qt.Key_F1) {
        event.accepted = true; help.open = true; return;
      }

      // ── a pending prefix owns the next key ──────────────────────────
      if (content.pending !== "") {
        event.accepted = true;
        if (event.key === Qt.Key_Escape) { content.done(); return; }
        // A bare modifier is a key event of its own with no text, and holding
        // shift to reach an upper-case destination sends one before the letter
        // arrives. Treating that as "not a choice, so dismiss" is what made
        // `g` then shift-D impossible: the menu was gone before the D landed.
        if (event.text === "") return;
        const list = content.sequences[content.pending] || [];
        for (const entry of list) {
          if (entry[0] === event.text) {
            content.done();
            entry[2]();
            return;
          }
        }
        // not one of the choices: leave the menu up rather than closing on a
        // stray keystroke
        return;
      }

      // ── escape, in the order things unwind ──────────────────────────
      // Escape unwinds what you are in the middle of, and stops there. It does
      // NOT close the window: a file manager you are browsing should not
      // vanish because you dismissed a filter twice. `q` quits, the way it
      // does in yazi, and a PICKER still cancels on escape — an application is
      // blocked on that answer, so escape means "no" and is handled above.
      if (event.key === Qt.Key_Escape) {
        event.accepted = true;
        if (root.searchMode !== "") root.clearSearch();
        else if (root.query !== "") { filterField.text = ""; root.query = ""; }
        else if (Object.keys(root.marked).length > 0) root.marked = {};
        return;
      }

      // ── movement ────────────────────────────────────────────────────
      // The GRID IS TWO-DIMENSIONAL, and it has to be asked first.
      //
      // This block used to sit below the plain up/down handlers, which meant
      // it could never run for them: they matched, moved by one tile, and
      // returned. So the grid navigated in a straight line through a layout
      // that is laid out in rows — down moved you one tile sideways instead of
      // one row down. Left and right reached here only because nothing above
      // claimed them.
      //
      // h and l still mean parent and enter: they are the same two keys in
      // every yazi layout, and there is no second axis for them to mean.
      if (root.viewMode === "grid") {
        if (event.key === Qt.Key_Left) {
          event.accepted = true; root.moveSel(-1); return;
        }
        if (event.key === Qt.Key_Right) {
          event.accepted = true; root.moveSel(1); return;
        }
        if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
          event.accepted = true; root.moveSel(-root.gridCols()); return;
        }
        if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
          event.accepted = true; root.moveSel(root.gridCols()); return;
        }
      }
      if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
        event.accepted = true; root.moveSel(-1); return;
      }
      if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
        event.accepted = true; root.moveSel(1); return;
      }
      if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
        event.accepted = true; root.goUp(); return;
      }
      if (event.key === Qt.Key_Right || event.key === Qt.Key_L
          || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        event.accepted = true; root.activate(); return;
      }
      if (event.key === Qt.Key_G) {
        event.accepted = true;
        if (event.modifiers & Qt.ShiftModifier) {
          root.sel = Math.max(0, root.view.length - 1);
          root.positionSel();
        } else content.seq("g");
        return;
      }
      if (event.modifiers & Qt.ControlModifier) {
        // Tab cycling and closing, where a browser puts them. Backtab is what
        // Qt reports for ctrl+shift+tab — shift turns the key itself into a
        // different one rather than only appearing in the modifiers.
        if (event.key === Qt.Key_Tab) {
          event.accepted = true;
          root.switchTab((root.tab + 1) % root.tabs.length);
          return;
        }
        if (event.key === Qt.Key_Backtab) {
          event.accepted = true;
          root.switchTab((root.tab - 1 + root.tabs.length) % root.tabs.length);
          return;
        }
        if (event.key === Qt.Key_C) { event.accepted = true; root.closeTab(); return; }
        if (event.key === Qt.Key_U) { event.accepted = true; root.moveSel(-8); return; }
        if (event.key === Qt.Key_D) { event.accepted = true; root.moveSel(8); return; }
        if (event.key === Qt.Key_B) { event.accepted = true; root.moveSel(-16); return; }
        if (event.key === Qt.Key_F) { event.accepted = true; root.moveSel(16); return; }
        if (event.key === Qt.Key_A) { event.accepted = true; root.selectAll(); return; }
        if (event.key === Qt.Key_R) { event.accepted = true; root.invertSelection(); return; }
        if (event.key === Qt.Key_S) { event.accepted = true; root.openShell(); return; }
        if (event.key === Qt.Key_0) { event.accepted = true; root.zoomReset(); return; }
        // ctrl +/- as well as the bare keys: in the grid these are thumbnail
        // size, and ctrl is where every application puts that
        if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) {
          event.accepted = true; root.zoomBy(0.1); return;
        }
        if (event.key === Qt.Key_Minus) {
          event.accepted = true; root.zoomBy(-0.1); return;
        }
      }
      if (event.key === Qt.Key_PageUp)   { event.accepted = true; root.moveSel(-16); return; }
      if (event.key === Qt.Key_PageDown) { event.accepted = true; root.moveSel(16); return; }
      if (event.key === Qt.Key_Home)     { event.accepted = true; root.sel = 0; root.positionSel(); return; }
      if (event.key === Qt.Key_End) {
        event.accepted = true;
        root.sel = Math.max(0, root.view.length - 1);
        root.positionSel();
        return;
      }
      if (event.key === Qt.Key_Backspace) { event.accepted = true; root.goUp(); return; }

      // ── zoom, on the keys everything else uses ──────────────────────
      if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) {
        event.accepted = true; root.zoomBy(0.1); return;
      }
      if (event.key === Qt.Key_Minus) {
        event.accepted = true; root.zoomBy(-0.1); return;
      }

      // ── tabs ────────────────────────────────────────────────────────
      if ((event.modifiers & Qt.AltModifier)
          && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
        event.accepted = true; root.switchTab(event.key - Qt.Key_1); return;
      }
      if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9 && event.text !== "") {
        event.accepted = true; root.switchTab(event.key - Qt.Key_1); return;
      }
      if (event.key === Qt.Key_BracketLeft) {
        event.accepted = true;
        root.switchTab((root.tab - 1 + root.tabs.length) % root.tabs.length);
        return;
      }
      if (event.key === Qt.Key_BracketRight) {
        event.accepted = true;
        root.switchTab((root.tab + 1) % root.tabs.length);
        return;
      }

      if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier)) return;

      // ── everything else, by character so shift is a different key ───
      switch (event.text) {
      case " ":  event.accepted = true; root.toggleMark(); root.moveSel(1); break;
      case "y":  event.accepted = true; root.yank("copy"); break;
      case "x":  event.accepted = true; root.yank("move"); break;
      case "p":  event.accepted = true; root.paste(); break;
      case "d":  event.accepted = true; root.trash(); break;
      case "D":  event.accepted = true; root.deleteForever(); break;
      case "a":  event.accepted = true; root.beginCreate(); break;
      case "r":  event.accepted = true; root.beginRename(); break;
      case ".":  event.accepted = true; root.showHidden = !root.showHidden; break;
      case ";":  event.accepted = true; root.openShell(); break;
      case "f":  event.accepted = true; filterField.forceActiveFocus(); break;
      case "/":  event.accepted = true; filterField.forceActiveFocus(); break;
      case "s":  event.accepted = true; root.beginSearch("find"); break;
      case "S":  event.accepted = true; root.beginSearch("grep"); break;
      case "t":  event.accepted = true; root.newTab(); break;
      case "w":  event.accepted = true; root.closeTab(); break;
      case "v":  event.accepted = true; root.cycleView(); break;
      case "u":  event.accepted = true; root.undo(); break;
      case "q":
        event.accepted = true;
        // the first window hides; a spare one goes away, because a pile of
        // hidden windows nobody can reach is a leak with a keybind
        if (root.winId === 0 || !root.mgr) root.shown = false;
        else root.mgr.retire(root.winId);
        break;
      case "N":
        event.accepted = true;
        if (root.mgr) root.mgr.spawn(root.cwd);
        break;
      case "~":  event.accepted = true; help.open = true; break;
      case "g":  event.accepted = true; content.seq("g"); break;
      case "c":  event.accepted = true; content.seq("c"); break;
      case "b":  event.accepted = true; content.seq("b"); break;
      case ",":  event.accepted = true; content.seq(","); break;
      }
    }

    Column {
      id: chrome
      anchors.fill: parent

      // Softened while the keymap is up — zeus' confirm card does the same
      // thing to its views, for the same reason: the list behind a reference
      // you are reading should recede rather than compete with it. An opaque
      // black panel hid it instead, which loses the sense of where you are.
      //
      // Only while it is on screen. A layer left enabled would put the whole
      // window through an offscreen texture for the entire session to buy a
      // blur that shows for a couple of seconds.
      layer.enabled: help.opacity > 0.01
      layer.effect: MultiEffect {
        blurEnabled: true
        blurMax: 40
        // ramped by the overlay's own fade, so it goes soft as the keymap
        // arrives instead of snapping out of focus underneath it
        blur: help.opacity
      }

      // ── tabs ──────────────────────────────────────────────────────
      // Hidden while there is one, because a single tab is just the window and
      // a strip saying so is a strip of nothing.
      Rectangle {
        id: tabStrip
        width: parent.width
        // the path bar's height, so the two strips stack as one band of chrome
        // rather than two of slightly different depths
        height: root.tabs.length > 1 ? root.headH : 0
        visible: height > 0
        clip: true
        // The path bar's own colour. Leaving the strip transparent removed the
        // 1px separator but not the LINE: the transparent strip showed the
        // window's ground (layerBg) while the bar below was headBg, and two
        // different colours meeting across the full width is a line whether or
        // not anyone drew one. With the strip painted the same as the bar, the
        // active tab is simply the strip showing through and the boundary
        // disappears; the inactive ones darken instead.
        color: Zenon.headBg

        // The strip spans the window and the tabs divide it, the way a browser
        // does it: a tab's position stops moving every time a directory with a
        // longer name is opened in one of them.
        Row {
          anchors.fill: parent
          anchors.bottomMargin: 1

          Repeater {
            model: root.tabs

            delegate: Rectangle {
              required property var modelData
              required property int index
              readonly property bool here: index === root.tab
              width: tabStrip.width / Math.max(1, root.tabs.length)
              height: parent.height
              // The active tab paints nothing — it is the strip, which is the
              // bar — so it runs into the path bar with no seam at all. The
              // inactive ones are shaded back, which is what separates them.
              color: here ? "transparent" : Qt.rgba(0, 0, 0, 0.28)

              Rectangle {
                anchors.right: parent.right
                width: 1
                height: parent.height
                visible: index < root.tabs.length - 1
                color: Zenon.msgBorder
              }

              Text {
                id: tabLabel
                anchors.centerIn: parent
                width: parent.width - 16
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
                text: Janus.basename(here ? root.cwd : modelData.cwd)
                color: here ? Zenon.white : Zenon.muted
                font.family: "JetBrainsMono Nerd Font Propo"
                // the body's row size, written the same way rather than as a
                // number that happens to match — zoom then moves both together
                font.pixelSize: Math.round(18 * root.zoom)
              }

              HoverHandler { id: tabHov }
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                cursorShape: Qt.PointingHandCursor
                onClicked: (m) => {
                  if (m.button === Qt.MiddleButton) {
                    root.switchTab(index);
                    root.closeTab();
                  } else root.switchTab(index);
                }
              }
            }
          }
        }

      }

      // ── the crumbs ────────────────────────────────────────────────
      Rectangle {
        id: crumbBar
        width: parent.width
        height: root.headH
        color: Zenon.headBg

        // the sidebar's switch, where the path begins — it is about what is to
        // the LEFT of the path, so it sits to the left of it
        Item {
          id: sideToggle
          anchors.left: parent.left
          anchors.leftMargin: 8
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: 1
          width: 34
          height: parent.height

          Text {
            anchors.centerIn: parent
            // Written as an escape, not as the character. Every literal nerd
            // glyph in this batch arrived empty — they do not survive the trip
            // through a shell heredoc — and an empty string renders as nothing
            // at all, which is exactly what the toggle did.
            text: "\uEC02"
            color: root.sidebar ? Zenon.cyan
              : (sideHov.hovered ? Zenon.white : Zenon.muted)
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 17
          }

          HoverHandler { id: sideHov }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.sidebar = !root.sidebar
          }
        }

        Row {
          anchors.left: sideToggle.right
          anchors.leftMargin: 4
          anchors.right: filterInline.left
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: 1
          spacing: 0
          clip: true

          Repeater {
            model: root.crumbList

            delegate: Row {
              required property var modelData
              required property int index

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: index > 1
                text: " › "
                color: Zenon.muted
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 13
              }

              Text {
                id: crumbLabel
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                // the last crumb is where you are; the rest are somewhere to go
                color: index === root.crumbList.length - 1
                  ? Zenon.white : (crumbMa.containsMouse ? Zenon.cyan : Zenon.muted)
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: Font.Medium
                font.pixelSize: 14

                MouseArea {
                  id: crumbMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.goTo(modelData.path)
                }
              }
            }
          }
        }


        // ── the filter, inline ──────────────────────────────────────
        // No card, no overlay. `/` or f puts the keyboard here and the list
        // narrows as you type; the query lives in the path bar beside the
        // counts, because that is where everything else about the current view
        // is already written. The field is only as wide as what is in it, so
        // an empty filter takes no room at all.
        Row {
          id: filterInline
          anchors.right: crumbStatus.left
          anchors.rightMargin: root.query !== "" || filterField.activeFocus ? 14 : 0
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: 1
          spacing: 6
          visible: root.query !== "" || filterField.activeFocus

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "\uF002"
            color: Zenon.cyan
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 14
          }

          TextInput {
            id: filterField
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(8, Math.min(260, contentWidth + 2))
            color: Zenon.cyan
            selectionColor: Zenon.cyan
            selectedTextColor: Zenon.black
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 16
            clip: true
            onTextChanged: { root.query = text; root.sel = 0; }
            Keys.onEscapePressed: (e) => {
              e.accepted = true;
              filterField.text = "";
              root.query = "";
              content.forceActiveFocus();
            }
            Keys.onReturnPressed: (e) => {
              e.accepted = true;
              content.forceActiveFocus();
            }
            Keys.onUpPressed: (e) => { e.accepted = true; root.moveSel(-1); }
            Keys.onDownPressed: (e) => { e.accepted = true; root.moveSel(1); }

            // the caret, since a bare TextInput on a bar has no frame to say
            // where the keyboard is
            Rectangle {
              anchors.left: parent.left
              anchors.leftMargin: Math.min(parent.contentWidth + 1, parent.width)
              anchors.verticalCenter: parent.verticalCenter
              width: 2
              height: 16
              color: Zenon.cyan
              visible: filterField.activeFocus
            }
          }
        }

        // What used to be a bar of its own along the bottom. Two full-width
        // strips to carry one line of text each was a strip too many, and the
        // right-hand end of the path bar was empty — so the count, the view
        // and whatever the last action had to say live here now.
        Row {
          id: crumbStatus
          anchors.right: parent.right
          anchors.rightMargin: 14
          // up by the separator's own pixel: it is the bar's bottom EDGE, not
          // part of the inside, and centring across it sat everything low
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: 1
          spacing: 14

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.status !== "" ? root.status
              : (root.pending ? (root.pending.paths.length + " "
                  + (root.pending.op === "copy" ? "copied" : "cut") + " · p to paste") : "")
            color: root.status !== "" ? Zenon.red : Zenon.sand
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 13
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: {
              const n = root.markedCount;
              if (n > 0) return n + " selected";
              const items = root.view.length
                + (root.view.length === 1 ? " item" : " items");
              // in the trash, how much it holds is what you are there to see
              return root.inTrash && root.trashSize !== ""
                ? items + " \u00b7 " + root.trashSize : items;
            }
            color: root.markedCount > 0 ? Zenon.cyan : Zenon.muted
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 13
          }

          // What the zoom is at, for the view you are in — thumbs and the
          // two list layouts scale independently, so one number would be
          // reporting the wrong one half the time. Dimmed at 100% so it reads
          // as "normal" rather than as something you have changed.
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Math.round(root.activeZoom * 100) + "%"
            color: root.activeZoom === 1.0 ? Zenon.muted : Zenon.cyan
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 13
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.searchMode !== ""
              ? (root.searchMode === "grep" ? "grep" : "find") : root.viewMode
            color: root.searchMode !== "" ? Zenon.sand : Zenon.muted
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 13
          }
        }

        Rectangle {
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: 1
          color: Zenon.msgBorder
        }
      }

      // ── column headers ────────────────────────────────────────────
      // Only the list view has columns to name. The miller layout's panes are
      // one column each and the grid has none, so the strip collapses rather
      // than standing there labelling nothing.
      Rectangle {
        id: colHeads
        width: parent.width
        height: root.viewMode === "list" ? 22 : 0
        visible: height > 0
        clip: true
        // TWO grounds, because this strip spans two things.
        //
        // Over the SIDEBAR it continues the sidebar's own tone — painting the
        // header colour the whole way across left a lighter band there that
        // read as a gap between the sidebar and the breadcrumb. Over the
        // listing it is transparent; see headArea.
        color: root.sidebarBg

        // Inset by the sidebar, because the columns name what is in the
        // LISTING and the sidebar is not the listing. Spanning the full width
        // put "NAME" above the bookmarks, labelling a column that is not
        // there — and the label moved out from over the rows it belongs to.
        Rectangle {
          id: headArea
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.right: parent.right
          anchors.left: parent.left
          anchors.leftMargin: side.width
          // The breadcrumb's own ground, which is already translucent —
          // headBg is #66282f36, so sharing it makes the two read as one
          // header AND keeps the glass. Fully transparent was not the same
          // thing: it dropped the strip to the window's ground and put a
          // visible step between the path and the column names.
          color: Zenon.headBg

          Row {
            anchors.fill: parent
            leftPadding: 12
            rightPadding: 12

            ColHead { width: parent.width * 0.54; label: "NAME"; sortKey: "name" }
            ColHead { width: parent.width * 0.18; label: "SIZE"; sortKey: "size"; rightAlign: true }
            ColHead {
              width: parent.width * 0.24
              label: "MODIFIED"
              sortKey: "time"
              rightAlign: true
              // flush, like the times below it
              padRight: 0
            }
          }
        }

        Rectangle {
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.leftMargin: side.width
          anchors.right: parent.right
          height: 1
          color: Zenon.msgBorder
        }
      }

      // ── the body, with the sidebar beside it ──────────────────────
      // The row owns the leftover height; the sidebar and the body divide the
      // width of it. Reading it off bodyBox instead was a loop: bodyBox sizes
      // itself from its parent, and its parent is this.
      Row {
        width: parent.width
        height: parent.height - tabStrip.height - crumbBar.height
          - colHeads.height - portalBar.height

        Rectangle {
          id: side
          width: root.sidebar ? root.sidebarWidth : 0
          height: parent.height
          visible: width > 0
          clip: true
          color: root.sidebarBg
          // Animated when it OPENS and CLOSES, not while it is being dragged:
          // easing every frame of a drag makes the edge lag the pointer, which
          // reads as the window resisting you.
          Behavior on width {
            enabled: !sideGrip.pressed
            NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease }
          }

          Rectangle {
            anchors.right: parent.right
            width: 1
            height: parent.height
            color: sideGrip.pressed || sideGrip.containsMouse
              ? Zenon.cyan : Zenon.msgBorder
          }

          Flickable {
            anchors.fill: parent
            anchors.rightMargin: 1
            contentHeight: sideCol.implicitHeight
            clip: true

            Column {
              id: sideCol
              width: side.width - 1

              // The sidebar's top moves between views, and this makes up the
              // difference. colHeads spans the full width, so in LIST view its
              // 22px strip sits above the sidebar and gives the first heading
              // its breathing room; in grid and columns that strip collapses to
              // nothing and the heading ended up jammed against the breadcrumb.
              // Whatever colHeads is not supplying, this does.
              Item {
                width: 1
                height: Math.max(0, 22 - colHeads.height)
              }

              SideHead { label: "BOOKMARKS"; first: true }

              Repeater {
                model: root.bookmarks

                delegate: SideRow {
                  required property var modelData
                  width: sideCol.width
                  label: Janus.basename(modelData)
                  glyph: "\uF02E"
                  active: modelData === root.cwd
                  onChosen: root.goTo(modelData)
                  // middle click removes it, the same gesture the tabs use
                  onRemoved: root.removeBookmark(modelData)
                }
              }

              Item {
                width: 1
                height: root.bookmarks.length === 0 ? 0 : 8
              }

              SideHead { label: "DISKS"; visible: root.disks.length > 0 }

              Repeater {
                model: root.disks

                delegate: SideRow {
                  required property var modelData
                  width: sideCol.width
                  label: modelData.name !== "" ? modelData.name
                    : Janus.basename(modelData.path)
                  // Free space when it is mounted, total size when it is not.
                  // "412G free" is the number you actually want before copying
                  // to a disk; the capacity only matters when you cannot yet
                  // see inside it. lsblk supplies both, so neither costs a
                  // process.
                  detail: modelData.mount !== "" && modelData.avail !== ""
                    ? modelData.avail + " free" : modelData.size
                  used: Janus.usedFraction(modelData.avail, modelData.fsSize)
                  glyph: modelData.removable ? "\uF0A0" : "\uF1C0"
                  active: modelData.mount !== "" && root.cwd.indexOf(modelData.mount) === 0
                  // a mounted disk is a place; an unmounted one is a button
                  mounted: modelData.mount !== ""
                  // no eject on the mounts the system is standing on
                  showMount: !Janus.isSystemMount(modelData.mount)
                  onChosen: {
                    if (modelData.mount !== "") root.goTo(modelData.mount);
                    else root.mountDisk(modelData);
                  }
                  onToggledMount: root.mountDisk(modelData)
                }
              }
            }
          }
        }

        // The divider, as something you can grab.
        //
        // A sibling of the sidebar rather than a child of it: `side` clips, so
        // a handle inside it could only ever be as wide as the 1px line it sits
        // on. Sitting in the Row between the two would steal width from the
        // body every frame; this takes none, and overlays the seam instead.
        MouseArea {
          id: sideGrip
          width: 9
          height: parent.height
          // z above the body so the cursor changes over the seam even where a
          // row is drawn right up to it
          z: 9
          visible: root.sidebar
          hoverEnabled: true
          cursorShape: Qt.SizeHorCursor
          preventStealing: true
          // straddling the divider, half either side
          x: side.width - 4

          // Where in the grip it was taken hold of, so the seam stays under
          // the same part of the pointer for the whole drag.
          property real grab: 0

          // Measured in the PARENT's coordinates, never in the grip's own.
          //
          // The grip's x follows side.width, so while you drag it slides along
          // underneath the pointer — and a delta taken from `m.x` is measured
          // against an origin that is itself moving. Each frame overshot and
          // the next corrected, which is what made the divider jitter. The
          // parent does not move, so a position mapped into it is stable.
          onPressed: (m) => {
            sideGrip.grab = m.x;
          }
          onPositionChanged: (m) => {
            if (!sideGrip.pressed) return;
            const px = sideGrip.mapToItem(sideGrip.parent, m.x, 0).x;
            root.sidebarWidth = Math.max(root.sidebarMin,
              Math.min(root.sidebarMax, px - sideGrip.grab + 4));
          }
          // Double click springs it back, so a width dragged somewhere silly is
          // one gesture to undo rather than a careful drag back.
          onDoubleClicked: root.sidebarWidth = 200
        }

        Item {
          id: bodyBox
          width: parent.width - side.width
          height: parent.height

        // Ctrl+wheel zooms — see the overlay at the bottom of this Item.
        // It cannot live here: a pointer handler on a parent is only offered
        // an event after every child has declined it, and all three views are
        // Flickables that handle the wheel themselves. So this container's own
        // handler was never reached and the gesture did nothing.

        // ── list ────────────────────────────────────────────────────
        ListView {
          id: list

          anchors.fill: parent
          visible: root.viewMode === "list"
          clip: true
          // Only the view that is ON SCREEN holds delegates. An invisible
          // ListView still builds every one of them, so all three layouts
          // were instantiating the whole directory at once and every change
          // to `view` rebuilt three sets instead of one. That is most of what
          // made the split feel heavier than the grid.
          model: root.viewMode === "list" ? root.view : []
          boundsBehavior: Flickable.StopAtBounds
          reuseItems: true

          delegate: EntryRow {
            required property var modelData
            required property int index
            width: list.width
            entry: modelData
            current: index === root.sel
            ticked: !!root.marked[modelData.path]
            showMeta: true
            onChosen: (right, shift, ctrl) => root.clickRow(index, right, shift, ctrl)
            onOpened: { root.sel = index; root.activate(); }
            onTabbed: if (modelData.isDir) root.openInNewTab(modelData.path)
          }
        }

        // ── columns ─────────────────────────────────────────────────
        // Yazi's miller layout: where you came from, where you are, and what
        // you are about to open. The point is that moving the cursor changes
        // the right-hand pane rather than the whole window, so you can look
        // into a directory without entering it.
        Row {
          id: miller
          anchors.fill: parent
          visible: root.viewMode === "columns"

          ListView {
            id: parentList
            width: Math.round(parent.width * 0.24)
            height: parent.height
            clip: true
            model: root.viewMode === "columns" ? root.parentRows : []
            // recycled, like the grid's tiles: the model is replaced whenever
            // the directory is re-read, and rebuilding every row for that is
            // the redraw you can see
            reuseItems: true
            boundsBehavior: Flickable.StopAtBounds

            delegate: EntryRow {
              required property var modelData
              required property int index
              width: parentList.width
              entry: modelData
              // the directory we are standing in, marked in its own parent
              current: index === root.parentIndex
              showMeta: false
              onChosen: if (modelData.isDir) root.goTo(modelData.path)
              onOpened: if (modelData.isDir) root.goTo(modelData.path)
              onTabbed: if (modelData.isDir) root.openInNewTab(modelData.path)
            }
          }

          Rectangle { width: 1; height: parent.height; color: Zenon.msgBorder }

          ListView {
            id: midList

            width: Math.round(parent.width * 0.34)
            height: parent.height
            clip: true
            model: root.viewMode === "columns" ? root.view : []
            reuseItems: true
            boundsBehavior: Flickable.StopAtBounds

            delegate: EntryRow {
              required property var modelData
              required property int index
              width: midList.width
              entry: modelData
              current: index === root.sel
              ticked: !!root.marked[modelData.path]
              showMeta: false
              onChosen: (right, shift, ctrl) => root.clickRow(index, right, shift, ctrl)
              onOpened: { root.sel = index; root.activate(); }
              onTabbed: if (modelData.isDir) root.openInNewTab(modelData.path)
            }
          }

          Rectangle { width: 1; height: parent.height; color: Zenon.msgBorder }

          Item {
            id: previewPane
            width: miller.width - parentList.width - midList.width - 2
            height: parent.height
            clip: true

            // a directory: what is inside it, inert. Clicking here would mean
            // acting on a row that is not the cursor, which is a way to move
            // the wrong file.
            ListView {
              anchors.fill: parent
              visible: root.previewKind === "dir"
              model: root.previewRows
              reuseItems: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: false

              // Clickable, because the pane is showing you a directory you are
              // about to enter and clicking a thing you can see should get you
              // there. It enters the PREVIEWED directory rather than acting on
              // the row, so a click here can never move the wrong file.
              delegate: EntryRow {
                required property var modelData
                width: previewPane.width
                entry: modelData
                showMeta: false
                  onChosen: {
                  const r = root.currentRow();
                  if (r && r.isDir) root.goTo(r.path);
                }
                onOpened: {
                  const r = root.currentRow();
                  if (r && r.isDir) root.goTo(r.path);
                }
                onTabbed: {
                  const r = root.currentRow();
                  if (r && r.isDir) root.openInNewTab(r.path);
                }
              }
            }

            Image {
              anchors.fill: parent
              anchors.margins: 12
              visible: root.previewKind === "video"
              source: {
                const r = root.currentRow();
                if (!r || root.previewKind !== "video") return "";
                return root.thumbReady[r.path]
                  ? "file://" + Janus.thumbPath(r.path, r.mtime) : "";
              }
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              sourceSize.width: 600
              sourceSize.height: 600
            }

            Image {
              anchors.fill: parent
              anchors.margins: 12
              visible: root.previewKind === "image"
              // The row is re-checked here, not just previewKind. Moving the
              // cursor changes the row a frame before loadPreview has decided
              // what the new one is, so for that frame this binding asked for
              // a DIRECTORY as an image and Qt logged "Cannot open:
              // file:///home/buck/Desktop" every time the cursor passed one.
              source: {
                const r = root.currentRow();
                if (!r || r.isDir || !Janus.isImage(r.name)) return "";
                return root.previewKind === "image" ? "file://" + r.path : "";
              }
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              // capped rather than full-size: a 6000px wallpaper decoded at
              // native resolution to fill a 300px pane is most of a second
              // and a lot of memory for a picture nobody is looking at yet
              sourceSize.width: 900
              sourceSize.height: 900
            }

            Text {
              anchors.fill: parent
              anchors.margins: 12
              visible: root.previewKind === "text" || root.previewKind === "archive"
              text: root.previewText
              // RichText, because bat's colours arrive as ANSI and are
              // translated rather than thrown away — that is the syntax
              // highlighting, and markdown comes through the same path
              textFormat: Text.RichText
              color: Zenon.white
              wrapMode: Text.NoWrap
              elide: Text.ElideRight
              clip: true
              font.family: "JetBrainsMono Nerd Font Mono"
              font.pixelSize: Math.round(14 * root.zoom)
            }

            Image {
              anchors.fill: parent
              anchors.margins: 12
              visible: root.previewKind === "pdf"
              source: root.previewKind === "pdf" && root.previewStamp > 0
                ? "file://" + root.pdfStem + ".png?v=" + root.previewStamp : ""
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              cache: false
              sourceSize.width: 900
              sourceSize.height: 1200
            }

            Text {
              anchors.centerIn: parent
              visible: root.previewKind === "binary" || root.previewKind === "none"
              text: root.previewKind === "binary" ? "binary" : ""
              color: Zenon.muted
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 12
            }
          }
        }

        // ── grid ────────────────────────────────────────────────────
        // Qt decodes the picture itself. There is no thumbnail cache and no
        // thumbnailer process behind this: sourceSize makes the loader scale
        // while decoding, so what lands in memory is already tile-sized, and
        // asynchronous keeps that off the render thread.
        GridView {
          id: grid

          anchors.fill: parent
          visible: root.viewMode === "grid"
          clip: true
          model: root.viewMode === "grid" ? root.view : []
          boundsBehavior: Flickable.StopAtBounds
          // Recycled, like the list's rows. A tile holds an Image, and
          // building a fresh one per tile while scrolling a folder of pictures
          // is the most expensive thing this window does.
          reuseItems: true
          // A target width rather than a fixed one: the cells divide the pane
          // exactly, so there is never a ragged strip of dead space down the
          // right-hand edge, and they land near enough to the target that a
          // thumbnail is worth looking at. 132px tiles on a 2550px window came
          // out as nineteen columns of stamps.
          readonly property int targetCell: Math.round(190 * root.thumbZoom)
          cellWidth: Math.floor(grid.width
            / Math.max(1, Math.round(grid.width / grid.targetCell)))
          cellHeight: Math.round(168 * root.thumbZoom)

          delegate: Item {
            id: tile
            required property var modelData
            required property int index
            width: grid.cellWidth
            height: grid.cellHeight

            readonly property bool current: tile.index === root.sel
            readonly property bool ticked: !!root.marked[modelData.path]

            // see EntryRow.cursorOnly — same rule, same reason
            readonly property bool cursorOnly:
              tile.current && !tile.ticked && root.markedCount > 0

            Rectangle {
              anchors.fill: parent
              anchors.margins: 4
              radius: 6
              color: tile.cursorOnly ? "transparent"
                : (tile.current ? Zenon.selBg
                  : (tile.ticked ? Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.10)
                    : "transparent"))
              border.width: tile.current ? 1 : 0
              // A tile has always carried a border, so the cursor keeps one
              // either way — it just stops being cyan, which is the colour
              // this window uses to mean "selected", and becomes the neutral
              // outline that only means "here".
              border.color: tile.cursorOnly ? Zenon.msgBorder : Zenon.cyan
            }
            HoverHandler {
              id: tileHov
              onHoveredChanged: {
                if (hovered) root.hoverRow = true;
                else if (root.hoverRow) root.hoverRow = false;
              }
            }

            Item {
              id: thumbBox
              anchors.top: parent.top
              anchors.topMargin: 12
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width - 24
              height: parent.height - 62

              Image {
                id: thumb
                anchors.fill: parent
                visible: status === Image.Ready
                // the cached 256px PNG if the batch has made it, the original
                // otherwise — so a folder is never blank while it renders, it
                // just gets cheaper a moment later
                // A video has no thumbnail until ffmpeg has pulled a frame
                // out of it, so unlike a picture there is nothing to fall back
                // to — it shows its glyph until the batch lands.
                // Zoomed past the cache, a PICTURE goes back to the original.
                //
                // The cached thumbnails are 256px, which is generous at the
                // default tile size and not enough at the top of the zoom
                // range — a 456px tile showing a 256px PNG is visibly soft,
                // and zooming in is precisely when you are looking closely. So
                // above the cache's own resolution the original file is decoded
                // instead, at the size actually needed. A VIDEO has no such
                // fallback: its thumbnail is a frame ffmpeg had to pull out of
                // it, so it keeps the cached one at any zoom.
                readonly property bool big: thumbBox.width > 256
                source: {
                  const vid = Janus.isVideo(modelData.name);
                  if (!vid && !Janus.isImage(modelData.name)) return "";
                  const ready = root.thumbReady[modelData.path];
                  if (ready && !(thumb.big && !vid))
                    return "file://" + Janus.thumbPath(modelData.path, modelData.mtime);
                  return vid ? "" : "file://" + modelData.path;
                }
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                // Decode at the size drawn, not at a fixed 320: below that it
                // was decoding more than it showed, above it, less.
                sourceSize.width: Math.max(320, Math.round(thumbBox.width))
                sourceSize.height: Math.max(320, Math.round(thumbBox.height))
              }

              // the glyph is the fallback AND the placeholder: it is what a
              // non-image shows, and what an image shows until it has decoded
              Text {
                anchors.centerIn: parent
                visible: thumb.status !== Image.Ready
                text: modelData.glyph
                color: root.inkFor(modelData)
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: Math.round(40 * root.thumbZoom)
              }
            }

            Text {
              anchors.top: thumbBox.bottom
              anchors.topMargin: 8
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.margins: 8
              horizontalAlignment: Text.AlignHCenter
              text: modelData.name
              elide: Text.ElideMiddle
              maximumLineCount: 2
              wrapMode: Text.Wrap
              color: root.inkFor(modelData)
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: tile.current ? Font.Bold : Font.Medium
              // NOT scaled by zoom, unlike the tile and the glyph above it.
              // Zoom in a thumbnail view is about how big the PICTURES are;
              // scaling the filenames with them meant zooming out to fit more
              // on screen also shrank the labels towards unreadable, and
              // zooming in to inspect an image blew its name up to a headline.
              // The 62px the tile reserves for this text is a constant too, so
              // two lines always fit at every zoom.
              font.pixelSize: 15
            }

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              cursorShape: Qt.PointingHandCursor
              onClicked: (m) => {
                const right = m.button === Qt.RightButton;
                root.clickRow(tile.index, right,
                              (m.modifiers & Qt.ShiftModifier) !== 0,
                              (m.modifiers & Qt.ControlModifier) !== 0);
                if (right) menu.openAt(tile, m);
              }
              onDoubleClicked: { root.sel = tile.index; root.activate(); }
            }
          }
        }

        // One rail per view that scrolls, each riding its own flickable. They
        // are declared here, after the views, so they draw over the tiles
        // rather than under them.
        ScrollRail {
          target: grid
          on: root.viewMode === "grid"
          anchors.right: grid.right
          anchors.rightMargin: 2
          anchors.top: grid.top
          anchors.topMargin: 2
          anchors.bottom: grid.bottom
          anchors.bottomMargin: 2
        }

        ScrollRail {
          target: list
          on: root.viewMode === "list"
          anchors.right: list.right
          anchors.rightMargin: 2
          anchors.top: list.top
          anchors.topMargin: 2
          anchors.bottom: list.bottom
          anchors.bottomMargin: 2
        }

        // In miller columns only the FOCUSED column gets one. The parent
        // column is context you glance at, and a second bar beside it would
        // be two scrollbars for one cursor.
        //
        // Positioned rather than anchored to its target: midList is a child of
        // the `miller` Row, so a rail anchored to it would have to live in that
        // Row too — and a Row lays its children out side by side, so the bar
        // would take a slice of width from the columns instead of floating over
        // the one it belongs to. `miller` fills this parent, so midList's own x
        // is already the offset needed here.
        ScrollRail {
          target: midList
          on: root.viewMode === "columns"
          anchors.top: miller.top
          anchors.topMargin: 2
          anchors.bottom: miller.bottom
          anchors.bottomMargin: 2
          x: midList.x + midList.width - width - 2
        }

        // ── dropping onto this directory ────────────────────────────
        // ONE DropArea, and that is the fix.
        //
        // There were two, stacked on the same rectangle with the same keys: the
        // real one, and a second declared later that existed only to light up
        // the border. Later means on top, and the top DropArea is the one Qt
        // delivers to — so every drop landed on the decorative one, which had
        // no onDropped and quietly dropped it on the floor. Dragging a file
        // from scout into janus did nothing for exactly this reason.
        //
        // No `keys` filter either. Keys are matched against the SOURCE's
        // Drag.keys, which an application outside quickshell has no reason to
        // set — the honest test is whether what arrived carries file URLs, and
        // dropUris already checks that and ignores anything else.
        //
        // The high z keeps it above the click and wheel overlays.
        DropArea {
          id: dropHint
          anchors.fill: parent
          z: 7
          onDropped: (d) => root.dropUris(d.urls, d.proposedAction)
        }

        Rectangle {
          anchors.fill: parent
          visible: dropHint.containsDrag
          color: Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.07)
          border.width: 2
          border.color: Zenon.cyan
          z: 8
        }

        // ── the drag box ────────────────────────────────────────────
        // A DragHandler, not a MouseArea. Every row already has a MouseArea
        // for its click, and a MouseArea laid over them would either swallow
        // those clicks or never see the press; a pointer handler can sit above
        // the lot and only TAKE the grab once the pointer has actually moved,
        // which is exactly the difference between a click and a drag.
        DragHandler {
          id: band
          target: null
          acceptedButtons: Qt.LeftButton
          // Off while the pointer is on an item, because then a drag is that
          // item being dragged. Anywhere else — the gap under the last row, the
          // empty half of a grid — the band is what a drag means, and it has to
          // outrank the ListView's own flick to get the gesture.
          //
          // `band.active ||` is what makes it survive the drag. hoverRow is a
          // live property, so the moment the pointer crossed onto a tile this
          // went false and the handler was disabled mid-gesture — in the grid
          // that is the very first row, which is why the box could not be
          // dragged past it. Once the band has the grab it keeps it.
          enabled: band.active || !root.hoverRow
          grabPermissions: PointerHandler.CanTakeOverFromAnything

          // Clamped to the body. bodyBox does not clip, so a drag carried past
          // its left edge drew the selection box out over the sidebar — the
          // rectangle was honest about the pointer and wrong about what it was
          // selecting from, since there is nothing selectable over there.
          readonly property real x1: Math.max(0,
            Math.min(centroid.pressPosition.x, centroid.position.x))
          readonly property real y1: Math.max(0,
            Math.min(centroid.pressPosition.y, centroid.position.y))
          readonly property real x2: Math.min(bodyBox.width,
            Math.max(centroid.pressPosition.x, centroid.position.x))
          readonly property real y2: Math.min(bodyBox.height,
            Math.max(centroid.pressPosition.y, centroid.position.y))

          // What was already ticked when the drag began, so dragging ADDS to a
          // selection instead of replacing it — and so releasing without
          // having moved cannot wipe what you had.
          property var base: ({})

          // The rectangle as last drawn. Kept because the centroid collapses
          // the instant the button comes up, and the box has to still have a
          // shape to fade out from.
          property rect held: Qt.rect(0, 0, 0, 0)

          onActiveChanged: {
            if (active) {
              band.base = Object.assign({}, root.marked);
              band.lastLo = -1;
              band.lastHi = -1;
            }
            // nothing to apply on release: the last centroid already did, and
            // the collapsed one would select a single row
          }
          // The last row range applied, so a move that stays inside the same
          // rows does not rebuild the selection. Dragging across a tall list
                    // fires a centroid change per pixel and only a fraction of
          // them cross a row boundary.
          property int lastLo: -1
          property int lastHi: -1

          onCentroidChanged: {
            if (!band.active) return;
            // (see the TapHandler below for the click, as opposed to the drag)
            const w = band.x2 - band.x1, h = band.y2 - band.y1;
            // Only remember a rectangle with a shape. On release the centroid
            // collapses to a point while `active` is still true for one more
            // event, and letting that through overwrote the held rect with a
            // 0x0 one — so the fade ran on something invisible, which looked
            // exactly like no fade at all.
            if (w > 2 && h > 2)
              band.held = Qt.rect(band.x1, band.y1, w, h);
            root.applyBand(band.x1, band.y1, band.x2, band.y2, band.base);
          }
        }

        Rectangle {
          // Drawn from the HELD rectangle, not the live centroid, so releasing
          // leaves it where it was and it fades from there rather than
          // collapsing to a point on the way out.
          visible: opacity > 0.01
          opacity: band.active ? 1 : 0
          // Slower on the way out than a normal transition: the box is being
          // dismissed rather than moved, and a 140ms disappearance reads as a
          // cut rather than a fade.
          Behavior on opacity {
            NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
          }
          x: band.held.x
          y: band.held.y
          width: band.held.width
          height: band.held.height
          radius: 5
          color: Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.12)
          border.width: 1
          border.color: Zenon.cyan
          z: 5
        }

        // Ctrl+wheel zooms.
        //
        // A MouseArea, not a WheelHandler, and that is not a preference: a
        // WheelHandler receives NOTHING here. Verified with a logging handler
        // placed inside the very ListView those same wheel events were visibly
        // scrolling, and again on an overlay above all three views — zero
        // events in both, while a console.log elsewhere in this file logged
        // fine. MouseArea.onWheel does get them.
        //
        // NoButton is what makes it safe to lay over everything: it never takes
        // a press, so clicks, drags and the rubber band are untouched. A wheel
        // without ctrl is declined and falls through to the view underneath,
        // which goes on scrolling exactly as before.
        MouseArea {
          anchors.fill: parent
          z: 6
          acceptedButtons: Qt.NoButton
          onWheel: (w) => {
            if (!(w.modifiers & Qt.ControlModifier)) { w.accepted = false; return; }
            w.accepted = true;
            root.zoomBy(w.angleDelta.y > 0 ? 0.1 : -0.1);
          }
        }

        // Whether the pointer is over empty space, tracked by something that
        // can never steal a press.
        //
        // A HoverHandler only ever handles hover, so unlike a MouseArea it
        // cannot take the press that a row's DragHandler needs — and taking
        // that press is exactly what the overlay below was doing, which is why
        // dragging a file out of janus produced no drag at all. Declining the
        // press with `accepted = false` was not enough: by then the overlay had
        // already won the gesture.
        //
        // It asks the view's own indexAt rather than reading hoverRow, for the
        // reason rowUnder exists.
        HoverHandler {
          id: emptyWatch
          onPointChanged: root.overEmpty =
            root.rowUnder(emptyWatch.point.position.x, emptyWatch.point.position.y) < 0
        }

        // A click on nothing: right opens the menu, left means "none of them".
        //
        // ABOVE the views, not below them, and that one word was the whole bug.
        // At z:-1 this sat underneath three Flickables, and a Flickable takes
        // the left button for its own flick and never gives it back — so the
        // deselect could not fire. RIGHT clicks did arrive, because a Flickable
        // ignores those, which is why the paste-here menu worked all along and
        // hid the fact that its other half never did.
        //
        // Two things stop it swallowing what it should not: `enabled` turns it
        // off whenever the pointer is on a row, so rows get their own clicks;
        // and the rubber band is a DragHandler declaring CanTakeOverFromAnything,
        // so it still steals the press the moment a click becomes a drag.
        MouseArea {
          anchors.fill: parent
          z: 5
          // Not present at all over a row, so a row keeps every press it is
          // entitled to — including the one that becomes a drag out of janus.
          enabled: root.overEmpty
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: (m) => {
            if (m.button === Qt.RightButton) { menu.openHere(bodyBox, m); return; }
            if (Object.keys(root.marked).length > 0) root.marked = {};
            content.forceActiveFocus();
          }
        }

        Text {
          anchors.centerIn: parent
          visible: root.view.length === 0
          text: root.query !== "" ? "No matches" : "Empty"
          color: Zenon.muted
          font.family: "JetBrainsMono Nerd Font Propo"
          font.weight: Font.Bold
          font.pixelSize: 14
        }
        }
      }


      // ── the picker's own footer ───────────────────────────────────
      // Only while a portal request is open. It is deliberately the widest
      // thing on screen and sits directly above the hints: an application is
      // blocked waiting on this, so what janus is being asked for has to be
      // impossible to miss.
      Rectangle {
        id: portalBar
        width: parent.width
        height: root.picking ? 44 : 0
        visible: height > 0
        clip: true
        color: Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.10)

        Rectangle {
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: 1
          color: Zenon.cyan
        }

        Text {
          id: portalLabel
          anchors.left: parent.left
          anchors.leftMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          text: root.portalTitle
          color: Zenon.cyan
          font.family: "JetBrainsMono Nerd Font Propo"
          font.weight: Font.Bold
          font.pixelSize: 14
        }

        // save requests need a name, and it is the only thing being chosen
        Rectangle {
          id: saveBox
          anchors.left: portalLabel.right
          anchors.leftMargin: 14
          anchors.right: portalButtons.left
          anchors.rightMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          height: 26
          radius: 4
          visible: !!root.portal && root.portal.save
          color: Zenon.selBg
          border.width: 1
          border.color: Janus.nameError(saveField.text) === ""
            ? Zenon.msgBorder : Zenon.red

          TextInput {
            id: saveField
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            color: Zenon.white
            selectionColor: Zenon.cyan
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 13
            clip: true
            Keys.onReturnPressed: (e) => { e.accepted = true; root.portalConfirm(); }
            Keys.onEscapePressed: (e) => { e.accepted = true; root.portalCancel(); }
          }
        }

        // what a confirm would actually hand over, spelled out, because the
        // difference between "this folder" and "the folder under the cursor"
        // is invisible otherwise
        Text {
          anchors.left: portalLabel.right
          anchors.leftMargin: 14
          anchors.right: portalButtons.left
          anchors.rightMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          visible: !!root.portal && !root.portal.save
          elide: Text.ElideMiddle
          text: {
            const c = root.portalChoice;
            if (c.length === 0) return "nothing selected";
            if (c.length === 1) return c[0];
            return c.length + " selected";
          }
          color: root.portalChoice.length === 0 ? Zenon.muted : Zenon.white
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 12
        }

        Row {
          id: portalButtons
          anchors.right: parent.right
          anchors.rightMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8

          Rectangle {
            width: 90; height: 26; radius: 4
            color: cancelHov.hovered ? Zenon.hoverTint : "transparent"
            border.width: 1
            border.color: Zenon.msgBorder
            Text {
              anchors.centerIn: parent
              text: "Cancel"
              color: Zenon.muted
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 12
            }
            HoverHandler { id: cancelHov }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.portalCancel()
            }
          }

          Rectangle {
            width: 110; height: 26; radius: 4
            readonly property bool ready: root.portalChoice.length > 0
            color: parent.parent && okHov.hovered && ready
              ? Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.25)
              : "transparent"
            border.width: 1
            border.color: ready ? Zenon.cyan : Zenon.msgBorder
            Text {
              anchors.centerIn: parent
              text: (!!root.portal && root.portal.save) ? "Save" : "Choose"
              color: parent.ready ? Zenon.cyan : Zenon.muted
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 12
            }
            HoverHandler { id: okHov }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.portalConfirm()
            }
          }
        }
      }

    }

    // ── properties ────────────────────────────────────────────────────
    // What the listing cannot fit: the whole path, the owner, the exact byte
    // count, and for a selection the total. `stat` is asked once for the set,
    // the same way the search results are — one process, not one per file.
    Rectangle {
      id: props
      anchors.fill: parent
      z: 13
      visible: opacity > 0.01
      opacity: props.open ? 1 : 0
      color: Qt.rgba(0, 0, 0, 0.55)
      Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

      property bool open: false
      property var rows: []
      property string owner: ""
      // -1 while du is still walking, so the row can say so rather than
      // showing a zero that looks like an answer
      property real walked: -1
      // "" = never asked, "…" = running, otherwise the digest or an error
      property string checksum: ""
      // dimensions and format, for an image; null for anything else
      property var imageInfo: null

      readonly property bool many: props.rows.length > 1
      readonly property int total: {
        let n = 0;
        for (const r of props.rows) if (!r.isDir) n += r.size;
        return n;
      }

      function ask() {
        const sel = root.acting();
        if (sel.length === 0) return;
        props.rows = sel;
        props.owner = "";
        props.walked = -1;
        props.open = true;
        // only when there is a directory in the set: for plain files the size
        // is already known and du would be a process for nothing
        if (sel.some((r) => r.isDir)) {
          sizeProc.command = ["sh", "-c",
            Janus.sizeCommand(sel.map((r) => r.path))];
          sizeProc.running = true;
        }
        ownerProc.command = ["sh", "-c",
          "stat -c '%U:%G' -- " + Strings.shellQuote(sel[0].path) + " 2>/dev/null"];
        ownerProc.running = true;

        // Dimensions come for free — identify reads a header, not a file — so
        // an image simply has them. A CHECKSUM does not: sha256 over a few
        // gigabytes takes real time, so it is a button, and only the digest you
        // asked for is ever computed.
        props.checksum = "";
        props.imageInfo = null;
        if (!props.many && !sel[0].isDir && Janus.isImage(sel[0].name)) {
          imageProc.command = ["sh", "-c", Janus.imageInfoCommand(sel[0].path)];
          imageProc.running = true;
        }
      }

      function computeChecksum() {
        const r = props.rows[0];
        if (!r || r.isDir || sumProc.running) return;
        props.checksum = "\u2026";
        sumProc.command = ["sh", "-c", Janus.checksumCommand(r.path)];
        sumProc.running = true;
      }

      MouseArea {
        anchors.fill: parent
        onClicked: { props.open = false; content.forceActiveFocus(); }
      }

      ClippingRectangle {
        anchors.centerIn: parent
        width: Math.min(560, parent.width - 80)
        height: propsCol.implicitHeight
        color: Zenon.black
        border.color: Zenon.surface
        border.width: 1
        radius: 10
        transform: Translate { y: (1 - props.opacity) * 10 }

        Column {
          id: propsCol
          width: parent.width

          Rectangle {
            width: parent.width
            height: 34
            color: Zenon.cyan
            Text {
              anchors.centerIn: parent
              text: props.many ? props.rows.length + " items" : "Properties"
              color: Zenon.black
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 16
            }
          }

          Item { width: 1; height: 8 }

          Repeater {
            model: {
              const r = props.rows[0];
              if (!r) return [];
              if (props.many) {
                let dirs = 0;
                for (const x of props.rows) if (x.isDir) dirs++;
                return [
                  ["items", props.rows.length + " (" + dirs + " folders)"],
                  ["total size", props.walked < 0
                    ? (dirs > 0 ? "measuring\u2026"
                        : Janus.formatSize(props.total) + "  ·  " + props.total + " bytes")
                    : Janus.formatSize(props.walked) + "  ·  " + props.walked + " bytes"],
                  ["location", Janus.dirname(r.path)]
                ];
              }
              return [
                ["name", r.name],
                ["location", Janus.dirname(r.path)],
                ["type", r.isDir ? "folder"
                  : (r.isLink ? "symbolic link"
                    : (Janus.categoryOf(r.name) || (r.isExec ? "executable" : "file")))],
                ["size", r.isDir
                  ? (props.walked < 0 ? "measuring\u2026"
                      : Janus.formatSize(props.walked) + "  ·  " + props.walked + " bytes")
                  : Janus.formatSize(r.size) + "  ·  " + r.size + " bytes"],
                ["modified", Janus.formatTime(r.mtime)],
                ["owner", props.owner === "" ? "…" : props.owner],
                ["permissions", ("000" + (r.mode & 511).toString(8)).slice(-3)
                  + "  " + Janus.modeString(r.mode)]
              ].concat(
                props.imageInfo
                  ? [["image", props.imageInfo.dims + "  \u00b7  "
                      + props.imageInfo.format + "  \u00b7  "
                      + props.imageInfo.depth + "  \u00b7  "
                      + props.imageInfo.colorspace]]
                  : [],
                r.isDir ? []
                  : [["sha256", props.checksum === "" ? "click to compute"
                      : props.checksum]]);
            }

            delegate: Row {
              required property var modelData
              width: propsCol.width
              height: 28
              leftPadding: 18
              rightPadding: 18
              spacing: 12

              Text {
                width: 118
                height: parent.height
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
                text: modelData[0]
                color: Zenon.muted
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 15
              }

              Text {
                id: propValue
                width: propsCol.width - 118 - 48
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: modelData[1]
                elide: Text.ElideMiddle
                // The one row you can act on says so by looking like a link
                // until it has an answer.
                readonly property bool askable:
                  modelData[0] === "sha256" && props.checksum === ""
                color: propValue.askable
                  ? (sumHov.hovered ? Zenon.cyan : Zenon.keyInk) : Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 15

                HoverHandler { id: sumHov; enabled: propValue.askable }

                MouseArea {
                  anchors.fill: parent
                  enabled: propValue.askable
                  cursorShape: Qt.PointingHandCursor
                  onClicked: props.computeChecksum()
                }
              }
            }
          }

          Item { width: 1; height: 8 }

          Rectangle {
            width: parent.width
            height: 30
            color: closeHov.hovered ? Zenon.hoverTint : "transparent"

            Rectangle {
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: Zenon.msgBorder
            }

            Text {
              anchors.centerIn: parent
              text: "Close"
              color: Zenon.muted
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 15
            }

            HoverHandler { id: closeHov }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: { props.open = false; content.forceActiveFocus(); }
            }
          }
        }
      }
    }

    // ── a transfer, in the corner ─────────────────────────────────────
    Rectangle {
      id: jobPanel
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: 14
      z: 9
      width: 300
      height: 62
      radius: 8
      visible: opacity > 0.01
      opacity: root.job !== null ? 1 : 0
      color: Zenon.black
      border.width: 1
      border.color: Zenon.surface
      Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

      Text {
        id: jobLabel
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.top: parent.top
        anchors.topMargin: 10
        text: {
          if (!root.job) return "";
          const n = root.job.names.length;
          const what = n === 1 ? root.job.names[0] : n + " items";
          const verb = root.job.op === "copy" ? "Copying " : "Moving ";
          // "3/7" only when the job actually goes item by item; the single
          // rsync modes report one true percentage across the whole set, and a
          // counter beside that would be two different progresses at once.
          const at = root.job.index > 0
            ? "  " + root.job.index + "/" + root.job.total : "";
          const q = root.jobQueue.length > 0
            ? "  (+" + root.jobQueue.length + " queued)" : "";
          return verb + what + at + q;
        }
        elide: Text.ElideMiddle
        width: parent.width - 96
        color: Zenon.white
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: 14
      }

      Text {
        id: jobPct
        anchors.right: jobStop.left
        anchors.rightMargin: 8
        anchors.verticalCenter: jobLabel.verticalCenter
        text: root.job ? root.job.pct + "%" : ""
        color: Zenon.cyan
        font.family: "JetBrainsMono Nerd Font Propo"
        font.weight: Font.Bold
        font.pixelSize: 14
      }

      // Stopping it has to be possible from here. A panel that reports a
      // percentage and offers no way out is a progress bar you have to wait
      // for whatever it turns out to be doing — a mistyped destination, a
      // directory far bigger than you thought.
      Item {
        id: jobStop
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: jobLabel.verticalCenter
        width: 20
        height: 20

        Text {
          anchors.centerIn: parent
          text: ""   // nf-fa-times
          color: stopHov.hovered ? Zenon.red : Zenon.muted
          font.family: "JetBrainsMono Nerd Font Mono"
          font.pixelSize: 14
        }

        HoverHandler { id: stopHov }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.cancelJob()
        }
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 12
        height: 6
        radius: 3
        color: Zenon.trough(Zenon.cyan)

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: parent.width * (root.job ? root.job.pct / 100 : 0)
          radius: 3
          color: Zenon.cyan
          Behavior on width { NumberAnimation { duration: 300; easing.type: Zenon.ease } }
        }
      }
    }

    // ── what the prefix key is waiting for ────────────────────────────
    // Yazi shows the continuations of a half-typed sequence along the bottom,
    // which is the difference between a sequence you remember and one you
    // have to look up. Same list, same place. It appears with the prefix and
    // goes the moment the next key lands or the timeout gives up.
    Rectangle {
      id: which
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: content.pending === "" ? 0 : whichFlow.implicitHeight + 16
      // one line, so the bar is a fixed depth whichever prefix is pending
      visible: height > 0
      clip: true
      z: 7
      color: Zenon.black
      Behavior on height { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

      Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Zenon.surface
      }

      readonly property var entries:
        content.pending === "" ? [] : (content.sequences[content.pending] || [])

      // A Row, not a Flow: one line, centred, always. A Flow wrapped the
      // longer sets onto a second line and grew the bar, which turned a
      // glanceable strip into a block — and a Flow cannot centre its wrapped
      // lines anyway, so the wrapping was never going to look right. A set
      // wider than the window is clipped evenly at both ends instead, which
      // only happens at sizes where nothing would have fitted regardless.
      Row {
        id: whichFlow
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 9
        spacing: 16

        Repeater {
          model: which.entries

          delegate: Row {
            required property var modelData
            spacing: 6

            Text {
              text: modelData[0]
              color: Zenon.cyan
              font.family: "JetBrainsMono Nerd Font Mono"
              font.weight: Font.Bold
              font.pixelSize: 15
            }

            Text {
              text: modelData[1]
              color: Zenon.muted
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 15
            }
          }
        }
      }
    }

    // ── the keymap, on F1 ─────────────────────────────────────────────
    // The hint strip is gone. A permanent one row of keys could only ever show
    // a fraction of them and cost a strip of the window for the privilege;
    // yazi puts the whole list behind a key, and so does this. Any key closes
    // it, because the reason it is open is that you wanted one.
    Rectangle {
      id: help
      anchors.fill: parent
      z: 20
      visible: opacity > 0.01
      opacity: help.open ? 1 : 0
      // Translucent, because what is behind it is blurred rather than sharp.
      // At 0.82 over an unblurred grid of thumbnails the text was unreadable;
      // over a blurred one this is enough to sit the keymap forward without
      // hiding the window it belongs to.
      color: Qt.rgba(0, 0, 0, 0.72)
      Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

      property bool open: false
      property string helpQuery: ""

      // The list, with every entry that does not match dropped and any group
      // left empty removed with it. Matching runs over the KEYS and the
      // DESCRIPTION together, so "tab" finds ctrl-tab and "new tab" alike, and
      // the group name counts too — typing "trash" keeps the whole trash
      // section rather than only the lines that repeat the word.
      readonly property var shownGroups: {
        const q = help.helpQuery.trim().toLowerCase();
        if (q === "") return help.groups;
        const out = [];
        for (const g of help.groups) {
          const groupHit = String(g[0]).toLowerCase().indexOf(q) >= 0;
          const rows = [];
          for (const r of g[1]) {
            if (groupHit
                || (String(r[0]) + " " + String(r[1])).toLowerCase().indexOf(q) >= 0)
              rows.push(r);
          }
          if (rows.length > 0) out.push([g[0], rows]);
        }
        return out;
      }

      readonly property int hitCount: help.shownRows.length

      // The groups flattened to plain key/description pairs. The grouped
      // layout put four narrow columns across the window and left the eye
      // hunting for which one held what; two columns read straight down.
      // The group name is kept on each row as a quiet third field, so the
      // sections are still legible without being structure.
      readonly property var shownRows: {
        const out = [];
        for (const g of help.shownGroups) {
          for (const r of g[1]) out.push([r[0], r[1], g[0]]);
        }
        return out;
      }

      // Cleared on the way in, so F1 always opens on the whole list rather
      // than on whatever you last searched for.
      onOpenChanged: {
        help.helpQuery = "";
        if (help.open) helpField.forceActiveFocus();
        else content.forceActiveFocus();
      }

      MouseArea {
        anchors.fill: parent
        onClicked: help.open = false
      }

      readonly property var groups: [
        ["move", [["j / k  ↓ ↑", "down / up"], ["h / l  ← →", "parent / enter"],
                  ["g g", "top"], ["G", "bottom"],
                  ["ctrl u / d", "half page"], ["ctrl b / f", "page"],
                  ["mouse 4 / 5", "back / forward"]]],
        ["select", [["space", "toggle and move on"], ["ctrl a", "all"],
                    ["ctrl r", "invert"], ["esc", "clear"]]],
        ["act", [["y", "copy"], ["x", "cut"], ["p", "paste"],
                 ["d", "trash"], ["D", "delete for good"],
                 ["a", "create (end in / for a folder)"], ["r", "rename"],
                 ["c m", "permissions"], [";  ctrl s", "shell here"],
                 ["u", "undo trash / move / rename"],
                 ["c a", "compress selection"]]],
        ["look", [["f  /", "filter"], ["s", "search names"],
                  ["S", "search contents"], [".", "hidden"],
                  [", n / s / m", "sort name / size / time"], [", !", "reverse"],
                  ["v", "view: columns · list · grid"], ["+ / -", "zoom"],
                  ["ctrl 0", "reset zoom"]]],
        ["go", [["g space", "type a path (tab completes)"],
                ["g h", "home"], ["g c", "config"], ["g d", "downloads"],
                ["g D", "documents"], ["g p", "pictures"], ["g v", "videos"],
                ["g t", "trash"], ["g m", "media"], ["g /", "root"]]],
        ["copy", [["c c", "full path"], ["c d", "directory"],
                  ["c f", "filename"], ["c n", "name without extension"]]],
        ["tabs", [["t", "new"], ["w", "close"], ["1 - 9", "switch"],
                  ["[  ]", "previous / next"]]],
        ["marks", [["b a", "bookmark here"], ["b d", "remove bookmark"]]],
        ["menu", [["right click", "actions for the row"],
                  ["\u2014", "extract · compress · open with"],
                  ["\u2014", "bulk rename · links · restore"],
                  ["\u2014", "sort, as a submenu"]]],
        ["window", [["F1  ~", "this list"], ["q", "close"],
                    ["esc", "clear filter / selection"],
                    ["mouse 4 / 5", "up / forward"]]]
      ]

      // ── searching it ────────────────────────────────────────────────
      // The list has grown past what fits on one screen, and scrolling a wall
      // of two-column text looking for the word "rename" is worse than typing
      // it. The field has focus the moment F1 opens, so it is type-to-filter
      // rather than something you have to click into first.
      Item {
        id: helpSearch
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 28
        height: 40

        Text {
          id: helpGlyph
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "\uf002"
          color: Zenon.muted
          font.family: "JetBrainsMono Nerd Font Mono"
          font.pixelSize: 16
        }

        TextInput {
          id: helpField
          anchors.left: helpGlyph.right
          anchors.leftMargin: 12
          anchors.right: helpCount.left
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          color: Zenon.white
          selectionColor: Zenon.selBg
          selectedTextColor: Zenon.white
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 17
          clip: true
          onTextChanged: help.helpQuery = text

          // Escape backs out one step at a time: it clears a search first, and
          // only closes the list once there is nothing to clear.
          Keys.onEscapePressed: (e) => {
            e.accepted = true;
            if (helpField.text !== "") helpField.text = "";
            else help.open = false;
          }
          Keys.onPressed: (e) => {
            if (e.key === Qt.Key_F1) { e.accepted = true; help.open = false; }
          }

          Text {
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            visible: helpField.text === ""
            text: "search the keymap\u2026"
            color: Zenon.muted
            font.family: helpField.font.family
            font.pixelSize: helpField.font.pixelSize
          }
        }

        Text {
          id: helpCount
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: help.helpQuery === "" ? ""
            : help.hitCount + (help.hitCount === 1 ? " match" : " matches")
          color: help.hitCount === 0 ? Zenon.red : Zenon.cyan
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 14
        }

        Rectangle {
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: 1
          color: Zenon.msgBorder
        }
      }

      Flickable {
        anchors.top: helpSearch.bottom
        anchors.topMargin: 16
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 28
        anchors.rightMargin: 28
        anchors.bottomMargin: 34
        contentHeight: helpGrid.implicitHeight
        clip: true

        Column {
          id: helpGrid
          width: parent.width

          Repeater {
            model: help.shownRows

            delegate: Item {
              required property var modelData
              required property int index
              width: helpGrid.width
              height: 30

              // The section name, printed once where it changes rather than on
              // every line — a column of the word "act" repeated eleven times
              // is noise, but knowing which section you are in is not.
              readonly property bool starts: index === 0
                || help.shownRows[index - 1][2] !== modelData[2]

              Rectangle {
                anchors.fill: parent
                color: helpHov.hovered ? Zenon.hoverTint : "transparent"
              }
              HoverHandler { id: helpHov }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: 8
                width: 150
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: modelData[0]
                elide: Text.ElideLeft
                color: Zenon.keyInk
                font.family: "JetBrainsMono Nerd Font Mono"
                font.weight: Font.Bold
                font.pixelSize: 16
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: 174
                anchors.right: helpSection.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: modelData[1]
                elide: Text.ElideRight
                color: Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 16
              }

              Text {
                id: helpSection
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: parent.starts ? modelData[2] : ""
                color: Zenon.cyan
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 13
              }
            }
          }
        }
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        text: "type to search  \u00b7  esc or F1 to close"
        color: Zenon.muted
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: 11
      }
    }


    // ── typing a destination ──────────────────────────────────────────
    // `g` then space. Everything else under `g` is a place someone decided was
    // worth a key; this is the escape hatch for the places nobody did.
    //
    // It completes as a shell does, and deliberately not as a dropdown does:
    // Tab fills in as far as the candidates agree and stops, rather than
    // picking one for you. The list underneath is there to be read, and the
    // arrows walk it when you would rather choose than type.
    Rectangle {
      id: pathBar
      anchors.fill: parent
      z: 12
      visible: opacity > 0.01
      opacity: pathBar.open ? 1 : 0
      color: Qt.rgba(0, 0, 0, 0.55)
      Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

      property bool open: false
      // every directory in the directory currently being completed against
      property var names: []
      property int pick: -1

      readonly property var ctx:
        Janus.completionContext(pathField.text, Paths.home(), root.cwd)
      readonly property var hits:
        Janus.completionsFor(pathBar.namesText, pathBar.ctx.frag)
      property string namesText: ""

      // The part Tab would add: how far the candidates agree, minus what is
      // already typed. Empty when there is nothing to add, which is what makes
      // the ghost disappear the moment a name is complete.
      readonly property string ghost: Janus.ghostFor(pathBar.hits, pathBar.ctx.frag)

      // Every path the field is written through, so the caret can never be
      // left in the middle of a completion. Typing continues where the text
      // ends, which is the only place there is anything useful to type.
      function setPath(t) {
        pathField.text = t;
        pathField.cursorPosition = pathField.text.length;
      }

      function begin() {
        pathBar.open = true;
        pathBar.pick = -1;
        // Opens on where you ARE, with a trailing slash, so the first thing
        // completion offers is this directory's own children. Starting empty
        // would make the common case — go somewhere near here — begin by
        // typing out where you already are.
        pathBar.setPath(root.cwd === "/" ? "/" : root.cwd + "/");
        pathField.forceActiveFocus();
        pathBar.reload();
      }

      function dismiss() {
        pathBar.open = false;
        pathBar.names = [];
        pathBar.namesText = "";
        content.forceActiveFocus();
      }

      // Re-listed whenever the DIRECTORY being completed changes — not on
      // every keystroke. Typing further into one directory filters a list we
      // already hold; only crossing a slash costs a process.
      property string lastDir: ""

      function reload() {
        const d = pathBar.ctx.dir;
        if (d === pathBar.lastDir) return;
        pathBar.lastDir = d;
        completeProc.command = ["sh", "-c", Janus.completeCommand(d)];
        completeProc.running = true;
      }

      // Tab: take the agreed prefix. When that adds nothing and there is
      // exactly one candidate, step into it — the second Tab on a finished
      // name is how you descend without reaching for the slash.
      function complete() {
        if (pathBar.hits.length === 0) return;

        // ONE Tab when there is one answer.
        //
        // Taking the candidate is checked BEFORE filling in the shared prefix,
        // and that order is the whole behaviour. The other way round, a lone
        // candidate cost two presses — the first spelled the name out, the
        // second added the slash — and the first press had told you nothing
        // you could not already see.
        //
        // So: a highlighted candidate, or a single candidate, completes whole.
        // Only a genuine ambiguity falls through to the prefix.
        if (pathBar.pick >= 0 || pathBar.hits.length === 1) {
          const one = pathBar.pick >= 0 ? pathBar.hits[pathBar.pick]
                                        : pathBar.hits[0];
          pathBar.setPath(Janus.completedPath(pathBar.ctx.dir, one));
          pathBar.pick = -1;
          pathBar.reload();
          return;
        }

        // Rewrites the fragment rather than appending to it, so the result
        // carries the directory's real capitalisation: "doc" completes to
        // "Documents", not "documents".
        const pre = Janus.completePrefix(pathBar.hits, pathBar.ctx.frag);
        if (pre !== "" && pre.length > pathBar.ctx.frag.length) {
          pathBar.setPath(Janus.joinPath(pathBar.ctx.dir, pre));
          pathBar.reload();
          return;
        }

        // Several candidates that share nothing further — a fuzzy match with
        // no prefix to agree on. The best-ranked one is the honest guess.
        pathBar.setPath(Janus.completedPath(pathBar.ctx.dir, pathBar.hits[0]));
        pathBar.pick = -1;
        pathBar.reload();
      }

      function step(d) {
        if (pathBar.hits.length === 0) return;
        pathBar.pick = Math.max(0,
          Math.min(pathBar.hits.length - 1, pathBar.pick + d));
        pathBar.setPath(
          Janus.completedPath(pathBar.ctx.dir, pathBar.hits[pathBar.pick]));
      }

      // Enter goes. A directory is entered; a FILE lands you in its parent
      // with the cursor on it, because "go to this path" said something real
      // even when what you named was not somewhere you can stand.
      function accept() {
        const target = Janus.expandPath(pathField.text, Paths.home(), root.cwd);
        if (target === "") { pathBar.dismiss(); return; }
        pathBar.dismiss();
        checkProc.command = ["sh", "-c",
          "if [ -d " + Strings.shellQuote(target) + " ]; then printf d; "
          + "elif [ -e " + Strings.shellQuote(target) + " ]; then printf f; fi"];
        pathBar.pendingTarget = target;
        checkProc.running = true;
      }

      property string pendingTarget: ""

      Process {
        id: completeProc
        stdout: StdioCollector {
          id: completeOut
          waitForEnd: true
          onStreamFinished: pathBar.namesText = completeOut.text
        }
      }

      Process {
        id: checkProc
        stdout: StdioCollector {
          id: checkOut
          waitForEnd: true
          onStreamFinished: {
            const kind = String(checkOut.text || "").trim();
            const t = pathBar.pendingTarget;
            pathBar.pendingTarget = "";
            if (kind === "d") { root.goTo(t); return; }
            if (kind === "f") {
              root.wantSel = t;
              root.goTo(Janus.dirname(t));
              return;
            }
            root.status = "no such path";
          }
        }
      }

      MouseArea { anchors.fill: parent; onClicked: pathBar.dismiss() }

      ClippingRectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 90
        width: Math.min(760, parent.width - 80)
        height: pathCol.implicitHeight
        color: Zenon.black
        border.color: Zenon.surface
        border.width: 1
        radius: 10
        transform: Translate { y: (1 - pathBar.opacity) * 10 }

        Column {
          id: pathCol
          width: parent.width

          Item {
            width: parent.width
            height: 46

            Text {
              id: pathGlyph
              anchors.left: parent.left
              anchors.leftMargin: 14
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf07c"
              color: Zenon.cyan
              font.family: "JetBrainsMono Nerd Font Mono"
              font.pixelSize: 17
            }

            // The typed text and the ghost are ONE line built from two items:
            // the input holds only what you typed, and the completion trails
            // it dimmed. Putting the ghost inside the field would mean deleting
            // it back out on every keystroke.
            TextMetrics {
              id: pathMetrics
              font: pathField.font
              text: pathField.text
            }

            TextInput {
              id: pathField
              anchors.left: pathGlyph.right
              anchors.leftMargin: 12
              anchors.right: parent.right
              anchors.rightMargin: 14
              anchors.verticalCenter: parent.verticalCenter
              color: Zenon.white
              selectionColor: Zenon.selBg
              selectedTextColor: Zenon.white
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 17
              clip: true
              onTextChanged: { pathBar.pick = -1; pathBar.reload(); }

              Text {
                // Placed by MEASURING the typed text, not by asking the input
                // where its cursor is. positionToRectangle is a method, and a
                // binding that calls one is computed once and never again — the
                // completion sat at x=0, printed over the start of the path.
                // TextMetrics is a property the binding can actually track.
                x: pathMetrics.advanceWidth
                anchors.verticalCenter: parent.verticalCenter
                visible: pathBar.ghost !== ""
                text: pathBar.ghost
                color: Zenon.muted
                font.family: pathField.font.family
                font.pixelSize: pathField.font.pixelSize
              }

              Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Tab) {
                  e.accepted = true; pathBar.complete(); return;
                }
                if (e.key === Qt.Key_Down) {
                  e.accepted = true; pathBar.step(1); return;
                }
                if (e.key === Qt.Key_Up) {
                  e.accepted = true; pathBar.step(-1); return;
                }
              }
              Keys.onReturnPressed: (e) => { e.accepted = true; pathBar.accept(); }
              Keys.onEnterPressed: (e) => { e.accepted = true; pathBar.accept(); }
              Keys.onEscapePressed: (e) => { e.accepted = true; pathBar.dismiss(); }
            }
          }

          Rectangle {
            width: parent.width
            height: pathBar.hits.length > 0 ? 1 : 0
            color: Zenon.msgBorder
          }

          // The candidates, capped. A directory with four hundred children is
          // not a list you read, and the field plus the ghost already tell you
          // what typing another letter would do.
          Repeater {
            model: pathBar.hits.slice(0, 8)

            delegate: Item {
              required property var modelData
              required property int index
              width: pathCol.width
              height: 28

              Rectangle {
                anchors.fill: parent
                color: index === pathBar.pick ? Zenon.selBg
                  : (hitHov.hovered ? Zenon.hoverTint : "transparent")
              }
              HoverHandler { id: hitHov }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: 43
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: modelData
                elide: Text.ElideMiddle
                color: index === pathBar.pick ? Zenon.white : Zenon.keyInk
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 15
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  pathBar.setPath(Janus.completedPath(pathBar.ctx.dir, modelData));
                  pathBar.reload();
                  pathField.forceActiveFocus();
                }
                onDoubleClicked: pathBar.accept()
              }
            }
          }

          Item {
            width: parent.width
            height: pathBar.hits.length > 8 ? 22 : 0
            visible: height > 0

            Text {
              anchors.left: parent.left
              anchors.leftMargin: 43
              anchors.verticalCenter: parent.verticalCenter
              text: "+" + (pathBar.hits.length - 8) + " more"
              color: Zenon.muted
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 13
            }
          }
        }
      }
    }

    // ── the right-click menu ──────────────────────────────────────────
    // What you can do to the thing under the pointer. Everything here has a
    // key as well; this is the half of the interface for the hand that is
    // already on the mouse.
    Item {
      id: menu
      anchors.fill: parent
      z: 9
      visible: menu.open

      property bool open: false
      property real mx: 0
      property real my: 0

      readonly property var target: root.currentRow()
      readonly property bool isImage:
        !!menu.target && !menu.target.isDir && Janus.isImage(menu.target.name)

      // on a row: everything applies to it
      function openAt(item, mouse) {
        const p = item.mapToItem(menu, mouse.x, mouse.y);
        menu.mx = p.x;
        menu.my = p.y;
        menu.here = false;
        menu.subAt = -1;
        menu.open = true;
        // asked now rather than on every selection change: it is a process,
        // and almost every right-click is not about opening with something
        const t = menu.target;
        root.findApps(t && !t.isDir ? t.path : "");
      }

      // on empty space: only the things that are about the DIRECTORY, because
      // there is no row under the pointer to be about
      function openHere(item, mouse) {
        const p = item.mapToItem(menu, mouse.x, mouse.y);
        menu.mx = p.x;
        menu.my = p.y;
        menu.here = true;
        menu.subAt = -1;
        menu.open = true;
      }

      property bool here: false

      // The sort options, as the submenu the `,` sequence already spells out.
      // One list feeding both would be ideal; these are three lines and the
      // sequence table's entries carry hint text this menu has no room for.
      // One row per format, described rather than just named: ".tar.zst" is
      // not self-explanatory to anyone who has not met zstd.
      readonly property var formatItems: {
        const out = [];
        for (const f of root.archiveFormats) {
          const ext = f[0];
          out.push({ label: ext, hint: f[1],
                     act: () => root.beginCompress(ext) });
        }
        return out;
      }

      readonly property var sortItems: [
        { label: "Name", act: () => root.setSort("name") },
        { label: "Size", act: () => root.setSort("size") },
        { label: "Modified", act: () => root.setSort("time") },
        { sep: true },
        { label: root.sortDesc ? "Ascending" : "Descending",
          act: () => root.sortDesc = !root.sortDesc }
      ]

      // Filled by the process findApps starts when the menu opens. Empty until
      // it answers, which is why it says so rather than showing nothing.
      readonly property var appItems: {
        const t = menu.target;
        if (!t) return [];
        const apps = root.openWithApps;
        if (apps.length === 0)
          return [{ label: "(no applications)", act: () => {} }];
        const out = [];
        for (let i = 0; i < apps.length; ++i) {
          const id = apps[i].id;
          out.push({ label: apps[i].name, act: () => root.openWith(id, t.path) });
        }
        return out;
      }

      // which item's submenu is showing, or -1
      property int subAt: -1

      function close() {
        menu.open = false;
        menu.subAt = -1;
        content.forceActiveFocus();
      }

      // anything that misses the card puts it away
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: menu.close()
      }

      readonly property var items: {
        if (menu.here) {
          const out = [];
          if (root.pending) {
            out.push({ label: "Paste here", act: () => root.paste() });
            out.push({ label: "Paste as symlink", act: () => root.pasteLink(true) });
            out.push({ label: "Paste as hard link", act: () => root.pasteLink(false) });
          }
          out.push({ label: "New folder\u2026", act: () => root.beginMkdir() });
          out.push({ label: "New file\u2026", act: () => root.beginCreate() });
          out.push({ sep: true });
          out.push({ label: "Sort by", sub: menu.sortItems });
          if (root.undoStack.length > 0)
            out.push({ label: root.undoLabel, act: () => root.undo() });
          out.push({ sep: true });
          out.push({ label: root.isBookmarked(root.cwd)
              ? "Remove bookmark" : "Bookmark this folder",
            act: () => root.toggleBookmark() });
          if (root.inTrash)
            out.push({ label: "Empty the trash\u2026", danger: true,
                       act: () => root.emptyTrash() });
          out.push({ label: "Open shell here", act: () => root.openShell() });
          out.push({ label: "Select all", act: () => root.selectAll() });
          return out;
        }
        const t = menu.target;
        if (!t) return [];
        // the cheap counter, so labels stay right without depending on the
        // whole selection array
        const n = root.markedCount > 0 ? root.markedCount : 1;
        const many = n > 1 ? " (" + n + ")" : "";
        const out = [
          { label: t.isDir ? "Open folder" : "Open", act: () => root.activate() },
          { label: "Copy" + many, act: () => root.yank("copy") },
          { label: "Cut" + many, act: () => root.yank("move") }
        ];
        if (root.pending)
          out.push({ label: "Paste here", act: () => root.paste() });
        out.push({ label: "Rename\u2026", act: () => root.beginRename() });
        if (n > 1)
          out.push({ label: "Bulk rename\u2026" + many,
                     act: () => root.beginBulkRename() });
        if (root.pending) {
          out.push({ label: "Paste as symlink", act: () => root.pasteLink(true) });
          out.push({ label: "Paste as hard link", act: () => root.pasteLink(false) });
        }
        // Only where it can do something: an Extract on a text file and a
        // Restore outside the trash are entries that exist to be greyed out.
        if (Janus.isArchive(t.name) && !t.isDir)
          out.push({ label: "Extract here" + many, act: () => root.extractSelected() });
        out.push({ label: "Compress" + many, sub: menu.formatItems });
        if (root.inTrash) {
          out.push({ label: "Restore" + many, act: () => root.restoreSelected() });
          out.push({ label: "Empty the trash\u2026", danger: true,
                     act: () => root.emptyTrash() });
        }
        if (!t.isDir)
          out.push({ label: "Open with", sub: menu.appItems });
        out.push({ label: "Sort by", sub: menu.sortItems });
        out.push({ label: "Copy path", act: () => root.copyPath() });
        out.push({ label: "Permissions\u2026", act: () => perms.ask() });
        out.push({ label: "Properties\u2026", act: () => props.ask() });
        if (t.isDir)
          out.push({ label: root.isBookmarked(t.path)
              ? "Remove bookmark" : "Bookmark",
            act: () => root.toggleBookmarkFor(t.path) });
        if (menu.isImage) {
          out.push({ sep: true });
          out.push({ label: "Set as wallpaper",
                     act: () => root.setWallpaper(null) });
          const screens = Quickshell.screens;
          if (screens.length > 1) {
            for (let i = 0; i < screens.length; ++i) {
              const nm = screens[i].name;
              out.push({ label: "Wallpaper on " + nm,
                         act: () => root.setWallpaper(nm) });
            }
          }
        }
        out.push({ sep: true });
        out.push({ label: "Trash" + many, danger: true, act: () => root.trash() });
        return out;
      }

      ClippingRectangle {
        id: menuCard
        // kept inside the window: a menu opened near the right edge that
        // hangs off it is a menu with items you cannot reach
        // Rounded. The position comes from a pointer, which lands on
        // fractions of a pixel, and an item on a half pixel renders its text
        // through a filter — which is what "blurry" was.
        x: Math.round(Math.max(4, Math.min(menu.mx, menu.width - width - 4)))
        y: Math.round(Math.max(4, Math.min(menu.my, menu.height - height - 4)))
        width: 240
        height: menuCol.implicitHeight + 8
        // Solid. A backdrop blur here was fighting the card rather than
        // helping it: ShaderEffectSource copies the rectangle behind the card,
        // and a menu that opens over three columns of text ends up smearing
        // three different backgrounds under one small surface. Opaque black is
        // what a menu wants — it is meant to sit ON the window, not in it.
        color: Zenon.black
        border.color: Zenon.surface
        border.width: 1
        radius: 6

        Column {
          id: menuCol
          width: parent.width
          topPadding: 4
          bottomPadding: 4

          Repeater {
            model: menu.items

            delegate: Item {
              required property var modelData
              width: menuCol.width
              height: modelData.sep ? 7 : 30

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 8
                height: 1
                visible: !!modelData.sep
                color: Zenon.msgBorder
              }

              required property int index

              Rectangle {
                anchors.fill: parent
                visible: !modelData.sep
                // the border's own colour, so the highlight reads as part of
                // the card rather than a light laid over it
                color: itemHov.hovered || menu.subAt === index
                  ? Zenon.surface : "transparent"
              }
              HoverHandler {
                id: itemHov
                enabled: !modelData.sep
                // Hovering a row with children opens them and hovering one
                // without closes whatever was open — so moving down the card
                // never leaves an orphaned second card beside an unrelated row.
                onHoveredChanged: if (hovered) menu.subAt = modelData.sub ? index : -1
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                visible: !modelData.sep
                text: modelData.label || ""
                color: modelData.danger ? Zenon.red : Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 15
              }

              // the chevron that says there is more to the right
              Text {
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                visible: !!modelData.sub
                text: "\uf105"   // nf-fa-angle_right
                color: Zenon.muted
                font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: 14
              }

              MouseArea {
                anchors.fill: parent
                enabled: !modelData.sep
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  // a parent row opens its children rather than doing anything
                  if (modelData.sub) { menu.subAt = index; return; }
                  menu.close();
                  modelData.act();
                }
              }
            }
          }
        }
      }

      // ── the submenu ───────────────────────────────────────────────
      // A second card beside the first, for the entries that are a CHOICE
      // rather than an action — how to sort, which application to open with.
      // Those would each be four or five more rows on a menu that is already
      // long, and they are all answers to one question, which is what a
      // submenu is for.
      //
      // Its y is computed from the rows above it rather than measured off the
      // delegate: the rows are a fixed 30 and separators 7, so the arithmetic
      // is exact and nothing has to be mapped between items.
      ClippingRectangle {
        id: subCard
        visible: menu.subAt >= 0 && subCard.items.length > 0

        readonly property var items: {
          if (menu.subAt < 0) return [];
          const it = menu.items[menu.subAt];
          return (it && it.sub) ? it.sub : [];
        }

        readonly property real rowTop: {
          let y = 4;   // menuCol's top padding
          for (let i = 0; i < menu.subAt && i < menu.items.length; ++i) {
            y += menu.items[i].sep ? 7 : 30;
          }
          return y;
        }

        width: subCard.items.length > 0 && subCard.items[0].hint ? 330 : 200
        height: subCol.implicitHeight + 8
        // Flipped to the left of the parent card when there is no room on the
        // right, for the same reason the parent card is clamped to the window.
        x: Math.round(menuCard.x + menuCard.width + 2 + width < menu.width - 4
          ? menuCard.x + menuCard.width + 2
          : Math.max(4, menuCard.x - width - 2))
        y: Math.round(Math.max(4,
          Math.min(menuCard.y + subCard.rowTop, menu.height - height - 4)))
        color: Zenon.black
        border.color: Zenon.surface
        border.width: 1
        radius: 6

        Column {
          id: subCol
          width: parent.width
          topPadding: 4
          bottomPadding: 4

          Repeater {
            model: subCard.items

            delegate: Item {
              required property var modelData
              width: subCol.width
              height: modelData.sep ? 7 : 30

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 8
                height: 1
                visible: !!modelData.sep
                color: Zenon.msgBorder
              }

              Rectangle {
                anchors.fill: parent
                visible: !modelData.sep
                color: subHov.hovered ? Zenon.surface : "transparent"
              }
              HoverHandler { id: subHov; enabled: !modelData.sep }

              Text {
                id: subLabel
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                visible: !modelData.sep
                text: modelData.label || ""
                color: Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 15
              }

              // what the format actually is, for the rows that carry one
              Text {
                anchors.left: subLabel.right
                anchors.leftMargin: 12
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                visible: !!modelData.hint
                text: modelData.hint || ""
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
                color: Zenon.muted
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 12
              }

              MouseArea {
                anchors.fill: parent
                enabled: !modelData.sep
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  menu.close();
                  modelData.act();
                }
              }
            }
          }
        }
      }

    }

    // ── permissions ───────────────────────────────────────────────────
    // Nine bits, shown as the grid they are. The octal and the rwxrwxrwx
    // string are both on screen because those are the two forms every other
    // tool speaks, and reading one off the other in your head is exactly the
    // step that gets a mode wrong.
    Rectangle {
      id: perms
      anchors.fill: parent
      z: 12
      visible: opacity > 0.01
      opacity: perms.open ? 1 : 0
      color: Qt.rgba(0, 0, 0, 0.55)
      Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

      property bool open: false
      property int mode: 0
      property var paths: []

      function ask() {
        const rows = root.acting();
        if (rows.length === 0) return;
        perms.paths = rows.map((r) => r.path);
        // the cursor's mode is the starting point even for a multi-select:
        // there is no single answer for a mixed set, and picking one of them
        // is more honest than showing zero
        perms.mode = rows[0].mode || 0;
        perms.open = true;
      }

      function apply() {
        root.run(Janus.chmodCommand(perms.paths, perms.mode));
        perms.open = false;
        content.forceActiveFocus();
      }

      MouseArea {
        anchors.fill: parent
        onClicked: { perms.open = false; content.forceActiveFocus(); }
      }

      ClippingRectangle {
        anchors.centerIn: parent
        width: 400
        // Sized to what is in it, like every other dialog here. It was a fixed
        // 208 that happened to fit the type it had; enlarging the type left a
        // band of empty card under the buttons, and the next change to its
        // contents would have done the same thing again.
        height: permsCol.implicitHeight
        color: Zenon.black
        border.color: Zenon.surface
        border.width: 1
        radius: 10
        transform: Translate { y: (1 - perms.opacity) * 10 }

        Column {
          id: permsCol
          width: parent.width

          Rectangle {
            width: parent.width
            height: 34
            color: Zenon.cyan
            Text {
              anchors.centerIn: parent
              text: perms.paths.length > 1
                ? "Permissions · " + perms.paths.length + " items" : "Permissions"
              color: Zenon.black
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 16
            }
          }

          Item {
            width: parent.width
            height: 30
            Text {
              anchors.centerIn: parent
              text: ("000" + (perms.mode & 511).toString(8)).slice(-3)
                + "   " + Janus.modeString(perms.mode)
              color: Zenon.sand
              font.family: "JetBrainsMono Nerd Font Mono"
              font.weight: Font.Bold
              font.pixelSize: 17
            }
          }

          // three rows of three, in the order chmod writes them
          Repeater {
            model: [["owner", 6], ["group", 3], ["other", 0]]

            delegate: Row {
              id: permRow
              required property var modelData
              // named, because the inner Repeater's delegate cannot reach out
              // through `parent` to find it — its parent is this Row, but the
              // chain that looked plausible (parent.parent.modelData) resolves
              // to the Repeater's own parent and yields undefined
              readonly property int shift: modelData[1]
              width: parent.width
              height: 30
              leftPadding: 40
              spacing: 10

              Text {
                width: 60
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: modelData[0]
                color: Zenon.muted
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 15
              }

              Repeater {
                model: [["r", 4], ["w", 2], ["x", 1]]

                delegate: Rectangle {
                  required property var modelData
                  readonly property int bit: modelData[1] << permRow.shift
                  readonly property bool on: (perms.mode & bit) !== 0
                  width: 54
                  height: 22
                  anchors.verticalCenter: parent.verticalCenter
                  radius: 4
                  color: on ? Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.20)
                    : (bitHov.hovered ? Zenon.hoverTint : "transparent")
                  border.width: 1
                  border.color: on ? Zenon.cyan : Zenon.msgBorder

                  Text {
                    anchors.centerIn: parent
                    text: modelData[0]
                    color: parent.on ? Zenon.cyan : Zenon.muted
                    font.family: "JetBrainsMono Nerd Font Mono"
                    font.weight: Font.Bold
                    font.pixelSize: 15
                  }

                  HoverHandler { id: bitHov }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: perms.mode = perms.mode ^ parent.bit
                  }
                }
              }
            }
          }

          Row {
            width: parent.width
            height: 30

            Repeater {
              model: [false, true]

              delegate: Item {
                required property var modelData
                width: parent.width / 2
                height: parent.height

                Rectangle {
                  anchors.fill: parent
                  color: pbHov.hovered ? Zenon.hoverTint : "transparent"
                }
                HoverHandler { id: pbHov }

                Text {
                  anchors.centerIn: parent
                  text: modelData ? "Apply" : "Cancel"
                  color: modelData ? Zenon.cyan : Zenon.muted
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.weight: Font.Bold
                  font.pixelSize: 15
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (modelData) perms.apply();
                    else { perms.open = false; content.forceActiveFocus(); }
                  }
                }
              }
            }
          }
        }
      }
    }

    // ── the confirmation ──────────────────────────────────────────────
    // Everything that overwrites or deletes comes through here. Same shape as
    // zeus' kill card, and for the same reason: the thing you are about to act
    // on stays on screen behind the question, dimmed, so you can still read
    // what you picked while you answer for it.
    Rectangle {
      id: confirm
      anchors.fill: parent
      z: 10
      visible: opacity > 0.01
      opacity: confirm.open ? 1 : 0
      color: Qt.rgba(0, 0, 0, 0.55)
      Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

      property bool open: false
      property string heading: ""
      property string detail: ""
      // Every button on the card, Cancel included: { label, ink, act }. A LIST
      // rather than a fixed yes/no pair, because a paste onto a name that is
      // already taken has three real answers and cramming a third one into a
      // second dialog would have been two cards that drift apart.
      property var choices: []

      // Red is reserved for what cannot be undone. Trash is recoverable, so it
      // is a warning colour and not an alarm.
      function verbInk(verb) {
        if (verb === "Delete") return Zenon.red;
        if (verb === "Trash") return Zenon.yellow;
        return Zenon.sand;
      }

      // The two-button case, which is most of them, in the shape every existing
      // caller already uses.
      function ask(heading, detail, verb, onYes) {
        confirm.askMany(heading, detail,
          [{ label: verb, ink: confirm.verbInk(verb), act: onYes }]);
      }

      // Cancel is appended here rather than passed in: every one of these can
      // be backed out of, and a caller that forgot to offer the way out would
      // be a dialog with no way out.
      function askMany(heading, detail, choices) {
        const all = choices.slice();
        all.push({ label: "Cancel", ink: Zenon.muted, act: null });
        confirm.heading = heading;
        confirm.detail = detail;
        confirm.choices = all;
        confirm.open = true;
        confirmKeys.forceActiveFocus();
      }

      function choose(i) {
        const c = confirm.choices[i];
        confirm.open = false;
        confirm.choices = [];
        content.forceActiveFocus();
        if (c && c.act) c.act();
      }

      // Enter takes the FIRST choice — the primary one, listed first for that
      // reason — and escape takes none of them.
      function accept() { confirm.choose(0); }

      function dismiss() {
        confirm.open = false;
        confirm.choices = [];
        content.forceActiveFocus();
      }

      MouseArea { anchors.fill: parent; onClicked: confirm.dismiss() }

      Item {
        id: confirmKeys
        anchors.fill: parent
        focus: confirm.open
        Keys.onPressed: (e) => {
          e.accepted = true;
          if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) confirm.accept();
          else if (e.key === Qt.Key_Escape) confirm.dismiss();
        }
      }

      ClippingRectangle {
        anchors.centerIn: parent
        // wider once there are more than two answers, so "Keep both" is not
        // squeezed into a column narrower than its own label
        width: Math.min(confirm.choices.length > 2 ? 700 : 560, parent.width - 60)
        height: confirmCol.implicitHeight
        color: Zenon.black
        border.color: Zenon.surface
        border.width: 1
        radius: 10
        transform: Translate { y: (1 - confirm.opacity) * 10 }

        Column {
          id: confirmCol
          width: parent.width

          // The header wears the PRIMARY choice's colour — the first one, the
          // one Enter takes — so the card reads as dangerous exactly when the
          // thing it is offering to do is.
          Rectangle {
            width: parent.width
            height: 34
            color: confirm.choices.length > 0
              ? confirm.choices[0].ink : Zenon.sand

            Text {
              anchors.centerIn: parent
              text: confirm.heading
              color: Zenon.black
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 17
            }
          }

          Item {
            width: parent.width
            height: 44

            Text {
              anchors.fill: parent
              anchors.margins: 12
              text: confirm.detail
              color: Zenon.white
              elide: Text.ElideRight
              wrapMode: Text.WordWrap
              maximumLineCount: 2
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 15
            }
          }

          Row {
            width: parent.width
            height: 32

            Repeater {
              model: confirm.choices

              delegate: Item {
                id: choiceBtn
                required property var modelData
                required property int index
                width: parent.width / Math.max(1, confirm.choices.length)
                height: parent.height

                readonly property color ink: choiceBtn.modelData.ink

                Rectangle {
                  anchors.fill: parent
                  color: btnHov.hovered
                    ? Qt.rgba(choiceBtn.ink.r, choiceBtn.ink.g, choiceBtn.ink.b, 0.25)
                    : "transparent"
                }
                HoverHandler { id: btnHov }

                Text {
                  anchors.centerIn: parent
                  text: choiceBtn.modelData.label
                  color: choiceBtn.ink
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.weight: Font.Bold
                  font.pixelSize: 15
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: confirm.choose(choiceBtn.index)
                }
              }
            }
          }
        }
      }
    }

    // ── the one-line prompt ───────────────────────────────────────────
    // Rename and new-folder both want a name and nothing else, so they share
    // one card rather than growing two nearly identical ones.
    Rectangle {
      id: prompt
      anchors.fill: parent
      z: 11
      visible: opacity > 0.01
      opacity: prompt.open ? 1 : 0
      color: Qt.rgba(0, 0, 0, 0.55)
      Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

      property bool open: false
      property string heading: ""
      property var onDone: null
      readonly property string error: Janus.nameError(promptField.text)

      function ask(heading, initial, onDone) {
        prompt.heading = heading;
        prompt.onDone = onDone;
        prompt.open = true;
        promptField.text = initial;
        // the stem, not the extension — renaming almost never means retyping
        // ".tar.gz", and selecting the lot means you have to click to avoid it
        const dot = initial.lastIndexOf(".");
        promptField.select(0, dot > 0 ? dot : initial.length);
        promptField.forceActiveFocus();
      }

      function accept() {
        if (prompt.error !== "") return;
        const fn = prompt.onDone;
        const name = promptField.text;
        prompt.open = false;
        prompt.onDone = null;
        content.forceActiveFocus();
        if (fn) fn(name);
      }

      function dismiss() {
        prompt.open = false;
        prompt.onDone = null;
        content.forceActiveFocus();
      }

      MouseArea { anchors.fill: parent; onClicked: prompt.dismiss() }

      ClippingRectangle {
        anchors.centerIn: parent
        width: Math.min(460, parent.width - 60)
        height: 104
        color: Zenon.black
        border.color: Zenon.surface
        border.width: 1
        radius: 10
        transform: Translate { y: (1 - prompt.opacity) * 10 }

        Column {
          width: parent.width

          Rectangle {
            width: parent.width
            height: 34
            color: Zenon.cyan

            Text {
              anchors.centerIn: parent
              text: prompt.heading
              color: Zenon.black
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 17
            }
          }

          Item {
            width: parent.width
            height: 40

            Rectangle {
              anchors.fill: parent
              anchors.margins: 10
              radius: 4
              color: Zenon.selBg
              border.width: 1
              border.color: prompt.error !== "" ? Zenon.red : Zenon.msgBorder

              TextInput {
                id: promptField
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                color: Zenon.white
                selectionColor: Zenon.cyan
                selectedTextColor: Zenon.black
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 16
                clip: true
                Keys.onReturnPressed: (e) => { e.accepted = true; prompt.accept(); }
                Keys.onEscapePressed: (e) => { e.accepted = true; prompt.dismiss(); }
              }
            }
          }

          Text {
            width: parent.width
            height: 24
            horizontalAlignment: Text.AlignHCenter
            text: prompt.error !== "" ? prompt.error : "return to confirm · esc to cancel"
            color: prompt.error !== "" ? Zenon.red : Zenon.muted
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 14
          }
        }
      }
    }
  }

  // One row of a directory, drawn the same way in all three places it appears.
  //
  // The list view wants size and date beside the name; the miller columns are
  // a third of the width and want the name alone; the preview pane wants the
  // name and no interaction at all. Those are the same row with two switches
  // on it, not three delegates — and three delegates is how the glyph, the
  // colour rules and the tick end up drifting apart.
  component EntryRow: Item {
    id: entryRow

    property var entry: null
    property bool current: false
    property bool ticked: false
    // size and modified, which only the full-width list has room for
    property bool showMeta: true
    // Kept, unused: the parent and preview columns set this to fade themselves
    // back, and reading a directory at 65% opacity turned out to be worse than
    // the ambiguity it was solving. Left in place because it is one property
    // and the next layout question may want it.
    property bool dim: false
    property bool clickable: true

    // What was held down when it was clicked. The row does not decide what
    // that means — clickRow does — because the same three modifiers have to
    // mean the same three things in all three views.
    signal chosen(bool right, bool shift, bool ctrl)
    signal opened()
    // middle click: a directory in a tab of its own, the way a browser opens
    // a link. Files have nothing sensible to do with it and ignore it.
    signal tabbed()

    height: root.rowH

    // ── dragging this row out ───────────────────────────────────────
    // Copied from scout, which drags into other applications successfully;
    // janus' own version did not, and the differences were all here.
    //
    // The attached Drag group is on the DELEGATE, not on a child Item that
    // fills it — janus had it on a child, and a child that merely fills its
    // parent is not the same thing to Qt's drag machinery. `Drag.source` and
    // `Drag.keys` were both missing entirely, and startDrag() returned false
    // with no warning: the drag began and nothing anywhere would accept it.
    //
    // CopyAction only, like scout. A move offered over the wayland data-device
    // means the source has to delete the file when the target says it took it,
    // and nothing here implements that half — so offering it would be a
    // promise janus cannot keep. Moving between janus windows is `x` then `p`.
    Drag.active: false
    Drag.source: entryRow
    Drag.keys: ["text/uri-list"]
    Drag.mimeData: ({ "text/uri-list": entryRow.entry ? root.dragUris(entryRow.entry) : "" })
    Drag.supportedActions: Qt.CopyAction
    Drag.dragType: Drag.Automatic
    Drag.hotSpot.x: 16
    Drag.hotSpot.y: entryRow.height / 2
    Drag.onDragFinished: (dropAction) => {
      entryRow.Drag.active = false;
      root.draggingRow = false;
    }

    // Resolved once per delegate. It was inkFor(entry) in two bindings — the
    // glyph's colour and the name's — and a function call in a binding cannot
    // be compiled, so every row paid for two interpreted calls on every
    // repaint. The value is already on the row; this just reads it.
    readonly property color rowInk: (entryRow.entry && entryRow.entry.ink !== undefined)
      ? entryRow.entry.ink : Zenon.muted

    // The CURSOR and a SELECTION are two different things, and they only need
    // to look different once both are on screen.
    //
    // They shared one fill, so opening a directory — where the cursor rests on
    // the first row by default — and then marking files elsewhere left that
    // first row looking selected when it was not in the selection at all.
    //
    // With nothing marked the cursor keeps its filled highlight, because then
    // there is nothing for it to be confused with. The moment a selection
    // exists, a cursor that is not part of it drops to an outline: still
    // plainly where you are, no longer claiming to be one of the chosen.
    readonly property bool cursorOnly:
      entryRow.current && !entryRow.ticked && root.markedCount > 0

    Rectangle {
      anchors.fill: parent
      // No hover tint. The cursor is already marked and a selection is already
      // marked; a third highlight that follows the pointer just made the list
      // twitch as it crossed.
      color: entryRow.cursorOnly ? "transparent"
        : (entryRow.current ? Zenon.selBg
          : (entryRow.ticked ? Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.10)
            : "transparent"))

      // the outline that replaces the fill
      border.width: entryRow.cursorOnly ? 1 : 0
      border.color: Zenon.msgBorder
    }

    // Still tracked, for the drag box: whether the pointer is ON a row is what
    // decides whether a drag moves that row or draws a selection rectangle.
    HoverHandler {
      id: entryHov
      enabled: entryRow.clickable
      onHoveredChanged: {
        if (hovered) root.hoverRow = true;
        else if (root.hoverRow) root.hoverRow = false;
      }
    }

    // The gesture that starts a drag. Scout's shape: a DragHandler with no
    // target, which sets Drag.active imperatively once it activates — the
    // handler decides WHEN, the attached group above decides WHAT.
    DragHandler {
      id: rowDrag
      target: null
      enabled: entryRow.clickable && !!entryRow.entry
      onActiveChanged: {
        if (!rowDrag.active) return;
        root.draggingRow = true;
        entryRow.Drag.active = true;
      }
    }

    // The row's clicks.
    //
    // The drag used to be a DragHandler, and it never once activated — proved
    // with a logging handler across drags of every length and speed, in every
    // view, with and without permission to take the grab from anything. The
    // row lives inside a Flickable, and whatever the arbitration was doing, the
    // handler was not winning it.
    //
    // This MouseArea, on the other hand, demonstrably receives the press: row
    // clicks and ctrl-clicks have always worked. So the drag is started from
    // here instead, by setting Drag.active once the pointer has moved far
    // enough to mean it — with Drag.Automatic that is what hands the gesture to
    // the platform, and no startDrag() call is needed (calling it as well is
    // what once logged "startDrag() drag must be active").
    //
    // preventStealing keeps the ListView from claiming the gesture as a flick
    // half way through. Nothing is lost by it: the rubber band is already
    // disabled while the pointer is on a row.
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      enabled: entryRow.clickable
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      cursorShape: Qt.PointingHandCursor

      property bool dragging: rowDrag.active

      onClicked: (m) => {
        // a gesture that became a drag is not also a click
        if (rowMouse.dragging) return;
        if (m.button === Qt.MiddleButton) { entryRow.tabbed(); return; }
        const right = m.button === Qt.RightButton;
        entryRow.chosen(right,
                        (m.modifiers & Qt.ShiftModifier) !== 0,
                        (m.modifiers & Qt.ControlModifier) !== 0);
        if (right) root.openMenuAt(entryRow, m);
      }
      onDoubleClicked: entryRow.opened()
    }

    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: 3
      height: parent.height - 8
      radius: 2
      visible: entryRow.ticked
      color: Zenon.cyan
    }


    Row {
      anchors.fill: parent
      leftPadding: 12
      rightPadding: 12

      Item {
        width: parent.width * (entryRow.showMeta ? 0.54 : 1.0)
        height: parent.height

        Text {
          id: entryGlyph
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          // A fixed COLUMN, not the glyph's own width. The nerd font is
          // proportional, so a wide icon and a narrow one ended the glyph at
          // different places and the name followed — which made the gap read
          // as cramped after the wide ones and left the names ragged down the
          // list. A column of constant width fixes both: the icons sit on one
          // centre line and every name starts at the same x.
          width: Math.round(24 * root.zoom)
          horizontalAlignment: Text.AlignHCenter
          text: entryRow.entry ? entryRow.entry.glyph : ""
          color: entryRow.rowInk
          opacity: entryRow.dim ? 0.65 : 1
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: Math.round(19 * root.zoom)
        }

        Text {
          anchors.left: entryGlyph.right
          anchors.leftMargin: 12
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          text: entryRow.entry
            ? entryRow.entry.name + (entryRow.entry.isLink ? " →" : "") : ""
          elide: Text.ElideMiddle
          color: entryRow.rowInk
          // The leading dot already says a file is hidden. Dimming it as well
          // said it twice and made half of ~ harder to read for nothing.
          opacity: entryRow.dim ? 0.65 : 1
          font.family: "JetBrainsMono Nerd Font Propo"
          font.weight: entryRow.current ? Font.Bold : Font.Medium
          font.pixelSize: Math.round(18 * root.zoom)
        }
      }

      Text {
        width: parent.width * 0.18
        height: parent.height
        visible: entryRow.showMeta
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        rightPadding: 14
        text: !entryRow.entry ? ""
          : (entryRow.entry.isDir ? "—" : Janus.formatSize(entryRow.entry.size))
        color: Zenon.muted
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: Math.round(16 * root.zoom)
      }

      Text {
        width: parent.width * 0.24
        height: parent.height
        visible: entryRow.showMeta
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: entryRow.entry ? Janus.formatTime(entryRow.entry.mtime) : ""
        color: Zenon.muted
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: Math.round(16 * root.zoom)
      }
    }
  }

  // ── a scrollbar you can actually grab ───────────────────────────────────
  // The rest of the shell wears a 3px position REPORT — right for a popup
  // where the wheel is the only thing that scrolls. A folder of thumbnails is
  // a different problem: it can be hundreds of tiles deep, and dragging to the
  // middle of it beats forty flicks of the wheel.
  //
  // Takes its target as a PROPERTY rather than reaching for an id, because an
  // inline component cannot see the ids of the document that declares it.
  //
  // It hides itself when everything already fits, so attaching one to a view
  // costs nothing in the common case of a short directory.
  component ScrollRail: Item {
    id: rail
    required property Flickable target
    // false while its view is not the one on screen
    property bool on: true

    // how far there is left to scroll; 0 when it all fits
    readonly property real over: Math.max(0, rail.target.contentHeight - rail.target.height)
    readonly property bool needed: rail.over > 0
    readonly property real thumbH: rail.needed
      ? Math.max(28, rail.height * (rail.target.height / rail.target.contentHeight))
      : 0
    // how far the thumb's top can travel
    readonly property real span: Math.max(0, rail.height - rail.thumbH)

    width: 10
    visible: rail.on && rail.needed
    // never eat a click when there is nothing to scroll
    enabled: rail.visible

    Rectangle {
      anchors.fill: parent
      anchors.topMargin: 2
      anchors.bottomMargin: 2
      radius: width / 2
      color: Zenon.msgBorder
      opacity: railArea.containsMouse || railArea.dragging ? 0.30 : 0.0
      Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
    }

    Rectangle {
      id: thumb
      x: (rail.width - width) / 2
      width: railArea.containsMouse || railArea.dragging ? 6 : 4
      height: rail.thumbH
      radius: width / 2
      color: Zenon.keyInk
      opacity: railArea.dragging ? 0.90 : (railArea.containsMouse ? 0.70 : 0.40)
      // a binding, never written to: dragging moves contentY and the thumb
      // follows from it, so the bar can never disagree with the view
      y: rail.needed ? (rail.target.contentY / rail.over) * rail.span : 0
      Behavior on width { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
      Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
    }

    // One MouseArea over the whole rail rather than one on the thumb: a click
    // on the empty track should jump there too, and hit-testing a 4px thumb
    // with a pointer is a game nobody wants to play.
    MouseArea {
      id: railArea
      anchors.fill: parent
      hoverEnabled: true
      // The rail lies OVER a Flickable, and a Flickable steals the mouse grab
      // as soon as it decides a press has become a flick — so a drag down the
      // bar was handed to the view mid-stroke and the thumb stopped following
      // the pointer. preventStealing keeps the grab here for the whole press.
      preventStealing: true
      // where in the thumb it was grabbed, so the point under the pointer
      // stays under the pointer; -1 when not dragging
      property real grab: -1
      readonly property bool dragging: railArea.grab >= 0

      function scrollTo(y) {
        if (rail.span <= 0) return;
        const cy = (y / rail.span) * rail.over;
        rail.target.contentY = Math.max(0, Math.min(rail.over, cy));
      }

      onPressed: (m) => {
        const top = thumb.y;
        if (m.y >= top && m.y <= top + rail.thumbH) {
          railArea.grab = m.y - top;
        } else {
          // clicked the bare track: take the thumb by its middle and go there
          railArea.grab = rail.thumbH / 2;
          railArea.scrollTo(m.y - railArea.grab);
        }
      }
      onReleased: railArea.grab = -1
      onCanceled: railArea.grab = -1
      onPositionChanged: (m) => {
        if (!railArea.dragging) return;
        railArea.scrollTo(m.y - railArea.grab);
      }
    }
  }

  component SideHead: Item {
    id: sideHead
    property string label: ""
    // The room above a heading separates it from the group BEFORE it, so the
    // first one does not want any — it would just be a gap under the
    // breadcrumb with nothing on the other side of it to separate from.
    property bool first: false
    width: parent ? parent.width : 0
    height: visible ? (sideHead.first ? 22 : 34) : 0

    Text {
      id: sideHeadText
      anchors.left: parent.left
      anchors.leftMargin: 14
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 6
      text: sideHead.label
      color: Zenon.muted
      font.family: "JetBrainsMono Nerd Font Propo"
      font.weight: Font.Bold
      font.pixelSize: 11
      // Tracked out, the way small caps want to be. At 11px a bold word reads
      // as a smudge; the spacing is what makes it read as a label.
      font.letterSpacing: 1.2
    }

    // a hairline carrying the heading across the column, so the group reads as
    // a group without needing a heavier label to say so
    Rectangle {
      anchors.left: sideHeadText.right
      anchors.leftMargin: 10
      anchors.right: parent.right
      anchors.rightMargin: 14
      anchors.verticalCenter: sideHeadText.verticalCenter
      height: 1
      color: Zenon.msgBorder
    }
  }

  // One row of the sidebar: a bookmark or a disk. The disk half adds the mount
  // switch on the right, because "go there" and "make it possible to go there"
  // are two different actions and a single click cannot be both.
  component SideRow: Item {
    id: sideRow
    property string label: ""
    property string detail: ""
    property string glyph: ""
    property bool active: false
    property bool mounted: false
    property bool showMount: false

    // 0..1 for a mounted disk, -1 when there is nothing to show a gauge from
    property real used: -1

    signal chosen()
    signal removed()
    signal toggledMount()

    height: 32

    Rectangle {
      anchors.fill: parent
      color: sideRow.active ? Zenon.selBg
        : (sideHover.hovered ? Zenon.hoverTint : "transparent")
    }

    // The active row gets a bar rather than only a fill — the same mark the
    // listing puts on a selected file, so "this is the one" reads the same way
    // in both halves of the window.
    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: 3
      height: parent.height - 10
      radius: 2
      visible: sideRow.active
      color: Zenon.cyan
    }
    HoverHandler { id: sideHover }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      cursorShape: Qt.PointingHandCursor
      onClicked: (m) => {
        if (m.button === Qt.MiddleButton) sideRow.removed();
        else sideRow.chosen();
      }
    }

    Text {
      id: sideGlyph
      anchors.left: parent.left
      anchors.leftMargin: 12
      anchors.verticalCenter: parent.verticalCenter
      // A fixed column, for the same reason the listing's glyphs got one: the
      // nerd font is proportional, so a wide icon and a narrow one ended their
      // labels at different places and the names came out ragged.
      width: 20
      horizontalAlignment: Text.AlignHCenter
      text: sideRow.glyph
      color: sideRow.active ? Zenon.cyan : Zenon.muted
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 14
    }

    // The name and the figure are TWO items, not one string.
    //
    // They were concatenated — "nvme0n1p8  855.7G free" in a single Text — so
    // a long disk label pushed the figure off the end and elided away the one
    // part you were looking for. Separated, the name gives up its own width
    // and the figure always survives.
    Text {
      id: sideLabel
      anchors.left: sideGlyph.right
      anchors.leftMargin: 8
      anchors.right: sideDetail.visible ? sideDetail.left : (mountBtn.visible
        ? mountBtn.left : sideRow.right)
      anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: sideRow.used >= 0 ? -4 : 0
      text: sideRow.label
      elide: Text.ElideMiddle
      color: sideRow.active ? Zenon.white : Zenon.keyInk
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 14
    }

    Text {
      id: sideDetail
      anchors.right: mountBtn.visible ? mountBtn.left : parent.right
      anchors.rightMargin: mountBtn.visible ? 8 : 12
      anchors.verticalCenter: sideLabel.verticalCenter
      visible: sideRow.detail !== ""
      text: sideRow.detail
      color: Zenon.muted
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 12
    }

    // How full it is, under the name it belongs to. A figure tells you how much
    // is left; a bar tells you whether that is a lot — and which of three
    // disks is the one filling up. Only for a mounted filesystem, because an
    // unmounted one reports no figures and a bar drawn from a guess would be
    // worse than none.
    Rectangle {
      id: gaugeTrough
      anchors.left: sideGlyph.right
      anchors.leftMargin: 8
      anchors.right: mountBtn.visible ? mountBtn.left : parent.right
      anchors.rightMargin: mountBtn.visible ? 8 : 12
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 6
      height: 2
      radius: 1
      visible: sideRow.used >= 0
      color: Zenon.trough(Zenon.cyan)

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width * sideRow.used
        radius: 1
        // Nearly full is worth saying in colour rather than making you read
        // the number and do the arithmetic.
        color: sideRow.used > 0.95 ? Zenon.red
          : (sideRow.used > 0.85 ? Zenon.yellow : Zenon.cyan)
      }
    }

    Text {
      id: mountBtn
      anchors.right: parent.right
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      visible: sideRow.showMount
      // eject when it is mounted, mount when it is not — the glyph is the
      // action the click performs, not the state it is in
      text: sideRow.mounted ? "\uF052" : "\uF0AB"
      color: mountHov.hovered ? Zenon.cyan
        : (sideRow.mounted ? Zenon.green : Zenon.muted)
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 13

      HoverHandler { id: mountHov }
      MouseArea {
        anchors.fill: parent
        anchors.margins: -6
        cursorShape: Qt.PointingHandCursor
        onClicked: sideRow.toggledMount()
      }
    }
  }

  // A column label that sorts, which is the only header behaviour this window
  // has. The caret marks the active column, the same way zeus' does.
  component ColHead: Item {
    id: head
    property string label: ""
    property string sortKey: ""
    property bool rightAlign: false
    // Matched to the DATA cell this names, not assumed. The size column keeps
    // a 14px gutter before the modified column; the modified column is the
    // last one and sits flush. A single hard-coded pad here put MODIFIED 14px
    // to the left of the times underneath it, which read as centred.
    property real padRight: 14
    height: 22

    Text {
      anchors.fill: parent
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: head.rightAlign ? Text.AlignRight : Text.AlignLeft
      rightPadding: head.rightAlign ? head.padRight : 0
      text: root.sortKey === head.sortKey
        ? head.label + (root.sortDesc ? " ▾" : " ▴") : head.label
      color: root.sortKey === head.sortKey ? Zenon.cyan
        : (headMa.containsMouse ? Zenon.keyInk : Zenon.muted)
      font.family: "JetBrainsMono Nerd Font"
      font.pixelSize: 11
    }

    MouseArea {
      id: headMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (root.sortKey === head.sortKey) root.sortDesc = !root.sortDesc;
        else { root.sortKey = head.sortKey; root.sortDesc = false; }
      }
    }
  }


}
