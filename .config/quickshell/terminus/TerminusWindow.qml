// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// TERMINUS — the file manager. God of boundaries, and of the stones that mark
// them: a directory is a boundary, a path is a line drawn between two of them,
// and the divider down the middle of a split view is the stone itself.
//
// It was called janus while it had one pane and two faces to look at it with.
// It has two panes now, so the boundary is the point.
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
//     windowrulev2 = float, title:^(terminus)$
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
import "terminus.js" as Terminus
import "icons.js" as Icons
import "../morpheus/thumbs.js" as Thumbs

FloatingWindow {
  id: root

  // A DIALOG IS NOT THE FILE MANAGER, and the window rules say so:
  //
  //     windowrulev2 = float, title:^(terminus)$          1000x1000
  //     windowrulev2 = float, title:^(terminus-picker)$   1000x450
  //
  // Both windows answered to "terminus", so the picker took the file manager's
  // rule and came up square. It has its own name whenever a portal request is
  // what put it on screen — which is set before `shown`, so the title is
  // already right when the surface is mapped and the rule is applied.
  title: root.picking ? "terminus-picker" : "terminus"
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

  // ── the menu key ──────────────────────────────────────────────────────
  // The keyboard's own way of asking what the right button asks, about the row
  // the CURSOR is on — which is already the row the menu acts on. `menu.target`
  // is `root.currentRow()`, never a hit test against the pointer; right-click
  // only looks like it is about the row under the mouse because clickRow()
  // moves the cursor there first. So this needs no target plumbing at all,
  // only somewhere to put the card.
  //
  // The row has to be REALISED before the view will hand back its delegate, so
  // the cursor is scrolled into view first and the placing waits a tick — the
  // same shape as positionSel's other callers.
  function openMenuAtCursor() {
    // An empty directory has no row to ask about, so ask about the directory
    // instead: the row branch of the menu returns nothing without a target,
    // and an empty card is worse than the one that has something in it.
    if (root.view.length === 0 || !root.currentRow()) {
      menu.openHere(content, { x: content.width / 2, y: content.height / 3 });
      return;
    }
    root.positionSel();
    Qt.callLater(root._placeMenuAtCursor);
  }

  function _placeMenuAtCursor() {
    const v = root.viewMode === "grid" ? grid
            : root.viewMode === "columns" ? midList : list;
    const it = v ? v.itemAtIndex(root.sel) : null;
    // From the row's bottom-left, so the card drops out of the row the way a
    // menu drops out of the thing it belongs to. menuCard clamps itself inside
    // the window, so a row near the bottom pulls it back up on its own.
    if (it) menu.openAt(it, { x: 0, y: it.height });
    // A row the view still has not built — it can refuse even after
    // positionSel if the listing changed underneath. The menu is about the
    // cursor either way, so it opens against the view rather than not at all.
    else if (v) menu.openAt(v, { x: 0, y: 0 });
  }
  function setSaveName(n) { saveField.text = n; }
  readonly property bool hasFocus: content.activeFocus

  // Zenon.layerBg's colour at Zenon.layerBg's alpha, until the settings panel
  // says otherwise — see winAlpha.
  color: Qt.rgba(Zenon.layerBg.r, Zenon.layerBg.g, Zenon.layerBg.b, root.winAlpha)
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
  // copying in one terminus and pasting in another is the same gesture it always
  // was. A binding rather than a copy, so both windows' status lines and menus
  // notice the moment either of them yanks. Written through setPending.
  readonly property var pending: root.mgr ? root.mgr.clipboard : null

  // The rows a pending CUT will take away, as a set.
  //
  // A copy leaves everything where it is, so it says nothing about the rows it
  // came from; a cut is a promise to remove them, and until it is paid the
  // listing was showing them exactly as solid as the files that are staying.
  // EntryRow has carried an unused `dim` for exactly this since it was
  // written.
  readonly property var cutSet: {
    const m = ({});
    const p = root.pending;
    if (p && p.op === "move")
      for (let i = 0; i < p.paths.length; ++i) m[p.paths[i]] = true;
    return m;
  }
  function setPending(v) { if (root.mgr) root.mgr.clipboard = v; }
  property string status: ""

  // ── watching the directory ──────────────────────────────────────────────
  // Until now the listing only changed when TERMINUS changed it: navigate, or
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
    // The anchor is a row INDEX, and the rows are about to be different ones.
    root.endVisual();
    // before anything else: how this directory was left is part of arriving
    // in it, and applying it after the listing has drawn is a visible flip
    root.applyDirView();
    root.watch();
    // one handler per signal: remembering the open tabs lives here too
    viewSave.restart();
  }
  onSearchModeChanged: root.watch()
  onShownChanged: {
    root.visible = root.shown;
    root.watch();
  }

  // ── how each directory likes to be looked at ────────────────────────────
  // A pictures folder wants the grid and a source tree wants the list, and
  // having to say so every time you walk between them is the sort of small
  // repeated cost a file manager should absorb. So the view and the zoom are
  // remembered PER DIRECTORY: change either while standing somewhere, and
  // coming back puts it the way you left it.
  //
  // A directory nobody has expressed an opinion about simply keeps whatever
  // the last one used, which is the old behaviour — so this only ever adds a
  // memory, never a surprise.
  //
  // Capped, and oldest-first, because this rides along in the preferences file
  // and a map that only ever grows would be an unbounded write on every save.
  property var dirViews: ({})
  property var dirViewOrder: []
  readonly property int dirViewCap: 300

  // ...and whether to do it at all.
  //
  // It is the kind of helpfulness that is either exactly right or quietly
  // maddening: a folder of photographs opening as thumbnails is the point,
  // and a view that changes as you walk a tree when you wanted one view
  // everywhere is the same feature being wrong. The map is kept either way —
  // turning it off stops it being written and stops it being applied, so
  // turning it back on returns the memory rather than starting again.
  property bool perDirView: true

  // Guards the round trip, and it is a DEPTH rather than a flag.
  //
  // applyDirView writes viewMode and the zooms, whose own handlers call
  // rememberView — which would write the very entry being read. A bool was
  // enough for that and wrong for everything since: exchangePanes sets it,
  // then changes cwd, whose handler calls applyDirView, which set it again and
  // then cleared it — releasing a guard its caller was still standing behind,
  // and applying the destination directory's view in the middle of a pane
  // swap. That is what made stepping between two panes with two different
  // views rearrange both of them.
  //
  // Counted, so an inner guard cannot end an outer one. Nothing terminus writes
  // to itself is recorded as a preference while this is above zero.
  property int applyDepth: 0
  readonly property bool applyingDirView: root.applyDepth > 0

  function rememberView() {
    if (!root.perDirView) return;
    if (root.applyingDirView || root.cwd === "" || root.picking) return;
    const m = root.dirViews;
    const o = root.dirViewOrder.slice();
    if (m[root.cwd] === undefined) o.push(root.cwd);
    m[root.cwd] = { view: root.viewMode, zoom: root.zoom,
                    thumbZoom: root.thumbZoom };
    while (o.length > root.dirViewCap) delete m[o.shift()];
    root.dirViews = m;
    root.dirViewOrder = o;
    viewSave.restart();
  }

  function applyDirView() {
    if (!root.perDirView) return;
    // Already inside something terminus is doing to itself — a pane exchange, a
    // tab load — so the directory's own preference is not what is wanted.
    if (root.applyDepth > 0) return;
    const v = root.dirViews[root.cwd];
    if (!v) return;
    root.applyDepth++;
    if (root.viewRing.indexOf(v.view) >= 0) root.viewMode = v.view;
    const z = Number(v.zoom);
    if (!isNaN(z) && z > 0) root.zoom = root.zoomClamp(z);
    const tz = Number(v.thumbZoom);
    if (!isNaN(tz) && tz > 0) root.thumbZoom = root.zoomClamp(tz);
    root.applyDepth--;
  }

  // ── the second pane ─────────────────────────────────────────────────────
  // Optional, and off by default: terminus is a one-pane file manager that can
  // become a two-pane one, not the other way round.
  //
  // The trick is that there is still only ONE pane's worth of live state. The
  // active side is the window — cwd, rows, sel, marks, filter, history, the
  // lot, exactly as before — and the other side is a listing and a cursor and
  // nothing else. `o` SWAPS them, which is the same move switchTab makes
  // between tabs, so both sides get the full window in turn and neither needs
  // a second copy of every property in this file.
  //
  // What that buys: no branch in any existing key, verb or view. What it
  // costs: the inactive side cannot be filtered or marked until you step into
  // it, which is what stepping into it is for.
  property bool dual: false
  property string otherCwd: ""
  property int otherSel: 0
  // Raw, as the listing came back. The sort and the hidden-file setting are
  // applied by the binding below rather than baked in here, so changing either
  // rearranges both panes at once instead of only the one you are standing in.
  property var otherRaw: []
  readonly property var otherRows: root.enrich(Terminus.sortEntries(
    Terminus.filterEntries(root.otherRaw, "", root.showHidden),
    root.sortKey, root.sortDesc))

  // WHICH HALF the active pane occupies: 0 left, 1 right.
  //
  // Without this, `o` swapped the two directories between the sides and the
  // active pane was always the left one — so pressing it made the contents
  // jump across the window, and a border marking "the live side" would have
  // been a border that never moved. With it, the exchange and the flip happen
  // together: the state moves one way, the side it is drawn on moves the
  // other, and the visible result is that the contents stay exactly where they
  // are while the focus crosses over. Which is what Tab is expected to do.
  property int paneSide: 0

  // What each SIDE was last looking at.
  //
  // The view belongs to the half of the window, not to the state that happens
  // to be in it. Without this, stepping across carried the active pane's view
  // with it — a grid jumped the divider and the list came the other way, so
  // both panes changed shape for a keystroke that was only meant to move the
  // keyboard. Index 1 starts as a list because the inactive side is always
  // drawn as one.
  property var paneViews: ["columns", "list"]

  // What the INACTIVE side is showing. Its own view, not a copy of the active
  // pane's and not a plain list it gets demoted to: stepping across must leave
  // both halves looking exactly as they did.
  // TOTAL, on purpose: grid or list and nothing else. The stored value can be
  // "columns" — from a session before there were two panes, or from a tab
  // saved while there was only one — and a third answer here rendered neither
  // view, which is a pane that goes blank the moment you step out of it.
  readonly property string otherViewMode:
    root.paneViews[root.paneSide === 0 ? 1 : 0] === "grid" ? "grid" : "list"

  // and the same for the thumbnail zoom, so two grids can be at two sizes and
  // stepping across does not resize either of them
  property var paneZooms: [1.0, 1.0]
  readonly property real otherThumbZoom:
    root.paneZooms[root.paneSide === 0 ? 1 : 0] || 1.0

  // Where the divider sits, as a FRACTION of the body rather than a pixel
  // count, so resizing the window keeps the proportion you chose instead of
  // pinning one pane to a width and giving every new pixel to the other.
  property real paneFrac: 0.5
  readonly property real paneMinFrac: 0.15
  readonly property real paneMaxFrac: 0.85

  // The divider's x, and the two halves either side of it.
  readonly property real paneSplit: Math.floor(bodyBox.width * root.paneFrac)
  readonly property real leftPaneW: root.paneSplit
  readonly property real rightPaneW: Math.max(0, bodyBox.width - root.paneSplit - 1)

  readonly property real activePaneW: !root.dual ? bodyBox.width
    : (root.paneSide === 0 ? root.leftPaneW : root.rightPaneW)
  readonly property real activePaneX: !root.dual ? 0
    : (root.paneSide === 0 ? 0 : root.paneSplit + 1)
  readonly property real otherPaneW:
    root.paneSide === 0 ? root.rightPaneW : root.leftPaneW
  readonly property real otherPaneX:
    root.paneSide === 0 ? root.paneSplit + 1 : 0

  Process {
    id: otherProc
    // A directory that has gone since the window was last open — an unmounted
    // disk, a deleted download — falls back to home rather than leaving the
    // pane blank with nothing to say for itself. `find` exits non-zero on a
    // path that is not there, which is the whole test. Guarded against home
    // itself so a failure there cannot loop.
    onExited: (code) => {
      if (code === 0 || root.otherCwd === Paths.home()) return;
      root.otherCwd = Paths.home();
      root.otherSel = 0;
      root.refreshOther();
    }
    stdout: StdioCollector {
      id: otherOut
      waitForEnd: true
      onStreamFinished: {
        root.otherRaw = Terminus.parseListing(otherOut.text, root.otherCwd);
        if (root.otherSel >= root.otherRows.length)
          root.otherSel = Math.max(0, root.otherRows.length - 1);
      }
    }
  }

  Timer {
    id: thumbRetry
    interval: 250
    onTriggered: root.makeThumbs()
  }

  function refreshOther() {
    if (!root.dual || root.otherCwd === "") return;
    otherProc.command = ["sh", "-c", Terminus.listCommand(root.otherCwd)];
    otherProc.running = true;
  }

  function toggleDual() {
    if (root.picking) return;   // see loadViewPrefs: a dialog has one pane
    if (root.dual) {
      root.dual = false;
      viewSave.restart();
      return;
    }
    // Opens where you are standing, like a new tab does and for the same
    // reason: you split the window because you want a second view of what is
    // already in front of you.
    if (root.otherCwd === "") root.otherCwd = root.cwd;
    root.dual = true;
    root.demoteColumns();
    root.refreshOther();
    viewSave.restart();
  }

  // Focus the other side: what `o`, Tab and a click over there all do. The
  // state changes hands AND the side it is drawn on flips, so on screen
  // nothing moves except which pane the keyboard is in.
  function stepOver() {
    if (!root.dual) return;
    const from = root.paneSide;
    const to = from === 0 ? 1 : 0;
    const pv = root.paneViews.slice();
    pv[from] = root.viewMode;
    root.paneViews = pv;
    root.exchangePanes();
    root.paneSide = to;
    // The side being stepped INTO keeps the view it had. Guarded like the
    // exchange itself: this is a side changing hands, not a view you chose,
    // so it must not be written back as this directory's preference.
    const pz = root.paneZooms.slice();
    pz[from] = root.thumbZoom;
    root.paneZooms = pz;
    root.applyDepth++;
    // the same total rule as otherViewMode: whatever is stored, the half being
    // stepped into is a grid or a list, never a third thing that draws nothing
    const want = pv[to] === "grid" ? "grid" : "list";
    if (want !== root.viewMode) root.viewMode = want;
    if (pz[to] > 0 && pz[to] !== root.thumbZoom) root.thumbZoom = pz[to];
    root.applyDepth--;
    // Written last and written whole: the handlers are muted while the depth
    // is up, so this is the one statement that decides what each half is.
    pv[to] = want;
    root.paneViews = pv;
    root.paneZooms = pz;
    root.makeThumbs();
  }

  // The two directories change sides and the focus stays where it is. The
  // same exchange, WITHOUT the flip — which is the whole difference.
  function swapSides() {
    if (!root.dual) return;
    root.exchangePanes();
  }

  // The whole second pane, in one function.
  function exchangePanes() {
    if (!root.dual) return;
    // The remembered view belongs to NAVIGATION, not to crossing the divider.
    // Without this guard, stepping into a directory last looked at as a grid
    // flipped the whole pane to a grid under the cursor — Tab is "the other
    // side", not "and rearrange it".
    root.applyDepth++;
    const there = root.otherCwd;
    const thereSel = root.otherSel;
    const theirRows = root.otherRaw;
    // NEITHER SIDE IS RE-LISTED. Both listings are already in hand — one in
    // `rows`, the other in `otherRaw` — so the exchange is four assignments
    // and no process at all.
    //
    // It used to call refresh(true), which meant every step across threw the
    // model away, ran `find`, and rebuilt every delegate from the answer. That
    // is the flicker: a pane emptying and refilling for a keystroke that
    // changed nothing about what is in it.
    root.otherCwd = root.cwd;
    root.otherSel = root.sel;
    root.otherRaw = root.rows;
    root.cwd = there;
    root.rows = theirRows;
    // The byte-identical guard compares against the last listing THIS side
    // read; the rows now on screen came from the other one, so the next real
    // refresh must not be skipped as "unchanged".
    root.lastListing = null;
    // A filter and a set of marks belong to the directory they were made in,
    // exactly as they do when switching tabs.
    root.query = "";
    filterField.text = "";
    root.marked = {};
    root.sel = thereSel;
    root.saveTab();
    // inotify follows the cwd (onCwdChanged), so anything that changes over
    // here while you were over there still arrives on its own.
    root.makeThumbs();
    root.applyDepth--;
  }

  // Step into the other side AT a row: what a click over there means.
  function enterOther(i) {
    if (!root.dual) return;
    root.otherSel = i;
    root.stepOver();
  }

  // F5 and F6, the two keys every dual-pane file manager has had since the
  // eighties. They are the yank buffer and a paste, with the destination
  // pointed at the other side rather than at where you are standing.
  function sendToOther(op) {
    if (!root.dual || root.otherCwd === "") {
      root.status = "no second pane";
      return;
    }
    if (root.otherCwd === root.cwd) {
      root.status = "both panes are here";
      return;
    }
    const rows = root.acting();
    if (rows.length === 0) return;
    root.setPending({ op: op, paths: rows.map((r) => r.path),
                      names: rows.map((r) => r.name) });
    root.pasteDest = root.otherCwd;
    root.paste();
  }

  // Where a paste LANDS. Normally where you are standing; the other pane's
  // directory for the one gesture that deliberately acts somewhere else. It is
  // cleared the moment the job is handed over, so nothing can inherit it.
  property string pasteDest: ""
  readonly property string destDir:
    root.pasteDest !== "" ? root.pasteDest : root.cwd

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
        const found = Terminus.parseDisks(diskOut.text);
        const key = Terminus.diskKey(found);
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
      diskProc.command = ["sh", "-c", Terminus.disksCommand()];
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
        diskProc.command = ["sh", "-c", Terminus.disksCommand()];
        diskProc.running = true;
      }
    }
  }

  function mountDisk(d) {
    mountProc.command = ["sh", "-c", d.mount === ""
      ? Terminus.mountCommand(d.path) : Terminus.unmountCommand(d.path)];
    mountProc.running = true;
  }

  // ── how big a folder really is ──────────────────────────────────────────
  // The listing shows a dash for a directory, because a directory's own size
  // is the size of its record and never the number anybody means. `z` asks for
  // the real one, and the answer replaces the dash for as long as the window
  // is open.
  //
  // On demand, and it has to be: `du` over a home directory is a walk of every
  // inode under it, which is seconds of disk for a column nobody had asked
  // about. Measured folders are remembered by path, so the answer survives
  // walking away and coming back.
  property var dirSizes: ({})

  Process {
    id: duProc
    stdout: StdioCollector {
      id: duOut
      waitForEnd: true
      onStreamFinished: {
        const got = Terminus.parseDirSizes(duOut.text);
        const next = Object.assign({}, root.dirSizes, got);
        root.dirSizes = next;
        const n = Object.keys(got).length;
        // In the usage view the bars ARE the report, and a line reading
        // "measured 22" left over from the directory before this one is just
        // a wrong caption under a right picture.
        if (root.usage) {
          root.status = "";
          // whatever this batch could not reach, and anything listed since it
          // started — see measureAll's note about being busy
          Qt.callLater(root.measureAll);
        } else {
          root.status = n === 0 ? "could not measure"
            : (n === 1 ? "measured" : "measured " + n);
        }
      }
    }
  }

  // ── disk usage ──────────────────────────────────────────────────────────
  //
  // ncdu's question, asked without leaving the directory you are in: what in
  // here is actually taking up the room. Everything it needs already existed —
  // `du` and its parser, the recursive sizes cache, the sort — so the mode is
  // mostly a matter of measuring every directory instead of the selected one
  // and drawing the answer as a length rather than only as a number.
  property bool usage: false
  // What the mode overrides, so leaving it puts things back rather than
  // leaving you in an order and a view you did not choose.
  property string usagePrevSort: ""
  property bool usagePrevDesc: false
  property string usagePrevView: ""

  // The measured size of a row: a walked directory, or a file, which is
  // already its own whole answer. Undefined until du has been round.
  function usageOf(r) {
    if (!r) return 0;
    if (!r.isDir) return r.size;
    const v = root.dirSizes[r.path];
    return v === undefined ? 0 : v;
  }

  // The biggest thing on screen, which is what every bar is drawn against.
  readonly property real usageMax: {
    if (!root.usage) return 0;
    // The array in a LOCAL. `root.view` is a QML property, and reading it in
    // the loop condition and again in the body is two property lookups per
    // row — on a four-thousand-entry directory, eight thousand of them every
    // time a measurement lands.
    const v = root.view;
    let m = 0;
    for (let i = 0; i < v.length; ++i) {
      const b = root.usageOf(v[i]);
      if (b > m) m = b;
    }
    return m;
  }

  function toggleUsage() {
    root.usage = !root.usage;
    if (root.usage) {
      root.usagePrevSort = root.sortKey;
      root.usagePrevDesc = root.sortDesc;
      root.usagePrevView = root.viewMode;
      root.sortKey = "usage";
      root.sortDesc = true;
      root.duTried = ({});
      // A FRESH ANSWER, because that is what turning the mode on is asking
      // for. Sizes are cached by path and outlive the listing, which is right
      // for navigating — but a folder measured an hour and several downloads
      // ago would be reported here as though it were current.
      root.dirSizes = ({});
      // The column this mode is about only exists in the list. Toggling it in
      // the grid would reorder tiles that show no sizes, which reads as
      // nothing having happened.
      if (root.viewMode !== "list") root.viewMode = "list";
      root.measureAll();
    } else {
      root.sortKey = root.usagePrevSort !== "" ? root.usagePrevSort : "name";
      root.sortDesc = root.usagePrevDesc;
      if (root.usagePrevView !== "" && root.usagePrevView !== root.viewMode)
        root.viewMode = root.usagePrevView;
      root.status = "";
    }
  }

  // Every directory here, not just the selected one — the mode is a picture of
  // the whole directory and a picture with holes in it is worse than none.
  // Already-measured folders are skipped: dirSizes outlives the listing, so
  // coming back to a directory you have already looked at costs nothing.
  // Paths du has already been asked about, so one it cannot answer for — a
  // directory that is not readable — is asked once and then left alone.
  // Without this the retry below would ask about it forever.
  property var duTried: ({})

  function measureAll() {
    if (!root.usage) return;
    // Busy is not the same as done. This used to just give up, and since the
    // only caller was the listing, nothing ever came back to it: walk into a
    // directory while the previous one is still being measured and its folders
    // kept their dashes for as long as the window stayed open. The retry now
    // lives in duProc's completion, so being busy costs a wait rather than the
    // whole answer.
    if (duProc.running) return;
    const tried = root.duTried;
    const sizes = root.dirSizes;
    const todo = root.rows.filter((r) => r.isDir
      && sizes[r.path] === undefined && tried[r.path] !== true);
    if (todo.length === 0) { root.status = ""; return; }
    const next = Object.assign({}, tried);
    for (const r of todo) next[r.path] = true;
    root.duTried = next;
    root.status = "measuring " + todo.length
      + (todo.length === 1 ? " directory\u2026" : " directories\u2026");
    duProc.command = ["sh", "-c",
      Terminus.dirSizeCommand(todo.map((r) => r.path))];
    duProc.running = true;
  }

  function measureDirs() {
    const dirs = root.acting().filter((r) => r.isDir);
    if (dirs.length === 0) { root.status = "no directory to measure"; return; }
    if (duProc.running) { root.status = "still measuring\u2026"; return; }
    root.status = "measuring " + (dirs.length === 1 ? dirs[0].name
      : dirs.length + " directories") + "\u2026";
    duProc.command = ["sh", "-c",
      Terminus.dirSizeCommand(dirs.map((r) => r.path))];
    duProc.running = true;
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
  // path -> the thumbnail that exists for it, as the generator REPORTED it.
  //
  // Terminus used to work the filename out itself and assume the batch had made
  // it. Two things were wrong with that: a file that yields no picture — a
  // track with no cover — was marked ready and pointed an Image at a path
  // nothing had written, and the name could only ever be computed by terminus, so
  // Picasso could not find a thumbnail terminus had already made of the same
  // wallpaper. The pool is shared now and the shell names the files; this is
  // what came back. See morpheus/thumbs.js.
  property var thumbFile: ({})
  property var thumbJobs: []

  Process {
    id: thumbProc
    // What the batch actually MADE, not what it was asked for.
    //
    // This used to mark every job it sent, which was near enough true while
    // the jobs were only pictures and videos. Audio broke it: a track with no
    // cover art produces no file, so the preview pointed an Image at a path
    // that was never written and Qt logged "Cannot open" for it on every
    // visit. The batch now prints the source of each thumbnail that exists
    // when it finishes, and only those are marked.
    stdout: StdioCollector {
      id: thumbOut
      waitForEnd: true
      onStreamFinished: {
        root.thumbFile = Object.assign({}, root.thumbFile,
                                       Thumbs.parseMade(thumbOut.text));
      }
    }
    onExited: root.thumbJobs = []
  }

  function makeThumbs() {
    // A batch already running is not a reason to skip: it may have been asked
    // for the OTHER pane's rows, and dropping this request left the pane you
    // just stepped into showing glyphs. Deferred rather than dropped.
    if (thumbProc.running) { thumbRetry.restart(); return; }
    // BOTH panes, because either can be the grid. The second pane's tiles
    // read the same cache and would otherwise sit on their glyphs forever
    // while the pane beside them was full of pictures.
    let want = [];
    if (root.viewMode === "grid") want = want.concat(root.view);
    if (root.dual && root.otherViewMode === "grid")
      want = want.concat(root.otherRows);
    if (want.length === 0) return;
    const jobs = [];
    for (const r of want) {
      if (r.isDir) continue;
      // Audio joins the grid for the same reason it joined the preview: a
      // folder of albums is a folder of covers, and showing eight identical
      // note glyphs is showing nothing. A track without art keeps its glyph.
      const kind = Terminus.isVideo(r.name) ? "v"
        : (Terminus.isAudio(r.name) ? "a" : (Terminus.isImage(r.name) ? "i" : ""));
      if (kind === "") continue;
      if (root.thumbFile[r.path]) continue;
      jobs.push({ src: r.path, kind: kind });
    }
    if (jobs.length === 0) return;
    root.thumbJobs = jobs;
    thumbProc.command = ["sh", "-c", Thumbs.generate(jobs)];
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
        statProc.command = Terminus.statArgv(paths);
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
        root.rows = root.enrich(Terminus.parseStat(statOut.text));
        root.sel = 0;
        root.status = root.rows.length + " matches";
        Qt.callLater(root.positionSel);
      }
    }
  }

  function search(mode, query) {
    if (query === "") return;
    // WHERE YOU WERE, so Escape can put you back there.
    //
    // Results are a page of their own, not a directory: they come from all
    // over the tree and the cursor lands on whichever of them ranked first.
    // Leaving them used to re-list wherever you happened to be with the cursor
    // wherever the results had left it, so a search you decided against cost
    // you your place. Recorded only on the way IN, so refining a search twice
    // still returns to where the first one started.
    if (root.searchMode === "") {
      const r = root.currentRow();
      root.searchBackCwd = root.cwd;
      root.searchBackSel = r ? r.path : "";
    }
    root.searchMode = mode;
    root.searchQuery = query;
    root.rows = [];
    root.status = "searching…";
    searchProc.command = ["sh", "-c", mode === "grep"
      ? Terminus.grepCommand(root.cwd, query)
      : Terminus.findCommand(root.cwd, query)];
    searchProc.running = true;
  }

  property string searchBackCwd: ""
  property string searchBackSel: ""

  function clearSearch() {
    if (root.searchMode === "") return;
    root.searchMode = "";
    root.searchQuery = "";
    const backCwd = root.searchBackCwd;
    const backSel = root.searchBackSel;
    root.searchBackCwd = "";
    root.searchBackSel = "";
    if (backSel !== "") root.wantSel = backSel;
    // THE STALE-LISTING GUARD HAS TO BE STOOD DOWN FIRST.
    //
    // Results replace `root.rows` without touching `lastListing`, so after a
    // search that guard still holds the text of the directory you searched
    // FROM. Escaping out of results re-lists that same directory, the output
    // matches byte for byte, and the "nothing changed" early return leaves the
    // RESULTS on screen — so Escape appeared to do nothing but drop the WHERE
    // column. null can never be a listing, which is the whole reason it is the
    // sentinel.
    root.lastListing = null;
    // A result you opened may have moved you somewhere else entirely, so this
    // is a navigation back rather than a re-listing of wherever you are.
    if (backCwd !== "" && backCwd !== root.cwd) root.enter(backCwd);
    else root.refresh(true);
  }

  // ── tabs ────────────────────────────────────────────────────────────────
  // `cwd` and `sel` stay the live values rather than being read out of the tab
  // array, because every binding in this window already reads them. A switch
  // saves the pair into the tab being left and loads the pair from the tab
  // being entered — so tabs cost one array and two assignments, and nothing
  // downstream has to know they exist.
  property var tabs: [{ cwd: Paths.home(), sel: 0, dual: false, otherCwd: "",
                       otherSel: 0, paneSide: 0, view: "columns" }]
  property int tab: 0

  // Whether the tabs come back at all. Some people want the file manager to
  // open where they left it and some want it to open clean every time, and
  // neither is wrong — so it is a switch rather than a decision made here.
  //
  // Only the RESTORE is gated — the tabs go on being recorded either way, so
  // switching this back on takes effect from the session you are in rather
  // than needing one more restart before it has anything to remember. It does
  // mean the session saved before you turned it off is written over by the
  // next one, which is the right way round: what comes back should be where
  // you actually were last, not where you were the last time you happened to
  // have the setting on.
  property bool sessionReplay: true

  // `tabs` only learns the current tab's cwd when you switch away from it, so
  // the live one is folded in here rather than trusting the stored copy.
  // Everything a tab is, in one object.
  //
  // A tab used to be a directory and a cursor, which was the whole of a pane's
  // state at the time. It is not any more: the second pane, which side the
  // keyboard is on and what each side is looking at all belong to the tab as
  // well, because a tab is meant to be a separate window — split in one and a
  // single pane in the next, neither disturbing the other.
  function tabState() {
    return {
      cwd: root.cwd,
      sel: root.sel,
      // The listing itself travels with the tab. Without it every switch threw
      // the model away and ran `find` again, so a tab emptied and refilled for
      // a keystroke that changed nothing about what was in it — the flicker,
      // and the same one the pane exchange had.
      rows: root.rows,
      // and the bytes they were parsed from, so the refresh that follows a
      // switch can recognise an unchanged directory and leave the model alone.
      // Restoring the rows without this only moved the flicker later: the
      // guard compares against the last listing THIS side read, which would
      // have been the other tab's, so every switch counted as a change and
      // rebuilt every delegate anyway.
      listing: root.lastListing,
      dual: root.dual,
      otherCwd: root.otherCwd,
      otherSel: root.otherSel,
      otherRaw: root.otherRaw,
      paneSide: root.paneSide,
      paneViews: root.paneViews.slice(),
      paneZooms: root.paneZooms.slice(),
      view: root.viewMode
    };
  }

  // Put a saved tab back on screen. `otherRaw` travels with it so stepping
  // between tabs does not re-list a directory that was already listed —
  // refreshOther catches anything that changed while it was away.
  function loadTab(t) {
    if (root.renaming) root.endRename(false);
    root.dual = t.dual === true;
    root.otherCwd = typeof t.otherCwd === "string" ? t.otherCwd : "";
    root.otherSel = t.otherSel || 0;
    root.otherRaw = t.otherRaw || [];
    root.paneSide = t.paneSide === 1 ? 1 : 0;
    if (t.paneViews && t.paneViews.length === 2) root.paneViews = t.paneViews.slice();
    root.demoteColumns();
    if (t.paneZooms && t.paneZooms.length === 2) root.paneZooms = t.paneZooms.slice();
    root.cwd = t.cwd;
    root.query = "";
    filterField.text = "";
    root.marked = {};
    root.sel = t.sel || 0;
    // Handed back rather than re-read. `lastListing` is cleared with it so the
    // byte-identical guard cannot mistake the next real refresh for a no-op.
    if (t.rows && t.rows.length > 0) {
      root.rows = t.rows;
      root.lastListing = (t.listing === undefined) ? null : t.listing;
    } else {
      root.lastListing = null;
    }
    // The tab's own view, not the destination directory's: arriving in a tab
    // is arriving back where you were, and a tab that rearranged itself on the
    // way in would not be the window you left.
    if (root.viewRing.indexOf(t.view) >= 0) {
      root.applyDepth++;
      root.viewMode = t.view;
      root.applyDepth--;
    }
    // The directory is still re-read, but the rows it had are already on
    // screen while that happens, so nothing blinks.
    root.refresh(true);
    root.refreshOther();
  }

  function tabList() {
    const out = [];
    for (let i = 0; i < root.tabs.length; ++i)
      out.push(i === root.tab ? root.tabState() : root.tabs[i]);
    return out;
  }

  // WHAT A TAB IS WORTH KEEPING, which is not everything a tab is.
  //
  // A tab carries its listings so switching between them costs no process and
  // no rebuild — and those listings have no business in a preferences file.
  // They are a cache of what is on the disk right now, they are megabytes on a
  // deep directory, and they would be rewritten on every debounced save. What
  // survives a restart is where the tab was pointing and how it was set up;
  // the rows come back from the disk, which is where they came from.
  function tabsForDisk() {
    return root.tabList().map((t) => ({
      cwd: t.cwd, sel: t.sel, view: t.view,
      dual: t.dual, otherCwd: t.otherCwd, otherSel: t.otherSel,
      paneSide: t.paneSide, paneViews: t.paneViews, paneZooms: t.paneZooms
    }));
  }

  function saveTab() {
    const next = root.tabs.slice();
    next[root.tab] = root.tabState();
    root.tabs = next;
  }

  onTabsChanged: viewSave.restart()
  onTabChanged: viewSave.restart()

  function switchTab(i) {
    if (i === root.tab || i < 0 || i >= root.tabs.length) return;
    root.saveTab();
    root.tab = i;
    root.loadTab(root.tabs[i]);
  }

  // A NEW TAB IS A NEW WINDOW: one pane, at home. It used to inherit the
  // current tab's directory and its split, which made "give me a clean sheet"
  // impossible — you got another copy of where you already were.
  // `t` opens at home; middle click and the menu entry open at a directory.
  // Both are the same tab, so they are the same function with an argument
  // rather than two that drift apart.
  function newTab(path) {
    root.saveTab();
    const t = root.tabState();
    t.cwd = (path && path !== "") ? path : Paths.home();
    t.sel = 0;
    t.dual = false;
    t.otherCwd = "";
    t.otherSel = 0;
    t.otherRaw = [];
    t.paneSide = 0;
    const next = root.tabs.slice();
    next.push(t);
    root.tabs = next;
    root.tab = next.length - 1;
    root.loadTab(t);
  }

  // A directory in a new tab, leaving this one exactly where it was — which
  // is the whole point of the gesture, so a file (which has no listing to
  // show) is quietly ignored rather than opening a tab onto nothing.
  function openInNewTab(path) {
    if (!path || path === "") return;
    root.newTab(path);
  }

  function closeTab() {
    if (root.tabs.length < 2) return;   // the last tab is just the window
    const next = root.tabs.slice();
    next.splice(root.tab, 1);
    const land = Math.min(root.tab, next.length - 1);
    root.tabs = next;
    root.tab = -1;          // force switchTab to do the load
    root.tab = land;
    root.loadTab(next[land]);
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
  // Eased, so a burst of ctrl-+ is one continuous change of scale rather than
  // a stack of steps. Everything sized off zoom — row height, glyphs, names,
  // the grid's cells — moves together because they all read this one number,
  // which is the whole reason it is one number.
  property real zoom: 1.0
  Behavior on zoom {
    NumberAnimation { duration: Zenon.normal; easing.type: Easing.OutCubic }
  }
  property real thumbZoom: 1.0
  Behavior on thumbZoom {
    NumberAnimation { duration: Zenon.normal; easing.type: Easing.OutCubic }
  }
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

  // Straight to a value, for the settings panel's slider — the keys step, and
  // stepping is the wrong gesture when the whole range is drawn in front of
  // you. Which zoom it lands on follows the same rule zoomBy uses: the grid
  // scales its pictures, everything else scales its text, and the two are
  // deliberately independent.
  function setZoom(v) {
    const z = root.zoomClamp(v);
    if (root.viewMode === "grid") root.thumbZoom = z;
    else root.zoom = z;
    Qt.callLater(root.positionSel);
  }

  // ── bookmarks ───────────────────────────────────────────────────────────
  // Kept in the shell's own state directory, not next to the config: it is
  // something you accumulate by using terminus, not something you write by hand.
  property var bookmarks: []

  FileView {
    id: bookmarkFile
    path: Quickshell.statePath("terminus-bookmarks")
    blockLoading: true
    printErrors: false
    // FileView can watch its own file, which is the one kind of watching
    // quickshell does offer — so a bookmark added in another terminus window,
    // or edited by hand, shows up here without a restart.
    watchChanges: true

    // TWO SIGNALS, AND THEY ARE NOT THE SAME EVENT. This took three goes.
    //
    // `fileChanged` says the file on disk is no longer what we hold. It
    // refreshes nothing by itself, so it has to ask — and `reload()` only
    // QUEUES the read. text() immediately afterwards still answers with the
    // copy we already had, which is what defeated every previous attempt
    // here: a "we are writing" flag that got stuck and swallowed other
    // windows' changes, and then a comparison against the text we last wrote
    // which compared the OLD content against the NEW and concluded it was
    // somebody else's news — so it re-derived the list from the stale bytes
    // and put back the bookmark you had just removed, about a second after
    // you removed it. That was the "not instant".
    //
    // `textChanged` is where the new bytes actually arrive. By then the
    // question "what does the file say" has an answer, and it does not matter
    // who wrote it: our own write lands here too and simply re-derives the
    // array the sidebar is already showing. There is no state left to get
    // stuck, and nothing to compare.
    onFileChanged: bookmarkFile.reload()
    onTextChanged: root.loadBookmarks()
  }

  function loadBookmarks() {
    const raw = String(bookmarkFile.text() || "").split("\n")
      .map((l) => l.trim()).filter((l) => l !== "");
    root.bookmarks = raw;
  }

  function isBookmarked(path) { return root.bookmarks.indexOf(path) >= 0; }

  // Every change goes through here, and it re-reads before it writes.
  //
  // The list is shared by every terminus window, so "what I think it is" is not
  // good enough to base a write on — the copy in hand can be stale, and a
  // read-modify-write on a stale copy silently reverts whatever another window
  // did. Re-reading immediately before mutating makes the last write win on
  // the CURRENT list rather than on an old one.
  function editBookmarks(mutate) {
    // Re-read before mutating, FOR REAL. reload() queues the read and
    // waitForJob() is what blocks until it has landed — without it, the
    // "modify the CURRENT list rather than an old one" this function exists
    // for was operating on exactly the old one it was trying to avoid.
    // Blocking is already the deal here: blockLoading is on, and this is one
    // short line-per-path file.
    bookmarkFile.reload();
    bookmarkFile.waitForJob();
    root.loadBookmarks();
    const next = root.bookmarks.slice();
    mutate(next);
    // In memory first, so the sidebar changes on this frame. The write comes
    // back round through onTextChanged and re-derives the same array.
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

  // What the hint bar should CALL that toggle, which depends on which way it
  // is about to go. A key that does two opposite things should not describe
  // itself with one of them.
  function bookmarkVerb() {
    const r = root.currentRow();
    const onRow = !!(r && r.isDir);
    const path = onRow ? r.path : root.cwd;
    if (root.isBookmarked(path)) return "remove bookmark";
    return onRow ? "bookmark item" : "bookmark this directory";
  }

  // What `b b` acts on: the directory under the cursor if there is one, and
  // otherwise the directory you are standing in. A file cannot be bookmarked —
  // the sidebar navigates to what it lists — so the cursor being on one falls
  // through to the containing directory rather than doing nothing.
  function toggleBookmarkHere() {
    const r = root.currentRow();
    if (r && r.isDir) root.toggleBookmarkFor(r.path);
    else root.toggleBookmark();
  }

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
  // request here over ipc and then waits, and terminus answers by writing the
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
    if (root.portal.directory) return "Choose a directory";
    return root.portal.multiple ? "Choose files" : "Choose a file";
  }

  // What confirming would hand back, so the button can say how many and refuse
  // when there is nothing to give.
  readonly property var portalChoice: {
    if (!root.portal) return [];
    if (root.portal.save) {
      const n = saveField.text;
      return Terminus.nameError(n) === "" ? [Terminus.joinPath(root.cwd, n)] : [];
    }
    if (root.portal.directory) {
      // a marked directory if you marked one, otherwise the one you are
      // standing in — which is what "choose this directory" means
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
      onStreamFinished: props.imageInfo = Terminus.parseImageInfo(imageOut.text)
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
  // MILLER COLUMNS IS A THREE-COLUMN LAYOUT, and two of them side by side is
  // six columns of listing in half a window each. So while the second pane is
  // open the ring is list and grid — the two views that are a single column
  // and therefore mean the same thing at half width. Closing the pane brings
  // columns back.
  readonly property var viewRing: root.dual
    ? ["list", "grid"] : ["columns", "list", "grid"]

  // Whatever was on columns when the second pane opened lands on list. Guarded
  // like every other view written by terminus rather than by you, so it is not
  // recorded as this directory's preference.
  // The active half's entries in paneViews/paneZooms follow what it is
  // showing, so stepping away and back returns to it.
  function syncPaneView() {
    if (!root.dual || root.applyDepth > 0) return;
    if (root.paneViews[root.paneSide] !== root.viewMode) {
      const pv = root.paneViews.slice();
      pv[root.paneSide] = root.viewMode;
      root.paneViews = pv;
    }
    if (root.paneZooms[root.paneSide] !== root.thumbZoom) {
      const pz = root.paneZooms.slice();
      pz[root.paneSide] = root.thumbZoom;
      root.paneZooms = pz;
    }
  }

  function demoteColumns() {
    if (!root.dual) return;
    const pv = root.paneViews.slice();
    let changed = false;
    for (let i = 0; i < 2; ++i)
      if (pv[i] === "columns") { pv[i] = "list"; changed = true; }
    if (changed) root.paneViews = pv;
    if (root.viewMode === "columns") {
      root.applyDepth++;
      root.viewMode = "list";
      root.applyDepth--;
    }
  }

  function cycleView() {
    const i = root.viewRing.indexOf(root.viewMode);
    root.viewMode = root.viewRing[(i + 1) % root.viewRing.length];
    Qt.callLater(root.positionSel);
  }

  // Straight to a named view, for the settings panel's three buttons. `v`
  // cycles, and cycling is the wrong gesture when the thing you want is
  // written on screen in front of you. A view that is not in the ring is
  // REFUSED rather than set and quietly undone — while the window is split,
  // columns is not one of the three, and demoteColumns says why.
  function setView(v) {
    if (root.viewRing.indexOf(v) < 0) return;
    root.viewMode = v;
    Qt.callLater(root.positionSel);
  }

  // ── how solid the window is ─────────────────────────────────────────────
  //
  // Zenon.layerBg is 0xcc black, the ground every layer in this shell sits on,
  // and this is that alpha made adjustable: a file manager is a window you
  // keep open OVER other windows, and how much of them you want to see through
  // it depends on what you are doing rather than on a constant in a palette.
  //
  // Floored well short of nothing. A window you cannot read is not a setting
  // anyone wants, and the slider has no way back once the text is gone.
  property real winAlpha: 0.80
  readonly property real winAlphaMin: 0.35
  function setAlpha(a) {
    if (isNaN(a)) return;
    root.winAlpha = Math.max(root.winAlphaMin, Math.min(1.0, a));
    viewSave.restart();
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
    path: Quickshell.statePath("terminus-view.json")
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
        tabs: root.winId === 0 ? root.tabsForDisk() : undefined,
        tab: root.winId === 0 ? root.tab : undefined,
        view: root.viewMode,
        zoom: root.zoom,
        sidebar: root.sidebar,
        sidebarWidth: root.sidebarWidth,
        thumbZoom: root.thumbZoom,
        sortKey: root.sortKey,
        sortDesc: root.sortDesc,
        usage: root.usage,
        showHidden: root.showHidden,
        winAlpha: root.winAlpha,
        perDirView: root.perDirView,
        sessionReplay: root.sessionReplay,
        dual: root.dual,
        otherCwd: root.otherCwd,
        paneSide: root.paneSide,
        paneViews: root.paneViews,
        paneZooms: root.paneZooms,
        paneFrac: root.paneFrac,
        dirViews: root.dirViews
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
    root.usage = s.usage === true;
    // "usage" is the mode's own sort key and means nothing without the mode.
    // Restoring one without the other would leave the window in an order with
    // no bars and no explanation for it.
    if (typeof s.sortKey === "string" && s.sortKey !== ""
        && (s.sortKey !== "usage" || root.usage))
      root.sortKey = s.sortKey;
    if (typeof s.sortDesc === "boolean") root.sortDesc = s.sortDesc;
    if (typeof s.showHidden === "boolean") root.showHidden = s.showHidden;
    if (typeof s.perDirView === "boolean") root.perDirView = s.perDirView;
    if (typeof s.sessionReplay === "boolean") root.sessionReplay = s.sessionReplay;
    const wa = Number(s.winAlpha);
    if (!isNaN(wa) && wa > 0)
      root.winAlpha = Math.max(root.winAlphaMin, Math.min(1.0, wa));
    // The second pane comes back the way it was left, and its directory with
    // it — but only if that directory still exists, for the same reason the
    // tabs are checked: a pane opening on a removed download is a pane opening
    // on an error.
    if (typeof s.otherCwd === "string") root.otherCwd = s.otherCwd;
    if (s.paneSide === 1) root.paneSide = 1;
    if (s.paneViews && s.paneViews.length === 2)
      root.paneViews = s.paneViews.slice();
    root.demoteColumns();
    if (s.paneZooms && s.paneZooms.length === 2)
      root.paneZooms = s.paneZooms.slice();
    const pf = Number(s.paneFrac);
    if (!isNaN(pf) && pf > 0)
      root.paneFrac = Math.max(root.paneMinFrac, Math.min(root.paneMaxFrac, pf));
    if (s.dirViews && typeof s.dirViews === "object") {
      root.dirViews = s.dirViews;
      root.dirViewOrder = Object.keys(s.dirViews);
    }
    // A PICKER IS NOT A FILE MANAGER. It is a dialog with one job — say which
    // file — and a second pane is a place to put things, which is the one
    // thing it must never be. winId is -1 for the portal's own window and is
    // set before this runs, so the preference is simply not read for it.
    if (root.winId >= 0 && s.dual === true && root.otherCwd !== "") {
      root.dual = true;
      root.refreshOther();
    }
    root.restoreTabs(s);
  }

  // Reopening where you left off, but only the tabs whose directories are still
  // there — a tab pointing at a removed download or an unmounted disk would be
  // a window that opens on an error. Checked by the caller, which is why this
  // hands the surviving list to a process rather than trusting the file.
  function restoreTabs(st) {
    if (root.winId !== 0) return;
    if (!root.sessionReplay) return;
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

  // rememberView restarts the save itself — see how each directory likes to
  // be looked at, above
  onZoomChanged: root.rememberView()
  onThumbZoomChanged: { root.rememberView(); root.syncPaneView(); }
  onSidebarChanged: viewSave.restart()
  onSidebarWidthChanged: viewSave.restart()
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
        const dir = Terminus.dirname(root.cwd);
        root.parentRows = root.enrich(Terminus.sortEntries(
          Terminus.filterEntries(Terminus.parseListing(parentOut.text, dir), "", root.showHidden),
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

  property string previewKind: "none"   // none | dir | image | video | audio | font | pdf | text | archive | binary
  // Where a rendered PDF page lands. One name, reused: only one preview is on
  // screen at a time, so keeping every page ever looked at would be a cache
  // nobody reads. `previewStamp` busts Qt's image cache, which would otherwise
  // show the previous PDF at the same path.
  // Beside the thumbnails, not loose in the cache root: everything terminus
  // renders is one directory, so clearing it is one rm.
  readonly property string pdfStem: Terminus.terminusCacheDir() + "/preview"
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
    // The metadata rides along, because `sel` is not the only thing that
    // changes what is being previewed. Entering a directory whose first row is
    // already the cursor fires no onSelChanged at all — the whole listing
    // changed underneath a cursor that never moved — and the panel came up
    // with a size and a date and no dimensions. Everything that restarts this
    // timer means "the preview is now of something else", which is exactly
    // when the probe has to run too.
    onTriggered: { root.loadPreview(); infoDelay.restart(); }
  }

  // The cache is tried SYNCHRONOUSLY, before the debounce. A row you have
  // already looked at needs no process and no parse, so making it wait 55ms
  // behind a timer that exists to avoid spawning things was the one delay with
  // nothing behind it — walking back up a list is now instant.
  onSelChanged: {
    // Before the early return below: the range follows the cursor in every
    // view, not only the one that draws a preview.
    if (root.visualOn) root.extendVisual();
    if (root.viewMode !== "columns") return;
    const r = root.currentRow();
    // Metadata takes the same shape as the preview itself: the cache answers
    // in the same frame and only a miss waits behind the debounce. Reading it
    // here rather than leaving it all to loadPreviewInfo is what stops the
    // panel blanking for a tenth of a second every time the cursor walks back
    // over a row it has already been on.
    const known = r ? root.infoCache[r.path] : undefined;
    root.previewInfo = known === undefined ? null : known;
    if (known === undefined) infoDelay.restart(); else infoDelay.stop();
    const hit = r ? root.previewCache[r.path] : undefined;
    if (hit !== undefined) {
      previewDelay.stop();
      root.previewKind = hit.kind;
      root.previewRows = hit.rows || [];
      root.previewText = hit.text || "";
      return;
    }
    // an image needs no process either: the pane points Qt at the file
    if (r && !r.isDir && Terminus.isImage(r.name)) {
      previewDelay.stop();
      root.previewKind = "image";
      root.previewRows = [];
      root.previewText = "";
      return;
    }
    previewDelay.restart();
  }
  onViewModeChanged: {
    if (root.viewMode === "columns") { previewDelay.restart(); infoDelay.restart(); }
    else root.previewInfo = null;
    root.rememberView();
    root.syncPaneView();
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
            ? root.enrich(Terminus.sortEntries(
                Terminus.filterEntries(Terminus.parseListing(t, cur.path), "", root.showHidden),
                root.sortKey, root.sortDesc))
            : [];
          root.previewRows = rows;
          if (cur) root.cachePreview(cur.path, { kind: "dir", rows: rows });
        } else if (root.previewKind === "archive") {
          const rich = Terminus.archivePreview(t);
          root.previewText = rich;
          // an unreadable or empty archive is still not text
          if (rich === "") root.previewKind = "binary";
          if (cur) root.cachePreview(cur.path,
            { kind: root.previewKind, text: rich });
        } else if (Terminus.looksBinary(t)) {
          root.previewKind = "binary";
          root.previewText = "";
          if (cur) root.cachePreview(cur.path, { kind: "binary" });
        } else {
          root.previewKind = "text";
          const rich = Terminus.ansiToRich(t);
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
      previewProc.command = ["sh", "-c", Terminus.peekCommand(r.path)];
      previewProc.running = true;
      return;
    }
    if (Terminus.isImage(r.name)) { root.previewKind = "image"; return; }
    if (Terminus.isVideo(r.name)) {
      root.previewKind = "video";
      // the same cached frame the grid uses, made on demand if the grid has
      // not already asked for it
      if (!root.thumbFile[r.path]) {
        root.thumbJobs = [{ src: r.path, kind: "v" }];
        thumbProc.command = ["sh", "-c", Thumbs.generate(root.thumbJobs)];
        thumbProc.running = true;
      }
      return;
    }
    if (Terminus.isAudio(r.name)) {
      root.previewKind = "audio";
      // Cover art, through the same cache and the same batch as a video's
      // frame — it is a picture pulled out of a file either way. A track with
      // no art writes nothing and the panel shows its tags alone.
      if (!root.thumbFile[r.path]) {
        root.thumbJobs = [{ src: r.path, kind: "a" }];
        thumbProc.command = ["sh", "-c", Thumbs.generate(root.thumbJobs)];
        thumbProc.running = true;
      }
      return;
    }
    // A typeface is previewed by BEING the preview: Qt loads the file and the
    // specimen below is drawn with it. Nothing to run, nothing to parse.
    if (Terminus.isFont(r.name)) { root.previewKind = "font"; return; }
    // An archive shows what is inside it. "binary" is true of a .tar.zst and
    // tells you nothing you wanted to know before extracting it.
    if (Terminus.isArchive(r.name)) {
      root.previewKind = "archive";
      previewProc.command = ["sh", "-c", Terminus.archiveListCommand(r.path)];
      previewProc.running = true;
      return;
    }
    if (Terminus.isPdf(r.name)) {
      root.previewKind = "pdf";
      pdfProc.command = ["sh", "-c", Terminus.pdfCommand(r.path, root.pdfStem)];
      pdfProc.running = true;
      return;
    }
    root.previewKind = "text";
    previewProc.command = ["sh", "-c", Terminus.batCommand(r.path)];
    previewProc.running = true;
  }

  // ── what the picture IS ──────────────────────────────────────────────────
  // The preview pane used to show a picture and nothing else, which answers
  // "which file is this" and none of the questions you actually open a folder
  // of media to ask — how big, how long, what codec.
  //
  // Two probes, one panel: `magick identify` for a still and `ffprobe` for a
  // video. Both were already installed for the thumbnails, so neither adds a
  // dependency, and both are quick enough to run per row PROVIDED they are not
  // run per row — hence the debounce and the cache below.
  property var previewInfo: null
  // Which path the answer on its way belongs to, and which probe was asked.
  // A reply arriving after the cursor has moved on is dropped rather than
  // shown against the wrong file: ffprobe on a large mkv can outlive several
  // keystrokes.
  property string previewInfoFor: ""
  property string previewInfoKind: ""
  property var infoCache: ({})
  property var infoOrder: []

  function cacheInfo(path, info) {
    const c = root.infoCache;
    const o = root.infoOrder.slice();
    if (c[path] === undefined) o.push(path);
    c[path] = info;
    while (o.length > 48) delete c[o.shift()];
    root.infoCache = c;
    root.infoOrder = o;
  }

  Timer {
    id: infoDelay
    // longer than the preview's 55ms: this is the one probe with no cheap
    // path. A picture's own preview is just Qt pointed at the file, but its
    // dimensions cost a process either way, so holding Down through a
    // wallpaper folder should start none of them.
    interval: 110
    onTriggered: root.loadPreviewInfo()
  }

  Process {
    id: infoProc
    stdout: StdioCollector {
      id: infoOut
      waitForEnd: true
      onStreamFinished: {
        const r = root.currentRow();
        const info = root.previewInfoKind === "video"
          ? Terminus.parseVideoInfo(infoOut.text)
          : (root.previewInfoKind === "audio"
            ? Terminus.parseAudioInfo(infoOut.text)
            : Terminus.parseImageInfo(infoOut.text));
        // Cached even when the cursor has moved on: the work is already done,
        // and walking back up the list should not pay for it twice.
        //
        // A FAILURE is not cached. Remembering a null would turn one probe
        // that lost a race — against a file still being written, most often —
        // into a file that has no metadata for as long as the window is open.
        if (info && root.previewInfoFor !== "")
          root.cacheInfo(root.previewInfoFor, info);
        if (r && r.path === root.previewInfoFor) root.previewInfo = info;
      }
    }
  }

  function loadPreviewInfo() {
    root.previewInfo = null;
    if (root.viewMode !== "columns") return;
    const r = root.currentRow();
    if (!r || r.isDir) return;
    const kind = Terminus.isVideo(r.name) ? "video"
      : (Terminus.isAudio(r.name) ? "audio"
        : (Terminus.isImage(r.name) ? "image" : ""));
    if (kind === "") return;
    const hit = root.infoCache[r.path];
    if (hit !== undefined) { root.previewInfo = hit; return; }
    root.previewInfoFor = r.path;
    root.previewInfoKind = kind;
    infoProc.command = ["sh", "-c",
      kind === "video" ? Terminus.videoInfoCommand(r.path)
        : (kind === "audio" ? Terminus.audioInfoCommand(r.path)
          : Terminus.imageInfoCommand(r.path))];
    infoProc.running = true;
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
  // SEARCH RESULTS ARE NOT SORTED, and that is the whole of the second half of
  // the search fix.
  //
  // fzf ranks its answers best-first, and this then threw that away and put
  // them back in alphabetical order — so the most relevant hit was wherever
  // its name happened to fall in the alphabet. Between matching whole paths
  // and re-sorting the result, "find" was returning good answers and
  // presenting them as noise.
  //
  // A search result is an ANSWER, not a directory; the hidden-file toggle
  // still applies, because that is about what you want to see rather than
  // about order.
  readonly property var sorted: {
    const kept = Terminus.filterEntries(root.rows, "", root.showHidden);
    if (root.searchMode !== "") return kept;
    // The usage sort reads `du` off the row, so the measured size is written
    // onto it here — the same decorating enrich() already does, and reading
    // dirSizes in this binding is also what makes the order settle by itself
    // the moment a measurement lands.
    if (root.usage) {
      const m = root.dirSizes;
      for (let i = 0; i < kept.length; ++i) {
        const r = kept[i];
        r.du = r.isDir ? m[r.path] : r.size;
      }
    }
    return Terminus.sortEntries(kept, root.sortKey, root.sortDesc);
  }

  readonly property var view: Terminus.filterQuery(root.sorted, root.query)

  // FUNCTIONS, not bindings. As properties these recomputed whenever `marked`
  // changed — every pointer move of a drag-select — and the context menu's
  // item list depended on `acting`, so it rebuilt its labels each time even
  // while closed. Nothing needs either until something acts.
  function markedRows() {
    const out = [];
    const v = root.view;
    const m = root.marked;
    for (let i = 0; i < v.length; ++i)
      if (m[v[i].path]) out.push(v[i]);
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
    const cat = Terminus.categoryOf(e.name);
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
      // The three cells that were still asking a function on every rebind.
      //
      // `reuseItems` means scrolling re-binds `entry` on every recycled
      // delegate, and each of these ran per row per bind: kindOf walks five
      // extension tables, formatTime does date arithmetic and builds a string,
      // formatSize compares three magnitudes and calls toFixed. A function
      // call in a binding cannot be compiled either, so it was interpreted
      // every time. None of the answers can change while the listing stands.
      //
      // Exactly the argument that already moved `ink` and `glyph` in here.
      r.kind = r.isDir ? "directory"
        : (r.isLink && r.broken ? "broken link" : Terminus.kindOf(r.name));
      // A relative time now freezes until the next listing rather than
      // refreshing whenever a row happens to be recycled. Nothing was
      // refreshing it on a clock before either — bindings do not re-evaluate
      // because time passed — so this only makes the column CONSISTENT: the
      // rows you scroll to no longer read a few minutes fresher than the rows
      // you started on.
      r.when = Terminus.formatTime(r.mtime);
      // Directories have no honest size until du has been round, so theirs
      // stays the size cell's business.
      r.sizeText = r.isDir ? "" : Terminus.formatSize(r.size);
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
    // A FloatingWindow is visible by default, and `shown` starts false, so a
    // freshly created window came up ON SCREEN with nothing having asked for
    // it — the manager makes one at load so SUPER+E always has something to
    // reveal, and that one flashed up on every quickshell start. Nothing
    // synced the two: onShownChanged only fires on a CHANGE, and false never
    // changed. So sync it once here, at construction, before spawn() or pick()
    // has had the chance to set `shown`.
    root.visible = root.shown;
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
        root.rows = root.enrich(Terminus.parseListing(listOut.text, root.cwd));
        // a directory you walk into while the mode is on measures itself,
        // because a usage view of a folder it has not looked at is a column
        // of dashes
        if (root.usage) Qt.callLater(root.measureAll);
        // Land on the directory we just came out of rather than on the first
        // row: walking up and back down a tree should return you to where you
        // were, not to the top of every level on the way.
        if (root.wantSel !== "") {
          const want = root.wantSel;
          root.wantSel = "";
          for (let i = 0; i < root.view.length; ++i) {
            if (root.view[i].path === want) { root.sel = i; root.anchor = i; break; }
          }
          // Something just made: land on it, flash it, and open the name for
          // editing — the second half of `a`, once the row it is about exists.
          if (want === root.freshPath) {
            root.madePulse++;
            root.renaming = true;
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
    listProc.command = ["sh", "-c", Terminus.listCommand(root.cwd)];
    listProc.running = true;
    if (full) {
      parentProc.command = ["sh", "-c", Terminus.listCommand(Terminus.dirname(root.cwd))];
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
    // An edit belongs to the row it was opened on, and that row is about to
    // stop existing. Not a cancel-with-delete: leaving a directory is not a
    // decision about the thing you were naming, so whatever it is called now
    // is what it keeps.
    if (root.renaming) root.endRename(false);
    root.searchMode = "";
    root.searchQuery = "";
    // Navigating out of results is leaving them behind, not going back: the
    // way back was to where the search STARTED, and you have since gone
    // somewhere on purpose.
    root.searchBackCwd = "";
    root.searchBackSel = "";
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
    root.goTo(Terminus.dirname(from));
  }

  // Bumped every time something is OPENED — Return, or a double click. A
  // counter rather than a signal because a delegate can bind to a property and
  // cannot connect to a signal it has no reference to — see the note over
  // openMenuAt for the same trap.
  //
  // This is the only thing the row sweep and the tile flare hang off, and it
  // took two goes to get there. The sweep was fired by the CURSOR MOVING, on
  // the theory that a highlight arriving fully formed is hard to follow at
  // speed. But moving the cursor is not an event worth animating: it happens
  // on every j and k, on every click, and on the pointer drifting across the
  // list — and a light washing over a row you were only passing through reads
  // as the list flashing at the pointer. Opening something is the event. The
  // grid's tiles had always been drawn this way; the list rows now agree.
  property int openPulse: 0
  // and one for a row that has just been created, so it can announce itself
  property int madePulse: 0

  function activate() {
    const r = root.currentRow();
    if (!r) return;
    root.openPulse++;
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

    root.run(Terminus.openCommand(r.path));
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
  // Whether the pointer is somewhere a rubber band would mean anything. See
  // band.zoneL/zoneR — written by the hover handler that watches the body.
  property bool overBandZone: true
  // The narrowest a listing can be and still hold three columns. Below it the
  // size and date are dropped rather than squeezed into each other.
  readonly property real metaMinWidth: 420

  // ── the mouse, as a glyph ─────────────────────────────────────────────
  // "middle click" is three syllables of hint sitting next to a two-word
  // entry, and the F1 list had "right click", "click" and "mouse 4 / 5" all
  // saying the same noun a different way.
  //
  // There is no per-button mouse glyph in the font, so the button is the
  // NUMBER beside it — the notation the keymap was already using for
  // "mouse 4 / 5", and the numbering this machine actually uses: evdev orders
  // them BTN_LEFT, BTN_RIGHT, BTN_MIDDLE (272, 273, 274), which is what
  // hyprland binds against. So 1 left, 2 RIGHT, 3 MIDDLE — not X11's order,
  // where 2 and 3 are the other way round.
  readonly property string mouseGlyph: "\uEFBA"
  function mouseKey(button) { return root.mouseGlyph + " " + button; }

  // ── the list's columns ──────────────────────────────────────────────────
  //
  // ONE set of fractions, read by the headings and by the rows, so a cell is
  // always under the heading that names it. Fractions of the INNER width: a
  // Row's padding comes out of its children's space, so subtracting the 24px
  // first is what makes the arithmetic exact at any width.
  //
  // Search gets a set of its own. A result is a PATH, not a name — where it
  // was found is half the answer and the reason the search was run — so the
  // column appears with the results and goes away with them. NAME gives up the
  // room for it: the numbers were already the narrowest things on the row.
  readonly property var colPlain:
    ({ name: 0.44, where: 0.0, kind: 0.14, size: 0.18, time: 0.24 })
  readonly property var colFound:
    ({ name: 0.30, where: 0.24, kind: 0.10, size: 0.16, time: 0.20 })
  // AND THE SAME ANSWER FOR A NARROW PANE. The miller layout's middle column
  // is a third of a pane wide, so it has always been drawn with no metadata at
  // all — which is right for a directory, where the name is the whole of what
  // distinguishes a row, and wrong for RESULTS, where it is not. A search in
  // columns view showed two files of the same name as two identical rows and
  // no way to tell which was which; that is the exact failure the WHERE column
  // was written for, and it was the one view that could not draw it.
  //
  // The numbers give up their room rather than the name: a size and a date are
  // what you can still get from the preview pane beside it, and where the file
  // actually is, is not.
  // Half and half. The first split gave WHERE the larger share on the grounds
  // that it is the disambiguating column — and turned "terminus.js" into
  // "ter….js", which disambiguates nothing because you can no longer read what
  // it is. A name has a length a file type puts a floor under; WHERE elides
  // from the FRONT and stays useful at any width, so it is the one that can
  // afford to give room back.
  readonly property var colFoundNarrow:
    ({ name: 0.52, where: 0.48, kind: 0.0, size: 0.0, time: 0.0 })
  // True while a scrollbar has the pointer. The rubber band stands down for
  // it — see ScrollRail's own note.
  property bool railDragging: false

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
  function rowUnder(bx, by) {
    // The second pane has its own rows and its own cursor, and neither belongs
    // to the active listing. Returning 0 rather than -1 says "over something",
    // which is what turns the empty-space overlay off and lets the click reach
    // the row underneath.
    if (root.dual && (bx < root.activePaneX
                      || bx > root.activePaneX + root.activePaneW)) return 0;
    // Measured from the ACTIVE PANE's left edge, not the body's. The three
    // views are placed at activePaneX now, and indexAt asks in the view's own
    // coordinates — with the active pane on the right-hand half, the unshifted
    // x landed a whole pane's width to the left of where the pointer was.
    const x = bx - root.activePaneX;
    // and from its top, which is under this half's headings when it has them
    const y = by - bodyBox.topH;
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

  // ── while a card has the screen ─────────────────────────────────────────
  //
  // Three layers keep a dialog modal and this is the third. InputShield stops
  // the POINTER, dialogKeys stops the KEYBOARD, and neither stops a
  // DragHandler: a pointer handler is allowed to take a grab away from an item
  // that has already accepted the press, and rowDrag/tileDrag are declared
  // with permissive enough grabs to do exactly that. So a press on a row
  // behind an open dialog still started a drag, complete with the card
  // following the cursor over the top of the panel.
  //
  // Handlers cannot be shielded, only switched off — so they read this.
  readonly property bool modal: props.open || perms.open || confirm.open
    || prompt.open || pathBar.open || bulk.open || prefs.open || help.open

  // Built when the path changes, not when a crumb is drawn. The delegate asked
  // crumbs() for its own length, so rendering n crumbs cost n+1 walks of the
  // path on every repaint.
  readonly property var crumbList: Terminus.crumbs(root.cwd)

  // How many are ticked, without building the list of them. The status line
  // wants a number, and markedRows scans the whole view to produce an array —
  // which it was doing on every pointer move of a drag-select.
  // Counted against the VIEW, not against the raw map.
  //
  // A filter narrows what every verb acts on — markedRows() has always walked
  // the view — so a header reading "12 selected" while `d` would trash three
  // of them was the window misreporting its own state. Marks made before the
  // filter was typed are KEPT rather than dropped: they stop being counted
  // while they are out of sight and come back the moment it clears.
  readonly property int markedCount: {
    const v = root.view;
    const m = root.marked;
    let n = 0;
    for (let i = 0; i < v.length; ++i) if (m[v[i].path]) n++;
    return n;
  }

  function markRange(a, b) {
    const lo = Math.min(a, b), hi = Math.max(a, b);
    const next = Object.assign({}, root.marked);
    const v = root.view;
    for (let i = lo; i <= hi; ++i)
      if (v[i]) next[v[i].path] = true;
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

  // ── visual mode ───────────────────────────────────────────────────────
  // yazi's `v`. An anchor is dropped where the cursor stands and everything
  // between it and the cursor is selected as the cursor moves; `v` again stops
  // extending and leaves the selection exactly as it is, and Escape does the
  // same before it gets as far as clearing anything.
  //
  // WHAT WAS ALREADY MARKED IS KEPT SEPARATELY, in `visualBase`, and the range
  // is laid over a copy of it on every move. That is the difference between a
  // selection you can extend and one that only ever grows: walking back down
  // the range releases the rows the range no longer covers, without releasing
  // the ones that were marked before visual mode started.
  //
  // The anchor is its own property rather than the `anchor` shift-click uses,
  // because the two are live at the same time and mean different things — one
  // is where the last plain click landed, this one is where `v` was pressed.
  property int visualAt: -1
  property var visualBase: ({})
  readonly property bool visualOn: root.visualAt >= 0

  function toggleVisual() {
    if (root.visualOn) { root.endVisual(); return; }
    if (root.view.length === 0) return;
    root.visualBase = Object.assign({}, root.marked);
    root.visualAt = root.sel;
    root.extendVisual();
  }

  function endVisual() { root.visualAt = -1; root.visualBase = ({}); }

  function extendVisual() {
    if (!root.visualOn) return;
    const v = root.view;
    const next = Object.assign({}, root.visualBase);
    const lo = Math.min(root.visualAt, root.sel);
    const hi = Math.max(root.visualAt, root.sel);
    for (let i = lo; i <= hi; ++i) if (v[i]) next[v[i].path] = true;
    root.marked = next;
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
    // WRAPS, but only off the end it is already standing on.
    //
    // Down at the bottom is the top again and up at the top is the bottom —
    // which is what a list of thirty items with the one you want at the other
    // end wants. A page or a half page from the MIDDLE still lands on the end
    // rather than jumping past it to the far side: "down sixteen" from row
    // four means row twenty or the bottom, never the top.
    let i = root.sel + delta;
    if (i < 0) i = root.sel === 0 ? n - 1 : 0;
    else if (i > n - 1) i = root.sel === n - 1 ? 0 : n - 1;
    root.sel = i;
    Qt.callLater(root.positionSel);
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
        const clash = Terminus.parseConflicts(conflictOut.text);
        // The mode is a plain string, not Terminus.CLASH.overwrite: a QML .js
        // import does not reliably expose top-level `const` bindings on its
        // namespace, and nothing else in this window reads one that way. The
        // names live in CLASH inside terminus.js, where the comparisons are.
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
      Terminus.conflictCommand(root.pending.names, root.destDir)];
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

        // an archive job counts entries; the percentage is derived from the
        // total it announced before it started
        if (root.job.op === "compress" || root.job.op === "extract") {
          const rec = Terminus.parseArchiveProgress(line);
          if (!rec) return;
          const j = Object.assign({}, root.job);
          if (rec.total !== undefined) j.entries = rec.total;
          if (rec.at !== undefined) j.seen = rec.at;
          // an empty archive is finished the moment it starts, and 0/0 would
          // otherwise sit at nothing until the process exited
          j.pct = j.entries > 0
            ? Math.max(0, Math.min(100, Math.round(j.seen * 100 / j.entries)))
            : (j.seen > 0 ? 100 : 0);
          root.job = j;
          return;
        }

        // "Keep both" copies one item at a time and announces each one, so the
        // panel can say which of them it is on rather than letting the
        // percentage drop to zero once per item with no explanation.
        const item = Terminus.parseItem(line);
        if (item > 0) {
          const at = Object.assign({}, root.job);
          at.index = item;
          at.pct = 0;
          root.job = at;
          return;
        }
        const pct = Terminus.parseProgress(line);
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
      // read BEFORE the job is cleared: the message below is about the job
      // that just ended, and by the next line there is no job to ask
      const done = root.job;
      const op = done ? done.op : "";
      root.job = null;
      // A cancel is a nonzero exit too, and reporting it as "transfer failed"
      // would be telling you something went wrong when you are the thing that
      // went wrong. cancelJob has already set the status line.
      if (code !== 0 && root.status === "")
        root.status = (op === "compress" ? "compress failed"
                     : op === "extract" ? "extract failed" : "transfer failed");
      // SUCCESS USED TO SAY NOTHING AT ALL. Failure set the status line and
      // the panel simply vanished when a copy worked, which is fine while you
      // are watching it and useless the moment you are not — and a copy worth
      // starting is very often one you walk away from.
      //
      // Announced through notify-send rather than by reaching into howler,
      // for the reason chronos/Chronos.qml gives where it does the same: it
      // goes out over DBus and comes back through the same server every other
      // application uses, so it lands in the history and the bell counts it.
      // (Reaching in directly is not an option either — quickshell's
      // Notification type is not creatable, and Howler.record would add a
      // history row that never becomes a toast.)
      //
      // ONLY IF IT TOOK LONG ENOUGH TO LOSE INTEREST IN. A toast for every
      // two-file copy is noise you learn to dismiss without reading, which
      // costs the toasts that matter their credibility. The rest is left to
      // the panel, which was the right answer for a job you watched.
      if (code === 0 && done && Date.now() - (done.started || 0) > 3000) {
        Quickshell.execDetached(["notify-send", "-a", "terminus",
          Terminus.jobSummary(op, done.names)]);
      }
      // and clear the note the job was started with — `status` is sticky, so
      // "3 to copy" would otherwise outlive the copy by the rest of the session
      if (code === 0 && root.status !== "") root.status = "";
      root.marked = {};
      root.refresh();
      // the second pane is very often the destination, and a destination that
      // does not show what just arrived in it is the whole point missed
      root.refreshOther();
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
    root.job = { op: op, names: paths.map((p) => Terminus.basename(p)),
                 pct: 0, index: 0, total: paths.length,
                 // entries counted rather than bytes measured, for the two ops
                 // whose tools report no percentage of their own
                 entries: 0, seen: 0,
                 // when it began, which is the only thing that can tell a job
                 // worth announcing from one you watched finish
                 started: Date.now() };

    // Compress and extract go through the same panel, the same queue and the
    // same cancel as a transfer does: it is the same question — something is
    // working, how far along is it — and a second set of machinery to answer
    // it would only be a second set to keep in step.
    if (op === "compress" || op === "extract") {
      jobProc.command = ["setsid", "sh", "-c", op === "compress"
        ? Terminus.compressJobCommand(paths, dest)
        : Terminus.extractJobCommand(paths[0], dest)];
      jobProc.running = true;
      return;
    }

    // setsid, so the job gets a process group of its own and CANCELLING it can
    // take the whole tree down. Signalling the Process itself would only reach
    // the shell and leave rsync running orphaned, still writing files.
    jobProc.command = ["setsid", "sh", "-c",
      Terminus.transferCommand(paths, dest, op === "move", clash)];
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
        pairs.push([p.paths[i],
          Terminus.joinPath(root.destDir, Terminus.basename(p.paths[i]))]);
      }
      root.pushUndo({ kind: "move", pairs: pairs });
    }
    root.startJob(p.op, p.paths, root.destDir, clash);
    // spent: the next paste is a paste into where you are standing again
    root.pasteDest = "";
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
        root.run(Terminus.trashCommand(paths));
        // recorded by where they CAME FROM: that is what undo can look up
        root.pushUndo({ kind: "trash", paths: paths });
        root.marked = {};
      });
  }

  // ── renaming ────────────────────────────────────────────────────────────
  // In place, on the row itself. `renaming` is a window-level flag rather than
  // per-row state because only one row can be the cursor, and the cursor is
  // the only row this is ever about — so the delegate that happens to be
  // current picks it up and everything else ignores it, including the rows in
  // the other pane and in the columns beside it.
  property bool renaming: false

  function beginRename() {
    if (!root.currentRow()) return;
    // `r` is never a creation, so Escape out of it must not delete anything —
    // and a create whose listing never came back would otherwise leave its
    // path armed behind an unrelated rename.
    root.freshPath = "";
    root.renaming = true;
  }

  // `cancelled` is Escape rather than Return, and for something that was
  // created a moment ago that means "I did not want this after all" — so it
  // goes away again. Anything older is left exactly as it was.
  function endRename(cancelled) {
    if (!root.renaming) return;
    root.renaming = false;
    const fresh = root.freshPath;
    root.freshPath = "";
    if (cancelled === true && fresh !== "")
      root.run(Terminus.deleteCommand([fresh]));
    content.forceActiveFocus();
  }

  function commitRename(entry, name) {
    root.endRename(false);
    const want = String(name || "").trim();
    // An empty answer on a thing that was just created keeps the name it
    // arrived with, which is the whole point of it arriving with one.
    if (!entry || want === "" || want === entry.name) return;
    // A name is a name, not a path: a slash in it would move the file
    // somewhere else under the guise of renaming it.
    if (want.indexOf("/") >= 0) { root.status = "a name cannot contain /"; return; }
    root.run(Terminus.renameCommand(entry.path, want));
    root.pushUndo({ kind: "rename", from: entry.path,
                    to: Terminus.joinPath(Terminus.dirname(entry.path), want) });
    // land on it under its new name rather than wherever the old one sorted
    root.wantSel = Terminus.joinPath(Terminus.dirname(entry.path), want);
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
    if (!r || r.isDir || !Terminus.isImage(r.name)) return;
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
    const v = root.view;
    for (let i = Math.max(0, lo); i <= Math.min(v.length - 1, hi); ++i)
      next[v[i].path] = true;
    root.marked = next;
  }

  // ── dragging in and out ─────────────────────────────────────────────────
  // text/uri-list is the one thing every file-aware application on the desktop
  // agrees on, so dragging a row into Firefox or a terminal hands over the
  // same list a file manager would. Dragging the CURSOR row alone would be
  // wrong when a selection exists — you dragged the selection.
  // What the drag card says, and the grab that turns it into a picture.
  property string dragLabel: ""
  property string dragGlyph: ""
  property color dragInk: Zenon.white
  property int dragCount: 0
  // Held so the grab result is not collected: Drag.imageSource points at a
  // url that lives exactly as long as this object does.
  property var dragGrab: null

  // Fills the card in for whatever is about to be dragged, renders it, and
  // hands the url back. Asynchronous by nature — grabToImage answers on the
  // next frame — so the caller starts the drag from inside the callback, with
  // the button still held, which is all the platform needs.
  function dragPicture(entry, then) {
    const rows = root.dragRows(entry);
    const first = rows[0] || entry;
    root.dragCount = rows.length;
    root.dragLabel = rows.length === 1
      ? (first ? first.name : "") : rows.length + " items";
    root.dragGlyph = (first && first.glyph) ? first.glyph : "";
    root.dragInk = (first && first.ink !== undefined) ? first.ink : Zenon.white;
    // A failed grab is not a reason to refuse the drag; it just goes without
    // a picture, which is what it did before there was one.
    if (!dragCard.grabToImage((res) => { root.dragGrab = res; then(res.url); }))
      then("");
  }

  // The rows a drag is actually about: the marked set when there is one, and
  // otherwise the row under the pointer. Exactly the rule dragUris always
  // used — written once now, because the picture and the payload have to
  // agree about what is being dragged or the card lies about the drop.
  function dragRows(entry) {
    const marked = root.markedRows();
    return marked.length > 0 ? marked : (entry ? [entry] : []);
  }

  function dragUris(entry) {
    return root.dragRows(entry).filter((r) => !!r)
      .map((r) => "file://" + encodeURI(r.path)).join("\r\n");
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
  // The directory currently under a drag, or "" for the space between rows.
  property string dropDir: ""

  // WHICH directory a drop means is a question about where the pointer is,
  // not about which item accepted it — there is one DropArea over the whole
  // body (see dropHint), and it already answers the same question for which
  // PANE the drop lands in. This just asks it one level finer.
  //
  // mapFromItem rather than hand-rolled offsets: the second pane's views are
  // nested a level deeper than the first pane's, and arithmetic written here
  // would have to know that and would break the day it moves. indexAt wants
  // CONTENT coordinates, which is what contentX/contentY add back.
  function dropDirAt(x, y) {
    const other = root.dual && (x < root.activePaneX
                             || x > root.activePaneX + root.activePaneW);
    const isGrid = other ? root.otherViewMode === "grid" : root.viewMode === "grid";
    const v = other ? (isGrid ? otherGrid : otherList)
                    : (isGrid ? grid : list);
    const rows = other ? root.otherRows : root.view;
    if (!v || !v.visible || !rows) return "";
    const p = v.mapFromItem(dropHint, x, y);
    if (p.x < 0 || p.y < 0 || p.x > v.width || p.y > v.height) return "";
    const i = v.indexAt(p.x + v.contentX, p.y + v.contentY);
    if (i < 0 || i >= rows.length) return "";
    const r = rows[i];
    // only a directory can be dropped INTO; anything else means the folder
    // it is sitting in, which is what the empty space already means
    return (r && r.isDir) ? r.path : "";
  }

  function dropUris(urls, action, dest) {
    const into = (dest && dest !== "") ? dest : root.cwd;
    const paths = [];
    // A drop with no file URLs at all — a text selection, a colour — is not
    // for us. Now that the DropArea takes everything, this is the filter.
    if (!urls || urls.length === 0) return;
    for (const u of urls) {
      const t = String(u);
      if (t.indexOf("file://") !== 0) continue;
      const path = decodeURIComponent(t.slice(7));
      // dropping a directory into itself is not a move, it is a mistake —
      // and neither is dropping one into something it contains, which mv
      // refuses anyway ("cannot move a directory into itself"). Catching it
      // here means the answer is nothing happening rather than an error.
      if (path === into || Terminus.dirname(path) === into) continue;
      if (into.indexOf(path + "/") === 0) continue;
      paths.push(path);
    }
    if (paths.length === 0) return;
    const names = paths.map((p) => Terminus.basename(p));
    const drop = (op) => {
      root.setPending({ op: op, paths: paths, names: names });
      root.pasteDest = into === root.cwd ? "" : into;
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
      root.run(Terminus.restoreCommand(e.paths, "path"));
      root.status = "restored " + e.paths.length;
      return;
    }
    if (e.kind === "move") {
      let cmd = "";
      for (let i = 0; i < e.pairs.length; ++i) {
        const from = e.pairs[i][1], to = e.pairs[i][0];
        cmd += "mkdir -p -- " + Strings.shellQuote(Terminus.dirname(to))
          + " && mv -n -- " + Strings.shellQuote(from) + " "
          + Strings.shellQuote(to) + "\n";
      }
      root.run(cmd);
      root.status = "moved back " + e.pairs.length;
      return;
    }
    root.run(Terminus.renameCommand(e.to, Terminus.basename(e.from)));
    root.status = "rename undone";
  }

  // ── the trash, in both directions ───────────────────────────────────────
  readonly property bool inTrash: Terminus.isTrashDir(root.cwd)

  // How much the trash holds, asked when you are standing in it.
  property string trashSize: ""

  Process {
    id: trashSizeProc
    command: ["sh", "-c", Terminus.trashSizeCommand()]
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
        root.run(Terminus.emptyTrashCommand());
        root.marked = {};
        root.status = "trash emptied";
      });
  }

  function restoreSelected() {
    const rows = root.acting();
    if (rows.length === 0) return;
    root.run(Terminus.restoreCommand(rows.map((r) => r.name), "name"));
    root.marked = {};
    root.status = "restoring " + rows.length;
  }

  // ── archives ────────────────────────────────────────────────────────────
  function extractSelected() {
    const rows = root.acting().filter((r) => !r.isDir && Terminus.isArchive(r.name));
    if (rows.length === 0) { root.status = "not an archive"; return; }
    // ONE JOB PER ARCHIVE, handed to the queue that already serialises work.
    // A single script over all of them could only report one count across
    // archives of wildly different sizes, and the panel would step backwards
    // every time it reached the next one.
    for (const r of rows) root.startJob("extract", [r.path], root.cwd, "");
    root.marked = {};
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
    const suggested = (rows.length === 1 ? Terminus.stem(rows[0].name)
                                         : Terminus.basename(root.cwd))
      + (ext && ext !== "" ? ext : ".tar.zst");
    prompt.ask("Compress to", suggested, (name) => {
      if (name === "") return;
      root.startJob("compress", rows.map((r) => r.path),
                    Terminus.joinPath(root.cwd, name), "");
      root.marked = {};
    });
  }

  // ── links ───────────────────────────────────────────────────────────────
  // Paste, but leaving the file where it is. Uses the same yank buffer as a
  // normal paste, because "what am I about to put down" is the same question.
  function pasteLink(symbolic) {
    if (!root.pending || root.pending.paths.length === 0) return;
    root.run(Terminus.linkCommand(root.pending.paths, root.cwd, symbolic));
    root.status = symbolic ? "symlinked" : "hard linked";
  }

  // ── bulk rename ─────────────────────────────────────────────────────────
  // It used to open $EDITOR in a terminal with one name per line. That is a
  // good way to rename forty files and a poor way to find out you cannot:
  // the window was somewhere else, the rules were only checked after you had
  // closed it, and the whole feature depended on having an editor configured.
  // The editing happens in the card below now — see `bulk`.
  property var bulkNames: []
  // What they WOULD be called. Replaced whole rather than written into: a QML
  // property only reports a change when the reference changes, so mutating the
  // array in place left every row showing what it showed before.
  property var bulkEdits: []
  property string bulkDir: ""

  function beginBulkRename() {
    const rows = root.acting();
    if (rows.length === 0) return;
    root.bulkNames = rows.map((r) => r.name);
    root.bulkEdits = root.bulkNames.slice();
    root.bulkDir = root.cwd;
    bulk.open = true;
  }

  function setBulkEdit(i, text) {
    if (i < 0 || i >= root.bulkEdits.length) return;
    if (root.bulkEdits[i] === text) return;
    const next = root.bulkEdits.slice();
    next[i] = text;
    root.bulkEdits = next;
  }

  // Find-and-replace across the whole set, from the ORIGINAL names.
  //
  // From the originals rather than from what is on screen, so running it twice
  // is the same as running it once — a replace that fed on its own output
  // turned "a-a" into "b-b" and then into "c-c" as you typed. The cost is that
  // it discards hand edits, which is why it is a button and not a live
  // binding: an edit you made by hand should not evaporate because the caret
  // moved through the pattern field.
  function applyBulkReplace(find, repl) {
    if (find === "") return;
    root.bulkEdits = Terminus.bulkReplace(root.bulkNames, find, repl);
  }

  function commitBulkRename() {
    const pairs = Terminus.bulkPairs(root.bulkNames, root.bulkEdits);
    // Refused rather than half-applied — see bulkIssues for the rules. The
    // card disables its own button on the same test, so getting here with a
    // null means something changed underneath it.
    if (pairs === null) { root.status = "bulk rename refused"; return; }
    bulk.open = false;
    content.forceActiveFocus();
    if (pairs.length === 0) { root.status = "no names changed"; return; }
    root.run(Terminus.bulkRenameApply(root.bulkDir, pairs));
    root.status = "renamed " + pairs.length;
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
      onStreamFinished: root.openWithApps = Terminus.parseApps(appsOut.text)
    }
  }

  function findApps(path) {
    root.openWithApps = [];
    if (!path || appsProc.running) return;
    appsProc.command = ["sh", "-c", Terminus.appsCommand(path)];
    appsProc.running = true;
  }

  function openWith(id, path) {
    root.run(Terminus.openWithCommand(id, path));
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

  function openShell() { root.run(Terminus.shellCommand(root.cwd)); }

  // yazi's `a`. One prompt for both, because the only difference is whether
  // the name ends in a slash — which is how yazi says it too.
  // ── creating ────────────────────────────────────────────────────────────
  // MAKE IT, THEN NAME IT — which is the order every file manager that feels
  // direct does it in, and the order a phantom row asking for a name up front
  // was pretending to.
  //
  // The item is created immediately under a free default name, the listing
  // brings it back, the cursor lands on it and the row goes straight into the
  // same inline edit `r` uses. So there is one naming interaction in this
  // window, not two, and the thing being named is on screen while you name it.
  //
  // Return with the name untouched keeps the default. Escape UNDOES the
  // creation rather than leaving a "new file" behind, which is what makes it
  // safe to press `a` to see what happens.
  property string freshPath: ""

  function beginCreate() { root.startCreate("file"); }
  function beginMkdir() { root.startCreate("dir"); }

  function startCreate(kind) {
    if (root.picking) return;
    // Finish whatever name is being typed rather than refusing: `a` twice in
    // a row is a reasonable thing to do, and the first one silently doing
    // nothing is not a reasonable answer to it.
    if (root.renaming) root.endRename(false);
    const name = Terminus.freeName(root.rows,
      kind === "dir" ? "new directory" : "new file");
    const path = Terminus.joinPath(root.cwd, name);
    root.freshPath = path;
    root.wantSel = path;
    root.run(kind === "dir" ? Terminus.mkdirCommand(root.cwd, name)
                            : Terminus.createCommand(root.cwd, name));
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
        root.run(Terminus.deleteCommand(rows.map((r) => r.path)));
        root.marked = {};
      });
  }

  function beginSearch(mode) { searchBar.begin(mode); }



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
        [" ", "go to\u2026", () => pathBar.begin()]
      ],
      c: [
        ["c", "copy path",     () => { const r = root.currentRow();
                                       if (r) root.copyText(r.path, "path copied"); }],
        ["d", "copy dirname",  () => { const r = root.currentRow();
                                       if (r) root.copyText(Terminus.dirname(r.path), "dirname copied"); }],
        ["f", "copy filename", () => { const r = root.currentRow();
                                       if (r) root.copyText(r.name, "filename copied"); }],
        ["n", "copy name",     () => { const r = root.currentRow();
                                       if (r) root.copyText(Terminus.stem(r.name), "name copied"); }],
        ["m", "permissions",   () => perms.ask()],
        ["a", "archive",       () => root.beginCompress("")]
      ],
      b: [
        ["a", "bookmark here",   () => root.toggleBookmark()],
        // ONE key that goes both ways, on whatever the cursor is on. `b d`
        // used to sit beside `b a` as "remove bookmark" and called exactly the
        // same function — two entries in the hint bar for one toggle, neither
        // of which could act on the row you were looking at. This one does:
        // a directory under the cursor is what you are pointing at, and the
        // glyph beside its name says which way the toggle will go.
        // A FUNCTION rather than a string, because this label is not fixed —
        // see bookmarkVerb. The hint bar calls it if it is callable, so any
        // other entry that wants to describe itself by the state it is in can
        // do the same without a second mechanism.
        ["b", () => root.bookmarkVerb(), () => root.toggleBookmarkHere()]
      ],
      ",": [
        ["u", "disk usage",  () => root.toggleUsage()],
        ["n", "by name",     () => root.setSort("name")],
        ["s", "by size",     () => root.setSort("size")],
        ["m", "by modified", () => root.setSort("time")],
        ["k", "by kind",     () => root.setSort("kind")],
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
      // ── while a dialog is up ──────────────────────────────────────
      // It takes the keyboard and the listing behind it gets nothing: acting
      // on a file while a question about that file is still on screen is the
      // one thing this must not do.
      //
      // confirm and prompt hold focus in controls of their own and never
      // reach here — this is the keyboard for the two that had none at all,
      // and Escape for both of them.
      // Dialogs are handled by dialogKeys, which takes the keyboard for as
      // long as one is up — see its own note. Nothing here may act while a
      // question is on screen.
      if (confirm.open || prompt.open || perms.open || props.open) return;

      if (help.open) {
        event.accepted = true;
        help.open = false;
        return;
      }
      if (menu.open) {
        // EVERY key belongs to the menu while it is up — the listing behind
        // it must not act on anything — but they no longer all mean "nothing".
        // The card is navigable from the keyboard now, which is the other half
        // of being able to open it from the keyboard.
        event.accepted = true;
        // the key that opened it closes it
        if (event.key === Qt.Key_Menu) { menu.close(); return; }
        // Escape backs out ONE LEVEL, the way it does everywhere else in this
        // window: out of the submenu first, and only then out of the menu.
        if (event.key === Qt.Key_Escape) {
          if (menu.subSel >= 0) { menu.subSel = -1; menu.subAt = -1; }
          else menu.close();
          return;
        }
        // j/k as well as the arrows, because the listing behind it moves that
        // way and a menu that did not would be the one place it does not.
        if (event.key === Qt.Key_Down || event.text === "j") { menu.move(1); return; }
        if (event.key === Qt.Key_Up || event.text === "k") { menu.move(-1); return; }
        // right steps INTO the children, left comes back out — the same shape
        // as h/l walking the tree in the listing
        if (event.key === Qt.Key_Right || event.text === "l") {
          if (menu.subSel < 0) {
            const it = menu.items[menu.at];
            if (it && it.sub) {
              menu.subAt = menu.at;
              menu.subSel = menu.step(it.sub, -1, 1);
            }
          }
          return;
        }
        if (event.key === Qt.Key_Left || event.text === "h") {
          if (menu.subSel >= 0) { menu.subSel = -1; menu.subAt = -1; }
          return;
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (menu.subSel >= 0) menu.activateSub();
          else menu.activateAt();
          return;
        }
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
        else if (root.visualOn) root.endVisual();
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
      // Alt+Return opens the properties of what is selected. It has to be
      // tested BEFORE the plain Return below, which takes any Return at all
      // and opens the file — modifiers and all.
      if ((event.modifiers & Qt.AltModifier)
          && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
        event.accepted = true; props.ask(); return;
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
      // The Menu (Application) key. No text of its own, so it belongs up here
      // with the named keys rather than in the switch below.
      if (event.key === Qt.Key_Menu)     { event.accepted = true; root.openMenuAtCursor(); return; }
      if (event.key === Qt.Key_Home)     { event.accepted = true; root.sel = 0; root.positionSel(); return; }
      if (event.key === Qt.Key_End) {
        event.accepted = true;
        root.sel = Math.max(0, root.view.length - 1);
        root.positionSel();
        return;
      }
      if (event.key === Qt.Key_Backspace) { event.accepted = true; root.goUp(); return; }
      // Tab crosses to the other pane, and only when there is one — with a
      // single pane it is left alone rather than bound to something else.
      if (event.key === Qt.Key_Tab && root.dual) {
        event.accepted = true; root.stepOver(); return;
      }
      // F5 and F6, where every dual-pane file manager has kept them since the
      // eighties. Inert with one pane rather than bound to something else,
      // because a key that means "to the other side" should not quietly mean
      // something different when there is no other side.
      if (event.key === Qt.Key_F5) { event.accepted = true; root.sendToOther("copy"); return; }
      if (event.key === Qt.Key_F6) { event.accepted = true; root.sendToOther("move"); return; }

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
      case "v":  event.accepted = true; root.toggleVisual(); break;
      case "V":  event.accepted = true; root.cycleView(); break;
      case "u":  event.accepted = true; root.undo(); break;
      case "z":  event.accepted = true; root.measureDirs(); break;
      case "\\": event.accepted = true; root.toggleDual(); break;
      case "o":  event.accepted = true; root.stepOver(); break;
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
              id: tabCell
              required property var modelData
              required property int index
              readonly property bool here: index === root.tab

              // A new tab grows into place rather than appearing, and the
              // active one lifts a little — the strip is the one part of the
              // chrome that changes while you are looking straight at it.
              opacity: 0
              Component.onCompleted: tabIn.start()
              NumberAnimation {
                id: tabIn
                target: tabCell
                property: "opacity"
                to: 1
                duration: Zenon.normal
                easing.type: Easing.OutCubic
              }
              Behavior on color {
                ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
              }
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
                text: Terminus.basename(here ? root.cwd : modelData.cwd)
                color: here ? Zenon.white : Zenon.muted
                font.family: "JetBrainsMono Nerd Font Propo"
                // the body's row size, written the same way rather than as a
                // number that happens to match — zoom then moves both together
                font.pixelSize: Math.round(16 * root.zoom)
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
            font.pixelSize: 18
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
              id: crumbRow
              required property var modelData
              required property int index

              // A step slides in from the left as you go deeper and fades as
              // you come back up. The path is the one thing in this window
              // that changes shape rather than content, and a row of words
              // that simply becomes a different row of words is hard to read
              // as movement.
              opacity: 0
              transform: Translate { id: crumbShift; x: -10 }
              Component.onCompleted: crumbIn.start()
              ParallelAnimation {
                id: crumbIn
                NumberAnimation { target: crumbRow; property: "opacity"; to: 1;
                                  duration: Zenon.normal; easing.type: Easing.OutCubic }
                NumberAnimation { target: crumbShift; property: "x"; to: 0;
                                  duration: Zenon.normal; easing.type: Easing.OutCubic }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: index > 1
                text: " › "
                color: Zenon.muted
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 14
              }

              Text {
                id: crumbLabel
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                // the last crumb is where you are; the rest are somewhere to go
                color: index === root.crumbList.length - 1
                  ? "#a3a9bd" : (crumbMa.containsMouse ? Zenon.cyan : Zenon.muted)
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: Font.Medium
                font.pixelSize: 15

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

          // ── what you are looking FOR, beside where you are looking ──────
          // The bar answers "where am I". During a search that is only half
          // the answer, and the other half was written in the search strip —
          // which closes the moment you press Return. So the results were a
          // directory of files from all over the tree with nothing on screen
          // saying what they had in common.
          //
          // It sits at the end of the path because that is what it qualifies:
          // this directory, these matches. The mode word stays over on the
          // right where it already was; repeating it here would be two labels
          // for one fact.
          Item {
            width: root.searchMode !== "" ? 10 : 0
            height: 1
          }

          Rectangle {
            id: searchChip
            anchors.verticalCenter: parent.verticalCenter
            visible: root.searchMode !== ""
            width: visible ? chipText.implicitWidth + 18 : 0
            height: 21
            radius: 5
            color: Qt.rgba(Zenon.sand.r, Zenon.sand.g, Zenon.sand.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(Zenon.sand.r, Zenon.sand.g, Zenon.sand.b, 0.32)

            Text {
              id: chipText
              anchors.centerIn: parent
              // the magnifier the search bar uses, so the two read as the same
              // thing seen twice rather than two different features
              text: "\uF002  " + root.searchQuery
              color: Zenon.sand
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 13
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
            font.pixelSize: 15
          }

          TextInput {
            id: filterField
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(8, Math.min(260, contentWidth + 2))
            color: Zenon.cyan
            selectionColor: Zenon.cyan
            selectedTextColor: Zenon.black
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 17
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

            // The caret, since a bare TextInput on a bar has no frame to say
            // where the keyboard is — and the field's OWN, for the reason the
            // search bar's carries: a second one drawn at contentWidth is in
            // the wrong place as soon as the caret is not at the end.
            cursorDelegate: Rectangle {
              width: 2
              color: Zenon.cyan
              SequentialAnimation on opacity {
                running: filterField.activeFocus
                loops: Animation.Infinite
                NumberAnimation { to: 0.2; duration: 620; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1.0; duration: 620; easing.type: Easing.InOutQuad }
              }
            }
          }
        }

        // ── the settings hatch ────────────────────────────────────────
        // The switches you flip WHILE you are working — hidden files, which
        // view, how much of the desktop shows through — at the far end of the
        // bar that already reports what the window is doing. Almost every one
        // of them has a key as well, and the panel is less a second way of
        // working than the place those keys are finally written down.
        Item {
          id: prefsToggle
          anchors.right: parent.right
          anchors.rightMargin: 8
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: 1
          width: 30
          height: parent.height

          Text {
            anchors.centerIn: parent
            // nf-fa-bars, as an escape — a literal nerd glyph does not survive
            // the trip through a shell heredoc, and arrives as nothing at all.
            text: "\uF0C9"
            color: prefs.open ? Zenon.cyan
              : (prefsHov.hovered ? Zenon.white : Zenon.muted)
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 16
          }

          HoverHandler { id: prefsHov }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: prefs.toggleFrom(prefsToggle)
          }
        }

        // What used to be a bar of its own along the bottom. Two full-width
        // strips to carry one line of text each was a strip too many, and the
        // right-hand end of the path bar was empty — so the count, the view
        // and whatever the last action had to say live here now.
        Row {
          id: crumbStatus
          anchors.right: prefsToggle.left
          anchors.rightMargin: 10
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
            font.pixelSize: 14
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: {
              const n = root.markedCount;
              // A MODE HAS TO BE VISIBLE. Everything else in this window is
              // one keystroke that does one thing; visual mode changes what
              // the arrow keys mean until it is turned off, so it says so.
              const mode = root.visualOn ? "VISUAL  \u00b7  " : "";
              // WHAT IT ADDS UP TO, not just how many. terminus.js has had
              // selectionSize since the status strip was written and nothing
              // ever called it — so "12 selected" told you nothing about
              // whether those twelve would fit on the stick you were copying
              // them to. Directories are left out of the total rather than
              // counted at their record size; the function's own note says why.
              if (n > 0) {
                const bytes = Terminus.selectionSize(root.markedRows());
                return bytes > 0
                  ? mode + n + " selected  \u00b7  " + Terminus.formatSize(bytes)
                  : mode + n + " selected";
              }
              if (mode !== "") return mode + "0 selected";
              const items = root.view.length
                + (root.view.length === 1 ? " item" : " items");
              // in the trash, how much it holds is what you are there to see
              return root.inTrash && root.trashSize !== ""
                ? items + " \u00b7 " + root.trashSize : items;
            }
            color: (root.markedCount > 0 || root.visualOn) ? Zenon.cyan : Zenon.muted
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 14
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
            font.pixelSize: 14
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.searchMode !== ""
              ? (root.searchMode === "grep" ? "grep" : "find") : root.viewMode
            color: root.searchMode !== "" ? Zenon.sand : Zenon.muted
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 14
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

      // ── the search bar ────────────────────────────────────────────
      // A STRIP, not a dialog. Searching is not a question with one answer to
      // give and then be done with — you type, you look, you narrow, you look
      // again — and a modal card over the listing hid the thing being searched
      // while asking about it. It sits under the breadcrumbs, above the rows,
      // and collapses to nothing when it is not in use.
      Rectangle {
        id: searchBar
        width: parent.width
        height: searchBar.open ? root.headH : 0
        visible: height > 0
        clip: true
        color: Zenon.headBg

        property bool open: false
        property string mode: "find"

        function begin(mode) {
          searchBar.mode = mode;
          searchBar.open = true;
          searchField.text = root.searchQuery;
          searchField.selectAll();
          searchField.forceActiveFocus();
        }

        function dismiss() {
          searchBar.open = false;
          content.forceActiveFocus();
        }

        function run() {
          const q = searchField.text.trim();
          if (q === "") { searchBar.dismiss(); return; }
          root.search(searchBar.mode, q);
          searchBar.dismiss();
        }

        Behavior on height {
          NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
        }

        Text {
          id: searchGlyph
          anchors.left: parent.left
          anchors.leftMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          text: searchBar.mode === "grep" ? "\uF002" : "\uF002"
          color: Zenon.sand
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 15
        }

        // Which of the two searches this is, and where. `s` walks names and
        // `S` reads contents; they take the same field and produce very
        // different answers, so the bar says which one is armed.
        Text {
          id: searchLabel
          anchors.left: searchGlyph.right
          anchors.leftMargin: 10
          anchors.verticalCenter: parent.verticalCenter
          text: (searchBar.mode === "grep" ? "contents" : "names") + " in"
          color: Zenon.muted
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 14
        }

        Text {
          id: searchWhere
          anchors.left: searchLabel.right
          anchors.leftMargin: 8
          anchors.verticalCenter: parent.verticalCenter
          text: Terminus.basename(root.cwd) || "/"
          color: Zenon.keyInk
          font.family: "JetBrainsMono Nerd Font Propo"
          font.weight: Font.Bold
          font.pixelSize: 14
        }

        TextInput {
          id: searchField
          anchors.left: searchWhere.right
          anchors.leftMargin: 14
          anchors.right: searchHint.left
          anchors.rightMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          color: Zenon.white
          selectionColor: Zenon.selBg
          selectedTextColor: Zenon.white
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 16
          clip: true

          Keys.onReturnPressed: (e) => { e.accepted = true; searchBar.run(); }
          Keys.onEnterPressed: (e) => { e.accepted = true; searchBar.run(); }
          Keys.onEscapePressed: (e) => { e.accepted = true; searchBar.dismiss(); }
          // Tab flips between the two searches without retyping the query,
          // which is most of what the second one is for.
          Keys.onPressed: (e) => {
            if (e.key !== Qt.Key_Tab) return;
            e.accepted = true;
            searchBar.mode = searchBar.mode === "grep" ? "find" : "grep";
          }

          // ONE cursor, and the field's own.
          //
          // There were two: a hand-drawn bar placed at contentWidth, and
          // TextInput's built-in caret underneath it in the text colour. Two
          // cursors is one too many, and the drawn one was in the wrong place
          // the moment you moved the caret into the middle of a word — it
          // measures the whole string, not the position.
          //
          // A cursorDelegate REPLACES the built-in one, so there is exactly
          // one and the field itself decides where it goes. It breathes rather
          // than blinking: a hard on/off in a bar that is already asking for
          // your attention reads as a fault.
          cursorDelegate: Rectangle {
            width: 2
            color: Zenon.cyan
            SequentialAnimation on opacity {
              running: searchField.activeFocus
              loops: Animation.Infinite
              NumberAnimation { to: 0.2; duration: 620; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 1.0; duration: 620; easing.type: Easing.InOutQuad }
            }
          }
        }

        Text {
          id: searchHint
          anchors.right: parent.right
          anchors.rightMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          text: "tab switches  ·  esc cancels"
          color: Zenon.msgBorder
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 12
        }

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
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
        // ONE PANE ONLY. With two, each carries its own heading bar inside its
        // own half — because each has its own view, and a strip up here can be
        // only one height for both. A grid beside a list would have had a
        // 22px band of nothing over the grid, which is what it looked like:
        // a sort bar placeholder.
        height: root.viewMode === "list" && !root.dual ? 22 : 0
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
        //
        // Over the ACTIVE pane, wherever that is; only when that pane is a
        // list; and the SAME ColHeadBar the two-pane case draws inside each
        // half, so there is one definition of what a heading row is.
        ColHeadBar {
          x: side.width + root.activePaneX
          width: root.activePaneW
          height: parent.height
          visible: root.viewMode === "list"
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
        id: bodyRow
        width: parent.width
        height: parent.height - tabStrip.height - crumbBar.height
          - searchBar.height - colHeads.height - portalBar.height

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
                  label: Terminus.basename(modelData)
                  glyph: "\uF02E"
                  active: modelData === root.cwd
                  showRemove: true
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
                    : Terminus.basename(modelData.path)
                  // Free space when it is mounted, total size when it is not.
                  // "412G free" is the number you actually want before copying
                  // to a disk; the capacity only matters when you cannot yet
                  // see inside it. lsblk supplies both, so neither costs a
                  // process.
                  detail: modelData.mount !== "" && modelData.avail !== ""
                    ? modelData.avail + " free" : modelData.size
                  used: Terminus.usedFraction(modelData.avail, modelData.fsSize)
                  glyph: modelData.removable ? "\uF0A0" : "\uF1C0"
                  active: modelData.mount !== "" && root.cwd.indexOf(modelData.mount) === 0
                  // a mounted disk is a place; an unmounted one is a button
                  mounted: modelData.mount !== ""
                  // no eject on the mounts the system is standing on
                  showMount: !Terminus.isSystemMount(modelData.mount)
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

        Item {
          id: bodyBox
          width: parent.width - side.width
          height: parent.height

          // 22px of headings when this half is a list, nothing when it is not.
          // With one pane the strip above the body does this job; with two it
          // has to happen in here, per pane, or the two halves cannot differ.
          readonly property real headH:
            root.dual && root.viewMode === "list" ? 22 : 0
          readonly property real topH: bodyBox.headH

          ColHeadBar {
            x: root.activePaneX
            width: root.activePaneW
            visible: bodyBox.headH > 0
            z: 3
          }

          // ── the divider, as something you can grab ────────────────
          // Not a child of the sidebar: `side` clips, so a handle inside it
          // could only ever be as wide as the 1px line it sits on. So it
          // overlays the seam from INSIDE the body instead.
          //
          // It used to sit in the Row between the sidebar and the body, which is
          // the one place it must not be: a Row lays out every visible child, so
          // the 9px handle was 9px of layout. The body was pushed 9px right of
          // the sidebar and, being sized as `parent.width - side.width`, ran 9px
          // off the right-hand edge of the window — which is why the preview
          // pane had 12px of padding down its left side and 3px down its right.
          // A child of bodyBox costs the Row nothing.
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
            // Straddling the divider, half either side — and measured from
            // bodyBox's own left edge, which IS the divider, so this no longer
            // has to follow side.width at all.
            x: -4

            // Where in the grip it was taken hold of, so the seam stays under
            // the same part of the pointer for the whole drag.
            property real grab: 0

            // Measured in bodyRow's coordinates, never in the grip's own.
            //
            // The grip travels with the divider, so while you drag it slides
            // along underneath the pointer — and a delta taken from `m.x` is
            // measured against an origin that is itself moving. Each frame
            // overshot and the next corrected, which is what made the divider
            // jitter. bodyRow does not move, so a position mapped into it is
            // stable.
            onPressed: (m) => {
              sideGrip.grab = m.x;
            }
            onPositionChanged: (m) => {
              if (!sideGrip.pressed) return;
              const px = sideGrip.mapToItem(bodyRow, m.x, 0).x;
              root.sidebarWidth = Math.max(root.sidebarMin,
                Math.min(root.sidebarMax, px - sideGrip.grab + 4));
            }
            // Double click springs it back, so a width dragged somewhere silly is
            // one gesture to undo rather than a careful drag back.
            onDoubleClicked: root.sidebarWidth = 200
          }

        // Ctrl+wheel zooms — see the overlay at the bottom of this Item.
        // It cannot live here: a pointer handler on a parent is only offered
        // an event after every child has declined it, and all three views are
        // Flickables that handle the wheel themselves. So this container's own
        // handler was never reached and the gesture did nothing.

        // ── list ────────────────────────────────────────────────────
        ListView {
          id: list

          // Placed rather than filled, because the second pane takes the
          // other half and either half can be the active one. With one pane
          // activePaneX is 0 and activePaneW is the body's width, so this is
          // the old anchors.fill written out.
          x: root.activePaneX
          y: bodyBox.topH
          width: root.activePaneW
          height: parent.height - bodyBox.topH
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
            dim: !!root.cutSet[modelData.path]
            live: true
            showMeta: list.width >= root.metaMinWidth
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
          x: root.activePaneX
          y: bodyBox.topH
          width: root.activePaneW
          height: parent.height - bodyBox.topH
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
              dim: !!root.cutSet[modelData.path]
              live: true
              ticked: !!root.marked[modelData.path]
              // No metadata for a DIRECTORY, where the name says everything
              // this narrow a column has room to say — but results are not a
              // directory, and two of them can share a name. See colFoundNarrow.
              showMeta: root.searchMode !== ""
              whereOnly: true
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

            // ── a picture or a film, and what it IS ────────────────────
            // Anchored to the TOP of the pane rather than centred in it,
            // because the facts underneath are part of the preview now. A
            // frame floating in the middle with a block of text below it reads
            // as two unrelated things, and worse, both of them move: every
            // change of aspect ratio slid the metadata up or down the pane.
            //
            // Rounded the same 5px as the grid tiles, and for the same reason
            // the note over thumbClip gives — the corners belong on the frame,
            // never on the pane it is letterboxed inside.
            Column {
              id: media
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.margins: 16
              // A touch tighter at the top than at the sides: the bar above is a hard
              // edge and the pane's own left divider is not, so an equal 16 read as
              // more air above than beside.
              anchors.topMargin: 12
              spacing: 10
              visible: root.previewKind === "image" || root.previewKind === "video"
                || root.previewKind === "audio"

              // The frame gets at most this much of the pane and the rest
              // belongs to the facts. Uncapped, a tall photograph filled the
              // pane on its own and pushed every row of metadata off the
              // bottom of it.
              readonly property real boxW: media.width
              readonly property real boxH: Math.max(80, previewPane.height * 0.56)

              ClippingRectangle {
                id: mediaClip
                anchors.horizontalCenter: parent.horizontalCenter
                visible: shot.status === Image.Ready
                color: "transparent"
                radius: 5

                // The aspect ratio comes from the Image's IMPLICIT size, the
                // decoded source, and never from paintedWidth/paintedHeight —
                // the painted size follows the item's own, which is this
                // rectangle's, and reading it here would be a binding loop.
                readonly property real ar:
                  shot.implicitWidth > 0 && shot.implicitHeight > 0
                    ? shot.implicitWidth / shot.implicitHeight : 1
                width: Math.max(1, Math.min(media.boxW, media.boxH * mediaClip.ar))
                height: Math.max(1, Math.min(media.boxH, media.boxW / mediaClip.ar))

                Image {
                  id: shot
                  anchors.fill: parent
                  // One Image for both kinds, because they differ only in
                  // where the pixels come from: a picture is shown as itself,
                  // a video as the frame ffmpeg pulled out of it for the grid.
                  //
                  // The row is re-checked here, not just previewKind. Moving
                  // the cursor changes the row a frame before loadPreview has
                  // decided what the new one is, so for that frame this
                  // binding asked for a DIRECTORY as an image and Qt logged
                  // "Cannot open: file:///home/buck/Desktop" every time the
                  // cursor passed one.
                  source: {
                    const r = root.currentRow();
                    if (!r || r.isDir) return "";
                    // a video's frame and an audio file's cover both live in
                    // the thumbnail cache; a picture is shown as itself
                    if (root.previewKind === "video"
                        || root.previewKind === "audio") {
                      return root.thumbFile[r.path]
                        ? "file://" + root.thumbFile[r.path] : "";
                    }
                    if (root.previewKind !== "image") return "";
                    return Terminus.isImage(r.name) ? "file://" + r.path : "";
                  }
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  // capped rather than full-size: a 6000px wallpaper decoded
                  // at native resolution to fill a 300px pane is most of a
                  // second and a lot of memory for a picture nobody is
                  // looking at yet
                  sourceSize.width: 900
                  sourceSize.height: 900
                }
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: {
                  const r = root.currentRow();
                  return r ? r.name : "";
                }
                elide: Text.ElideMiddle
                color: Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: Font.Bold
                font.pixelSize: 17
              }

              Rectangle {
                width: parent.width
                height: 1
                color: Zenon.msgBorder
              }

              Column {
                width: parent.width
                spacing: 3

                Repeater {
                  // Every property this reads is named here on purpose: a
                  // binding re-evaluates when a PROPERTY it touched changes,
                  // and currentRow() is a function call, which is not one.
                  // Without `sel` and `view` in the expression the panel kept
                  // the first file's size and date for the whole folder.
                  model: {
                    const kind = root.previewKind;
                    const info = root.previewInfo;
                    const at = root.sel;
                    const all = root.view;
                    if (kind !== "image" && kind !== "video" && kind !== "audio")
                      return [];
                    const r = root.currentRow();
                    if (!r) return [];
                    const out = [];
                    const dot = "  \u00b7  ";
                    const add = (k, v) => { if (v) out.push([k, v]); };
                    if (info && info.dims) out.push(["dimensions", info.dims]);
                    if (kind === "video" && info) {
                      add("duration", info.duration);
                      add("codec", info.codec
                        + (info.container ? dot + info.container : ""));
                      add("frame rate", info.fps);
                      add("bitrate", info.bitrate);
                    } else if (kind === "audio" && info) {
                      // the tags first: on a track they are the answer, and
                      // the codec is the footnote
                      add("title", info.title);
                      add("artist", info.artist);
                      add("album", info.album
                        + (info.date ? dot + info.date : ""));
                      add("track", info.track);
                      add("duration", info.duration);
                      add("codec", info.codec
                        + (info.container ? dot + info.container : ""));
                      add("audio", [info.rate, info.channels]
                        .filter((x) => !!x).join(dot));
                      add("bitrate", info.bitrate);
                    } else if (info) {
                      add("format", info.format);
                      add("colour", [info.depth, info.colorspace]
                        .filter((x) => !!x).join(dot));
                    }
                    out.push(["size", Terminus.formatSize(r.size)]);
                    out.push(["modified", Terminus.formatTime(r.mtime)]);
                    return out;
                  }

                  delegate: Row {
                    required property var modelData
                    width: media.width
                    height: 24
                    spacing: 10

                    Text {
                      // wide enough for "frame rate", the longest label any of
                      // these rows carries, at this size
                      width: 102
                      height: parent.height
                      horizontalAlignment: Text.AlignRight
                      verticalAlignment: Text.AlignVCenter
                      text: modelData[0]
                      color: Zenon.muted
                      font.family: "JetBrainsMono Nerd Font Propo"
                      font.pixelSize: 16
                    }

                    Text {
                      width: media.width - 112
                      height: parent.height
                      verticalAlignment: Text.AlignVCenter
                      text: modelData[1]
                      elide: Text.ElideRight
                      color: Zenon.white
                      font.family: "JetBrainsMono Nerd Font Propo"
                      font.pixelSize: 16
                    }
                  }
                }
              }
            }

            // ── a typeface, in its own hand ────────────────────────────
            // Every other preview describes the file. This one IS it: Qt loads
            // the face and draws the specimen with it, which answers "what
            // does this look like" in a way no list of facts about a font ever
            // could.
            //
            // FontLoader reads the file on the fly and leaves nothing behind —
            // the family it registers lives only as long as the loader does,
            // so browsing a folder of fonts does not install any of them.
            Column {
              id: fontPane
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.margins: 16
              // A touch tighter at the top than at the sides: the bar above is a hard
              // edge and the pane's own left divider is not, so an equal 16 read as
              // more air above than beside.
              anchors.topMargin: 12
              spacing: 12
              visible: root.previewKind === "font"

              FontLoader {
                id: face
                source: {
                  const r = root.currentRow();
                  if (!r || r.isDir || root.previewKind !== "font") return "";
                  return "file://" + r.path;
                }
              }

              readonly property bool ready: face.status === FontLoader.Ready
              // The family NAME as the file declares it, which is very often
              // not what the file is called.
              readonly property string family: fontPane.ready ? face.font.family : ""

              Text {
                width: parent.width
                text: fontPane.ready ? fontPane.family : "could not read this font"
                elide: Text.ElideRight
                color: fontPane.ready ? Zenon.white : Zenon.muted
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: Font.Bold
                font.pixelSize: 17
              }

              Rectangle {
                width: parent.width
                height: 1
                color: Zenon.msgBorder
              }

              Repeater {
                // Sizes as well as letters, because a face that reads well at
                // 28px can be mud at 13 and that is the thing worth knowing
                // before choosing one.
                model: fontPane.ready ? [
                  ["Sphinx of black quartz, judge my vow", 30],
                  ["ABCDEFGHIJKLMNOPQRSTUVWXYZ", 20],
                  ["abcdefghijklmnopqrstuvwxyz", 20],
                  ["0123456789  &@#$%  .,;:!?  ()[]{}", 20],
                  ["The quick brown fox jumps over the lazy dog", 15],
                  ["The quick brown fox jumps over the lazy dog", 12]
                ] : []

                delegate: Text {
                  required property var modelData
                  width: fontPane.width
                  text: modelData[0]
                  wrapMode: Text.Wrap
                  color: Zenon.white
                  font.family: fontPane.family
                  font.pixelSize: modelData[1]
                }
              }
            }

            // SCROLLABLE, because a preview that only ever shows the first
            // screenful is a preview of the top of a file. bat is asked for a
            // capped number of lines either way, but forty lines in a pane
            // twenty deep is half an answer, and an archive listing is nearly
            // always longer than the pane.
            //
            // Wheel and drag both work because it is a Flickable; the rail
            // beside it is the same one every other view here uses.
            Flickable {
              id: textScroll
              anchors.fill: parent
              anchors.margins: 16
              // A touch tighter at the top than at the sides: the bar above is a hard
              // edge and the pane's own left divider is not, so an equal 16 read as
              // more air above than beside.
              anchors.topMargin: 12
              visible: root.previewKind === "text" || root.previewKind === "archive"
              clip: true
              interactive: true
              boundsBehavior: Flickable.StopAtBounds
              contentWidth: Math.max(width, previewBody.implicitWidth)
              contentHeight: previewBody.implicitHeight
              // back to the top whenever the pane is showing something else
              onVisibleChanged: if (!visible) contentY = 0;

              Text {
                id: previewBody
                width: textScroll.width
                text: root.previewText
                // RichText, because bat's colours arrive as ANSI and are
                // translated rather than thrown away — that is the syntax
                // highlighting, and markdown comes through the same path
                textFormat: Text.RichText
                color: Zenon.white
                wrapMode: Text.NoWrap
                font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: Math.round(17 * root.zoom)
              }
            }

            // A new file starts at the top of itself, not wherever the last
            // one was left. previewText changes for every row the cursor
            // lands on, so this is the moment to reset.
            Connections {
              target: root
              function onPreviewTextChanged() { textScroll.contentY = 0; }
            }

            ScrollRail {
              target: textScroll
              on: textScroll.visible
              anchors.top: textScroll.top
              anchors.bottom: textScroll.bottom
              x: textScroll.x + textScroll.width - width - 2
            }

            Image {
              anchors.fill: parent
              anchors.margins: 16
              // A touch tighter at the top than at the sides: the bar above is a hard
              // edge and the pane's own left divider is not, so an equal 16 read as
              // more air above than beside.
              anchors.topMargin: 12
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
              font.pixelSize: 13
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

          x: root.activePaneX
          y: bodyBox.topH
          width: root.activePaneW
          height: parent.height - bodyBox.topH
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

          delegate: Tile {
            id: tileItem
            required property var modelData
            required property int index
            width: grid.cellWidth
            height: grid.cellHeight
            entry: modelData
            current: index === root.sel
            dim: !!root.cutSet[modelData.path]
            ticked: !!root.marked[modelData.path]
            live: true
            onChosen: (right, shift, ctrl, mx, my) => {
              root.clickRow(index, right, shift, ctrl);
              if (right) root.openMenuAt(tileItem, { x: mx, y: my });
            }
            onOpened: { root.sel = index; root.activate(); }
            onTabbed: if (modelData.isDir) root.openInNewTab(modelData.path)
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

        // ── the second pane ─────────────────────────────────────────
        // Deliberately plain. It shows a directory, a cursor and its columns,
        // and nothing else: no filter, no marks, no preview, no view modes.
        // Everything a pane can DO belongs to the active one, and Tab, `o` or
        // a click in here is how this side becomes that.
        // The same neutral border every other seam in this window uses. A cyan
        // one was tried and read as decoration rather than structure — cyan
        // here means "chosen", and a line that is always there is not making a
        // choice. The CHEVRON on it is cyan, which is the one thing that is.
        Rectangle {
          width: 1
          height: parent.height
          x: root.paneSplit
          visible: root.dual
          color: Zenon.msgBorder
        }

        // The divider, as something you can take hold of. The sidebar's grip in
        // every respect — 9px straddling a 1px line, z above the body so the
        // cursor changes over the seam, and measured in a frame that does NOT
        // move: bodyBox's own width is fixed while the split is dragged, and
        // reading the delta off the grip would be reading it against an origin
        // sliding under the pointer.
        MouseArea {
          id: splitGrip
          width: 9
          height: parent.height
          x: root.paneSplit - 4
          z: 9
          visible: root.dual
          hoverEnabled: true
          cursorShape: Qt.SizeHorCursor
          preventStealing: true

          property real grab: 0
          onPressed: (m) => { splitGrip.grab = m.x; }
          onPositionChanged: (m) => {
            if (!splitGrip.pressed || bodyBox.width <= 0) return;
            const px = splitGrip.mapToItem(bodyBox, m.x, 0).x - splitGrip.grab + 4;
            root.paneFrac = Math.max(root.paneMinFrac,
              Math.min(root.paneMaxFrac, px / bodyBox.width));
            viewSave.restart();
          }
          // back to even, the way the sidebar's grip springs back to 200
          onDoubleClicked: { root.paneFrac = 0.5; viewSave.restart(); }
        }

        // Which side the keyboard is in, as a chevron ON the divider.
        //
        // It was a hairline around the whole active half, which is a lot of
        // line for one bit of information and put a cyan rectangle around a
        // grid of pictures. The divider is already the boundary between the
        // two, so the mark belongs on it: `❮|` the left side has the keyboard,
        // `|❯` the right one does.
        //
        // Both panes still say it a second way — the inactive one's cursor is
        // an outline rather than a fill — so the chevron is the confirmation,
        // not the only clue.
        Text {
          id: paneMark
          visible: root.dual
          text: root.paneSide === 1 ? "\u276F" : "\u276E"
          color: Zenon.cyan
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 13
          y: (parent.height - height) / 2
          x: root.paneSide === 1
            ? root.paneSplit + 4 : root.paneSplit - width - 3
          z: 4
        }

        Item {
          id: otherPane
          x: root.otherPaneX
          width: root.otherPaneW
          height: parent.height
          visible: root.dual
          clip: true

          // its own headings, on the same rule as the active half's
          ColHeadBar {
            id: otherHeads
            width: parent.width
            visible: root.otherViewMode === "list"
            live: false
            z: 3
          }

          ListView {
            id: otherList
            // Under its own headings when it has them, flush with the top when
            // it does not — which is what keeps two lists on the same lines
            // and lets a grid beside a list start where a grid should.
            anchors.top: parent.top
            anchors.topMargin: otherHeads.visible ? otherHeads.height : 0
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            visible: root.otherViewMode === "list"
            model: root.dual && root.otherViewMode === "list" ? root.otherRows : []
            reuseItems: true
            boundsBehavior: Flickable.StopAtBounds

            delegate: EntryRow {
              required property var modelData
              required property int index
              width: otherList.width
              entry: modelData
              current: index === root.otherSel
              dim: !!root.cutSet[modelData.path]
              showMeta: otherList.width >= root.metaMinWidth
              // Marks live on the active side only, so a row over here is
              // never ticked — the cursor is the whole of its state, and it is
              // drawn as an outline rather than a fill so it cannot be taken
              // for one.
              ticked: false
              passive: true
              // A single click steps into this pane AT this row, which is what
              // makes the two sides interchangeable rather than one of them
              // being second class.
              actionable: false
              onChosen: root.enterOther(index)
              onOpened: { root.enterOther(index); root.activate(); }
              onTabbed: if (modelData.isDir) root.openInNewTab(modelData.path)
            }
          }

          // The same grid the active pane draws, from the same Tile — because
          // the whole point of the second pane is that it is a pane. It keeps
          // ITS view when you step away: a folder of pictures stays a folder
          // of pictures whichever side the keyboard is on.
          GridView {
            id: otherGrid
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            visible: root.otherViewMode === "grid"
            model: root.dual && root.otherViewMode === "grid" ? root.otherRows : []
            reuseItems: true
            boundsBehavior: Flickable.StopAtBounds

            // its own zoom, the active grid's arithmetic
            readonly property int targetCell: Math.round(190 * root.otherThumbZoom)
            cellWidth: Math.floor(otherGrid.width
              / Math.max(1, Math.round(otherGrid.width / otherGrid.targetCell)))
            cellHeight: Math.round(168 * root.otherThumbZoom)

            delegate: Tile {
              required property var modelData
              required property int index
              width: otherGrid.cellWidth
              height: otherGrid.cellHeight
              entry: modelData
              current: index === root.otherSel
              dim: !!root.cutSet[modelData.path]
              ticked: false
              passive: true
              tileZoom: root.otherThumbZoom
              onChosen: (right, shift, ctrl, mx, my) => root.enterOther(index)
              onOpened: { root.enterOther(index); root.activate(); }
              onTabbed: if (modelData.isDir) root.openInNewTab(modelData.path)
            }
          }

          ScrollRail {
            target: otherGrid
            on: root.dual && root.otherViewMode === "grid"
            anchors.top: otherGrid.top
            anchors.topMargin: 2
            anchors.bottom: otherGrid.bottom
            anchors.bottomMargin: 2
            x: otherPane.width - width - 2
          }

          // Anywhere in this pane, not only on a row: clicking the empty
          // space below the last one is still saying "I want to be over
          // here".
          //
          // Above the ListView rather than under it, because a Flickable takes
          // the left button for its own flick and never gives it back — the
          // same reason the active pane's empty-space click had to move above
          // its views. Gated on the hover hit test so a press that IS on a row
          // reaches the row and steps across once, not twice.
          property bool overRow: false

          HoverHandler {
            id: otherWatch
            onPointChanged: {
              const v = root.otherViewMode === "grid" ? otherGrid : otherList;
              otherPane.overRow = v.indexAt(
                otherWatch.point.position.x - v.x + v.contentX,
                otherWatch.point.position.y - v.y + v.contentY) >= 0;
            }
          }

          MouseArea {
            anchors.fill: parent
            enabled: root.dual && !otherPane.overRow
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: root.stepOver()
          }

          ScrollRail {
            target: otherList
            on: root.dual && root.otherViewMode === "list"
            anchors.top: otherList.top
            anchors.topMargin: 2
            anchors.bottom: otherList.bottom
            anchors.bottomMargin: 2
            x: otherPane.width - width - 2
          }

          // The same word at the same size as the active pane's — see the
          // note there. Two panes saying the same thing two different ways
          // reads as two different states.
          Text {
            anchors.centerIn: parent
            visible: root.dual && root.otherRows.length === 0
            text: "Empty"
            color: Zenon.muted
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: Font.Bold
            font.pixelSize: 15
          }
        }

        // ── dropping onto this directory ────────────────────────────
        // ONE DropArea, and that is the fix.
        //
        // There were two, stacked on the same rectangle with the same keys: the
        // real one, and a second declared later that existed only to light up
        // the border. Later means on top, and the top DropArea is the one Qt
        // delivers to — so every drop landed on the decorative one, which had
        // no onDropped and quietly dropped it on the floor. Dragging a file
        // from artemis into terminus did nothing for exactly this reason.
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
          // WHERE it was dropped decides where it goes. With one pane that is
          // always here; with two, dropping on the right-hand side means the
          // right-hand side, which is most of what a second pane is for.
          // Tracked as the pointer moves so the row under it can light up:
          // a drop that is about to go INTO something has to say which thing,
          // or the only honest reading is "somewhere in this pane".
          onPositionChanged: (d) => root.dropDir = root.dropDirAt(d.x, d.y)
          onExited: root.dropDir = ""

          onDropped: (d) => {
            const pane = root.dual && (d.x < root.activePaneX
                                       || d.x > root.activePaneX + root.activePaneW)
              ? root.otherCwd : root.cwd;
            const into = root.dropDir !== "" ? root.dropDir : pane;
            root.dropDir = "";
            root.dropUris(d.urls, d.proposedAction, into);
          }
        }

        Rectangle {
          anchors.fill: parent
          // Not while a directory is the target: two things lit at once says
          // the drop is going to both.
          visible: dropHint.containsDrag && root.dropDir === ""
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
          //
          // `overBandZone` is the third condition, and it is about COLUMNS
          // view: of its three panes only the middle one holds rows this
          // window can select. A press in the preview started a band that
          // could never select anything and drew a box over a picture to say
          // so; the left-hand pane is the parent directory and is no better.
          enabled: band.active
            || (!root.hoverRow && root.overBandZone && !root.railDragging
                && !root.modal)
          grabPermissions: PointerHandler.CanTakeOverFromAnything

          // Where a band is allowed to be drawn: the whole body in list and
          // grid view, the middle column alone in columns view.
          readonly property real zoneL: root.activePaneX
            + (root.viewMode === "columns" ? midList.x : 0)
          readonly property real zoneR: root.activePaneX
            + (root.viewMode === "columns"
              ? midList.x + midList.width : root.activePaneW)

          // Clamped to that zone. bodyBox does not clip, so a drag carried
          // past its left edge drew the selection box out over the sidebar —
          // the rectangle was honest about the pointer and wrong about what it
          // was selecting from, since there is nothing selectable over there.
          readonly property real x1: Math.max(band.zoneL,
            Math.min(centroid.pressPosition.x, centroid.position.x))
          readonly property real y1: Math.max(0,
            Math.min(centroid.pressPosition.y, centroid.position.y))
          readonly property real x2: Math.min(band.zoneR,
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
              // COLLAPSE THE OLD RECTANGLE FIRST.
              //
              // `held` survives a release on purpose, so the box has a shape
              // to fade out from — but it also survived into the NEXT gesture,
              // and opacity goes to 1 the instant the band activates. So a
              // band that activated and had not yet been dragged anywhere drew
              // the PREVIOUS box, at the previous place, for a frame.
              //
              // That is the ghost: press on a selected row and move fast, and
              // hoverRow has not caught up, so this handler — which may take
              // the grab from anything — wins the gesture for a moment before
              // the row drag claims it, just long enough to flash the last
              // rectangle back onto the screen.
              band.held = Qt.rect(band.x1, band.y1, 0, 0);
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
          // A rectangle with no shape is not drawn at all, so a stale one can
          // never appear and the fade only ever runs on something real.
          visible: opacity > 0.01 && band.held.width > 2 && band.held.height > 2
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
        // dragging a file out of terminus produced no drag at all. Declining the
        // press with `accepted = false` was not enough: by then the overlay had
        // already won the gesture.
        //
        // It asks the view's own indexAt rather than reading hoverRow, for the
        // reason rowUnder exists.
        HoverHandler {
          id: emptyWatch
          onPointChanged: {
            const px = emptyWatch.point.position.x;
            root.overEmpty = root.rowUnder(px, emptyWatch.point.position.y) < 0;
            // The rubber band cannot ask where the pointer is — a DragHandler
            // has a position only once it is already dragging — so the hover
            // that is watching anyway answers for it.
            root.overBandZone = px >= band.zoneL && px <= band.zoneR;
          }
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
          // entitled to — including the one that becomes a drag out of terminus.
          enabled: root.overEmpty
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: (m) => {
            if (m.button === Qt.RightButton) { menu.openHere(bodyBox, m); return; }
            if (Object.keys(root.marked).length > 0) root.marked = {};
            content.forceActiveFocus();
          }
        }

        // Centred in the ACTIVE PANE, not in the body. With two panes open the
        // body is both of them, so an empty directory on one side put its
        // label in the middle of the window — half of it hanging over the
        // other pane's rows, saying "Empty" about a listing that was not.
        Text {
          x: root.activePaneX + (root.activePaneW - width) / 2
          y: (parent.height - height) / 2
          visible: root.view.length === 0
          text: root.query !== "" ? "No matches" : "Empty"
          color: Zenon.muted
          font.family: "JetBrainsMono Nerd Font Propo"
          font.weight: Font.Bold
          font.pixelSize: 15
        }
        }
      }


      // ── the picker's own footer ───────────────────────────────────
      // Only while a portal request is open. It is deliberately the widest
      // thing on screen and sits directly above the hints: an application is
      // blocked waiting on this, so what terminus is being asked for has to be
      // impossible to miss.
      Rectangle {
        id: portalBar
        width: parent.width
        height: root.picking ? 44 : 0
        visible: height > 0
        clip: true
        color: Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.10)

        // The neutral seam every other strip in this window uses. A cyan rule
        // here was the loudest line on the surface, for a bar that is already
        // tinted and already says what it is.
        Rectangle {
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: 1
          color: Zenon.msgBorder
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
          font.pixelSize: 15
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
          border.color: Terminus.nameError(saveField.text) === ""
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
            font.pixelSize: 14
            clip: true
            Keys.onReturnPressed: (e) => { e.accepted = true; root.portalConfirm(); }
            Keys.onEscapePressed: (e) => { e.accepted = true; root.portalCancel(); }
          }
        }

        // what a confirm would actually hand over, spelled out, because the
        // difference between "this directory" and "the directory under the cursor"
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
          font.pixelSize: 13
        }

        Row {
          id: portalButtons
          anchors.right: parent.right
          anchors.rightMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8

          DialogButton {
            label: "Cancel"
            ink: Zenon.muted
            onClicked: root.portalCancel()
          }

          DialogButton {
            label: (!!root.portal && root.portal.save) ? "Save" : "Choose"
            ink: Zenon.cyan
            ready: root.portalChoice.length > 0
            primary: root.portalChoice.length > 0
            onClicked: root.portalConfirm()
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
        props.show(sel);
      }

      // Properties of THE DIRECTORY YOU ARE IN, which is what a right click on
      // empty space is asking about — there is no row selected and the one the
      // cursor happens to be on is not the answer.
      //
      // It needs a row object and the listing has none: the listing is of this
      // directory's CHILDREN. So one is made the same way a search result's
      // is, out of `stat` — the same command, parser and enrich the results
      // path already uses, so the card gets a row indistinguishable from one
      // that came out of a listing.
      function askPath(path) {
        if (path === "" || hereProc.running) return;
        props.wantPath = path;
        hereProc.command = Terminus.statArgv([path]);
        hereProc.running = true;
      }

      property string wantPath: ""

      function show(sel) {
        props.rows = sel;
        props.owner = "";
        props.walked = -1;
        props.open = true;
        // only when there is a directory in the set: for plain files the size
        // is already known and du would be a process for nothing
        if (sel.some((r) => r.isDir)) {
          sizeProc.command = ["sh", "-c",
            Terminus.sizeCommand(sel.map((r) => r.path))];
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
        // The thumbnail panel above shows a video's frame or a track's cover
        // from the same cache the grid uses — which may not have been asked
        // for yet if you have only ever seen this directory as a list.
        const one = props.many ? null : sel[0];
        if (one && !one.isDir && !root.thumbFile[one.path]
            && (Terminus.isVideo(one.name) || Terminus.isAudio(one.name))
            && !thumbProc.running) {
          root.thumbJobs = [{ src: one.path,
                              kind: Terminus.isVideo(one.name) ? "v" : "a" }];
          thumbProc.command = ["sh", "-c", Thumbs.generate(root.thumbJobs)];
          thumbProc.running = true;
        }
        if (!props.many && !sel[0].isDir && Terminus.isImage(sel[0].name)) {
          imageProc.command = ["sh", "-c", Terminus.imageInfoCommand(sel[0].path)];
          imageProc.running = true;
        }
      }

      Process {
        id: hereProc
        stdout: StdioCollector {
          id: hereOut
          waitForEnd: true
          onStreamFinished: {
            const rows = root.enrich(Terminus.parseStat(hereOut.text));
            if (rows.length === 0) {
              root.status = "could not read " + Terminus.basename(props.wantPath);
              return;
            }
            props.show(rows);
          }
        }
      }

      function computeChecksum() {
        const r = props.rows[0];
        if (!r || r.isDir || sumProc.running) return;
        props.checksum = "\u2026";
        sumProc.command = ["sh", "-c", Terminus.checksumCommand(r.path)];
        sumProc.running = true;
      }

      InputShield {
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

        // the card keeps its own clicks — see InputShield
        InputShield {}

        Column {
          id: propsCol
          width: parent.width

          // THE THING, not the word. A card that says "Properties" is telling
          // you what you already know — you opened it — while the one fact it
          // is about, which file this is, was buried in the first row of the
          // table underneath. The name goes in the bar and the row comes out.
          //
          // And the bar is thinner for it: 34px of cyan under a 17px word was
          // a banner, and this is a caption.
          Rectangle {
            width: parent.width
            height: 26
            color: Zenon.cyan
            Text {
              anchors.fill: parent
              anchors.leftMargin: 14
              anchors.rightMargin: 14
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: props.many ? props.rows.length + " items"
                : (props.rows[0] ? props.rows[0].name : "Properties")
              // the middle of a long name is the part you can spare
              elide: Text.ElideMiddle
              color: Zenon.black
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 14
            }
          }

          Item { width: 1; height: 8 }

          // picture on the left, facts on the right
          Item {
            id: propBody
            width: parent.width
            height: Math.max(props.many ? 0 : 100, propFacts.implicitHeight)

            // What it LOOKS like, beside what it is.
            //
            // A picture or a video shows itself; a font shows its own A; anything
            // else shows the glyph the listing gives it, which is at least the
            // mark you picked the row out by. A multi-selection shows nothing at
            // all — there is no single thing to be a picture of, and the first
            // item's thumbnail standing in for eleven files would be a small lie
            // at the top of a panel of facts.
            //
            // Down the LEFT rather than across the top: the rows beside it are a
            // label column and a value column, and a picture over them pushed
            // every fact half a panel further down for no reason. On the left it
            // sits in the margin the labels already leave.
              Item {
              id: propShotBox
              anchors.left: parent.left
                anchors.leftMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                width: props.many ? 0 : 96
                height: 96
                visible: !props.many

              ClippingRectangle {
                id: propShotClip
                anchors.centerIn: parent
                visible: propShot.status === Image.Ready
                color: "transparent"
                radius: 5

                // sized from the decoded source, never from paintedWidth — the
                // note over the preview pane's thumbClip has the reason
                readonly property real ar:
                  propShot.implicitWidth > 0 && propShot.implicitHeight > 0
                    ? propShot.implicitWidth / propShot.implicitHeight : 1
                width: Math.max(1, Math.min(88, 88 * propShotClip.ar))
                height: Math.max(1, Math.min(88, 88 / propShotClip.ar))

                Image {
                  id: propShot
                  anchors.fill: parent
                  source: {
                    if (props.many || !props.open) return "";
                    const r = props.rows[0];
                    if (!r || r.isDir) return "";
                    if (Terminus.isVideo(r.name) || Terminus.isAudio(r.name)) {
                      return root.thumbFile[r.path]
                        ? "file://" + root.thumbFile[r.path] : "";
                    }
                    return Terminus.isImage(r.name) ? "file://" + r.path : "";
                  }
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  sourceSize.width: 256
                  sourceSize.height: 256
                }
              }

              FontLoader {
                id: propFace
                source: {
                  if (props.many || !props.open) return "";
                  const r = props.rows[0];
                  return r && !r.isDir && Terminus.isFont(r.name) ? "file://" + r.path : "";
                }
              }

              Text {
                anchors.centerIn: parent
                visible: !propShotClip.visible
                readonly property bool specimen: propFace.status === FontLoader.Ready
                text: {
                  const r = props.rows[0];
                  if (!r) return "";
                  return specimen ? "Ag" : r.glyph;
                }
                color: {
                  const r = props.rows[0];
                  return r ? root.inkFor(r) : Zenon.muted;
                }
                font.family: specimen ? propFace.font.family
                  : "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 56
              }
          }


            Column {
              id: propFacts
              anchors.left: props.many ? parent.left : propShotBox.right
              anchors.leftMargin: props.many ? 0 : 10
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

            Repeater {
              model: {
                const r = props.rows[0];
                if (!r) return [];
                if (props.many) {
                  let dirs = 0;
                  for (const x of props.rows) if (x.isDir) dirs++;
                  return [
                    ["items", props.rows.length + " (" + dirs + " directories)"],
                    ["total size", props.walked < 0
                      ? (dirs > 0 ? "measuring\u2026"
                          : Terminus.formatSize(props.total) + "  ·  " + props.total + " bytes")
                      : Terminus.formatSize(props.walked) + "  ·  " + props.walked + " bytes"],
                    ["location", Terminus.dirname(r.path)]
                  ];
                }
                // no "name" row: it is the card's own title now
                return [
                  ["location", Terminus.dirname(r.path)],
                  ["type", r.isDir ? "directory"
                    : (r.isLink ? "symbolic link"
                      : (Terminus.categoryOf(r.name) || (r.isExec ? "executable" : "file")))],
                  ["size", r.isDir
                    ? (props.walked < 0 ? "measuring\u2026"
                        : Terminus.formatSize(props.walked) + "  ·  " + props.walked + " bytes")
                    : Terminus.formatSize(r.size) + "  ·  " + r.size + " bytes"],
                  ["modified", Terminus.formatTime(r.mtime)],
                  ["owner", props.owner === "" ? "…" : props.owner],
                  ["permissions", ("000" + (r.mode & 511).toString(8)).slice(-3)
                    + "  " + Terminus.modeString(r.mode)]
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
                width: propFacts.width
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
                  font.pixelSize: 16
                }

                Text {
                  id: propValue
                  width: propFacts.width - 118 - 48
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
                  font.pixelSize: 16

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

            }
          }

          Item { width: 1; height: 10 }

          Rectangle {
            width: parent.width
            height: 1
            color: Zenon.msgBorder
          }

          Item {
            width: parent.width
            height: 46

            DialogButton {
              anchors.centerIn: parent
              label: "Close"
              ink: Zenon.cyan
              primary: true
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
          const verb = root.job.op === "copy" ? "Copying "
                     : root.job.op === "move" ? "Moving "
                     : root.job.op === "compress" ? "Compressing "
                     : "Extracting ";
          // "3/7" only when the job actually goes item by item; the single
          // rsync modes report one true percentage across the whole set, and a
          // counter beside that would be two different progresses at once.
          const at = root.job.entries > 0
            ? "  " + root.job.seen + "/" + root.job.entries
            : (root.job.index > 0
                ? "  " + root.job.index + "/" + root.job.total : "");
          const q = root.jobQueue.length > 0
            ? "  (+" + root.jobQueue.length + " queued)" : "";
          return verb + what + at + q;
        }
        elide: Text.ElideMiddle
        width: parent.width - 96
        color: Zenon.white
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: 15
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
        font.pixelSize: 15
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
          font.pixelSize: 15
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
      height: content.pending === "" ? 0 : whichFlow.implicitHeight + 20
      // one line, so the bar is a fixed depth whichever prefix is pending
      visible: height > 0
      clip: true
      z: 7
      // headBg, the same ground the breadcrumb and search strips stand on.
      // Bare black made this read as a hole in the window rather than as
      // another of its bars.
      color: Zenon.headBg
      Behavior on height { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

      Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        // the divider every other strip in this window is separated by
        color: Zenon.msgBorder
      }

      readonly property var entries:
        content.pending === "" ? [] : (content.sequences[content.pending] || [])

      // ── laid out by hand, so it can WRAP AND STILL BE CENTRED ────────
      //
      // This was a single Row that clipped at both ends when the set was wider
      // than the window — the reasoning being that a Flow can wrap but cannot
      // centre the lines it wraps, so a narrow window would trade a clipped
      // strip for a ragged block. Both halves of that are true, and clipping
      // is still the worse of the two: a hint you cannot see is not a hint.
      //
      // So the break points are worked out here rather than left to a Flow,
      // and each line is its own centred Row. FontMetrics measures the same
      // two fonts the delegates draw with, so the widths it adds up are the
      // widths that get drawn — the chip's padding is the one constant that
      // has to agree with KeyChip, and it is written down in both places.
      readonly property real chipPad: Math.round(13 * 1.15)
      readonly property real gap: 22
      readonly property real entryGap: 8

      FontMetrics {
        id: chipFm
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: 13
      }
      FontMetrics {
        id: labelFm
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: 15
      }

      function entryText(e) {
        return (typeof e[1] === "function") ? e[1]() : e[1];
      }
      function keyText(e) { return e[0] === " " ? "space" : e[0]; }

      function entryWidth(e) {
        return chipFm.advanceWidth(which.keyText(e)) + which.chipPad
          + which.entryGap + labelFm.advanceWidth(which.entryText(e));
      }

      // The entries grouped into the lines they will be drawn on. Greedy, which
      // is what you want here: the order is the order the keys are listed in,
      // so a line break must never reorder them to pack better.
      readonly property var lines: {
        const avail = which.width - 32;
        const out = [];
        let cur = [];
        let w = 0;
        for (const e of which.entries) {
          const ew = which.entryWidth(e);
          if (cur.length > 0 && w + which.gap + ew > avail) {
            out.push(cur);
            cur = [];
            w = 0;
          }
          w += (cur.length > 0 ? which.gap : 0) + ew;
          cur.push(e);
        }
        if (cur.length > 0) out.push(cur);
        return out;
      }

      Column {
        id: whichFlow
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 10
        spacing: 6

        Repeater {
          model: which.lines

          delegate: Row {
            required property var modelData
            anchors.horizontalCenter: parent.horizontalCenter
            // wider apart than the two halves of one entry, so a line reads as
            // separate hints rather than one long sentence
            spacing: which.gap

            Repeater {
              model: parent.modelData

              delegate: Row {
                required property var modelData
                spacing: which.entryGap

                KeyChip {
                  anchors.verticalCenter: parent.verticalCenter
                  fontSize: 13
                  // The KEY as something you can read, which is not always the
                  // key itself: the entry that opens the path bar is bound to a
                  // space, and a space drawn in the key column is a gap with a
                  // label floating after it. The binding stays a space — this
                  // is the name of it, not the match.
                  label: which.keyText(modelData)
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  // Static for nearly every entry, and worked out on the spot
                  // for the ones whose meaning depends on what the cursor is on.
                  text: which.entryText(modelData)
                  color: Zenon.white
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.pixelSize: 15
                }
              }
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
            // A GLYPH CANNOT BE TYPED, so it is searched by the word it
            // replaced. Turning "middle click" into a picture of a mouse made
            // this list better to read and impossible to search for "mouse" —
            // the labels beside those keys say "back / forward" and "actions
            // for the row", so the word had left the row entirely.
            const hay = (String(r[0]).split(root.mouseGlyph).join("mouse ")
              + " " + String(r[1])).toLowerCase();
            if (groupHit || hay.indexOf(q) >= 0)
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
                  [root.mouseGlyph + " 4 / 5", "back / forward"]]],
        ["select", [["space", "toggle and move on"],
                    ["v", "visual: extend as you move"],
                    ["ctrl a", "all"],
                    ["ctrl r", "invert"], ["esc", "leave visual, then clear"]]],
        ["act", [["y", "copy"], ["x", "cut"], ["p", "paste"],
                 ["d", "trash"], ["D", "delete for good"],
                 ["a", "create (end in / for a directory)"], ["r", "rename"],
                 ["c m", "permissions"], [";  ctrl s", "shell here"],
                 ["u", "undo trash / move / rename"],
                 ["z", "measure directory size"],
                 ["alt return", "properties"],
                 ["c a", "compress selection"]]],
        ["look", [["f  /", "filter"], ["s", "search names"],
                  ["S", "search contents"], [".", "hidden"],
                  [", n / s / m / k", "sort name / size / time / kind"],
                  [", !", "reverse"],
                  ["V", "view: columns · list · grid"], ["+ / -", "zoom"],
                  ["ctrl 0", "reset zoom"]]],
        ["go", [["g space", "go to\u2026 (tab completes)"],
                ["g h", "home"], ["g c", "config"], ["g d", "downloads"],
                ["g D", "documents"], ["g p", "pictures"], ["g v", "videos"],
                ["g t", "trash"], ["g m", "media"], ["g /", "root"]]],
        ["copy", [["c c", "full path"], ["c d", "directory"],
                  ["c f", "filename"], ["c n", "name without extension"]]],
        ["tabs", [["t", "new"], ["w", "close"], ["1 - 9", "switch"],
                  ["[  ]", "previous / next"]]],
        ["panes", [["\\", "second pane on / off"],
                   ["tab  o", "step into the other side"],
                   ["f5", "copy to the other side"],
                   ["f6", "move to the other side"],
                   [root.mouseKey(1), "step into the other side"]]],
        ["marks", [["b a", "bookmark this directory"],
                   ["b b", "bookmark the item under the cursor"]]],
        ["dialogs", [["esc", "close"], ["return", "accept"],
                     ["\u2190 \u2192 \u2191 \u2193", "move (permissions)"],
                     ["space", "toggle a bit"],
                     ["s", "checksum (properties)"]]],
        ["menu", [["menu key", "actions for the row"],
                  [root.mouseKey(2), "actions for the row"],
                  ["\u2014", "extract · compress · open with"],
                  ["\u2014", "bulk rename · links · restore"],
                  ["\u2014", "sort, as a submenu"]]],
        ["window", [["F1  ~", "this list"], ["q", "close"],
                    ["esc", "clear filter / selection"],
                    [root.mouseGlyph + " 4 / 5", "up / forward"]]]
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
        // Not `margins: 28` — that set the TOP to the side value too, and a
        // field sitting 28px down from the edge of a full-screen overlay reads
        // as having been pushed rather than placed. The sides still want the
        // wider gutter; the top does not.
        anchors.leftMargin: 28
        anchors.rightMargin: 28
        anchors.topMargin: 10
        // 40 was most of the gap on its own: the text sits in the MIDDLE of
        // this item, so half its height reads as padding above the words.
        height: 32

        Text {
          id: helpGlyph
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "\uf002"
          color: Zenon.muted
          font.family: "JetBrainsMono Nerd Font Mono"
          font.pixelSize: 17
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
          font.pixelSize: 18
          clip: true
          onTextChanged: help.helpQuery = text

          // Escape backs out one step at a time: it clears a search first, and
          // only closes the list once there is nothing to clear.
          Keys.onEscapePressed: (e) => {
            e.accepted = true;
            if (helpField.text !== "") helpField.text = "";
            else help.open = false;
          }
          // MOVING THROUGH THE LIST IS NOT LEAVING IT.
          //
          // A single-line TextInput does not consume Up and Down, so they went
          // on up to the window's own handler — where the rule is that any key
          // closes the keymap. Pressing down to look further along the list
          // therefore dismissed it, and because the field keeps its text the
          // panel came back exactly as it was, which made it look like the key
          // had done nothing at all rather than something wrong.
          //
          // They scroll it instead. Escape is untouched and still backs out one
          // step at a time; every other key still falls through and closes.
          Keys.onPressed: (e) => {
            if (e.key === Qt.Key_F1) { e.accepted = true; help.open = false; return; }
            const page = Math.max(60, helpScroll.height - 40);
            const step = (e.key === Qt.Key_Up) ? -30
                       : (e.key === Qt.Key_Down) ? 30
                       : (e.key === Qt.Key_PageUp) ? -page
                       : (e.key === Qt.Key_PageDown) ? page : 0;
            if (step === 0) return;
            e.accepted = true;
            const most = Math.max(0, helpScroll.contentHeight - helpScroll.height);
            helpScroll.contentY =
              Math.max(0, Math.min(most, helpScroll.contentY + step));
          }

          // The same breathing caret the search bar and the path bar use. A
          // cursorDelegate REPLACES the built-in one, so there is exactly one
          // and it is this; a hard blink in a field that is already asking for
          // your attention reads as a fault.
          cursorDelegate: Rectangle {
            width: 2
            color: Zenon.cyan
            SequentialAnimation on opacity {
              running: helpField.activeFocus
              loops: Animation.Infinite
              NumberAnimation { to: 0.2; duration: 620; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 1.0; duration: 620; easing.type: Easing.InOutQuad }
            }
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
          font.pixelSize: 15
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
        id: helpScroll
        anchors.top: helpSearch.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 28
        anchors.rightMargin: 28
        // 34 was the room the footer needed. With the footer gone it was a
        // black band under the last row with nothing in it.
        anchors.bottomMargin: 10
        contentHeight: helpGrid.implicitHeight
        clip: true

        Column {
          id: helpGrid
          width: parent.width

          Repeater {
            model: help.shownRows

            delegate: Item {
              id: helpRow
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

              // The key column, right-aligned so every chip ends on the same
              // line and the labels start on the next one.
              Item {
                id: helpKeyCol
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 150
                height: parent.height

                // Some rows under `menu` carry an em dash instead of a key —
                // they are continuations of the line above, "and also this".
                // A dash in a keycap would be claiming there is something to
                // press, so those stay plain text.
                readonly property bool pressable: helpRow.modelData[0] !== "\u2014"

                KeyChip {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: helpKeyCol.pressable
                  fontSize: 15
                  label: helpRow.modelData[0]
                }

                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !helpKeyCol.pressable
                  text: helpRow.modelData[0]
                  color: Zenon.muted
                  font.family: "JetBrainsMono Nerd Font Mono"
                  font.pixelSize: 17
                }
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
                font.pixelSize: 17
              }

              Text {
                id: helpSection
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: parent.starts ? modelData[2] : ""
                color: Zenon.cyan
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 14
              }
            }
          }
        }
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

      // NOTHING GETS PAST THE CARD. pathField handles what it wants and the
      // rest stops here rather than bubbling on to the listing's own key
      // handler, which would act on rows behind a dialog that has the screen.
      Keys.onPressed: (event) => { event.accepted = true; }

      // every directory in the directory currently being completed against
      property var names: []
      property int pick: -1

      readonly property var ctx:
        Terminus.completionContext(pathField.text, Paths.home(), root.cwd)
      readonly property var hits:
        Terminus.completionsFor(pathBar.namesText, pathBar.ctx.frag)
      property string namesText: ""

      // The part Tab would add: how far the candidates agree, minus what is
      // already typed. Empty when there is nothing to add, which is what makes
      // the ghost disappear the moment a name is complete.
      // With a candidate highlighted the ghost previews THAT one rather than
      // what they all agree on — arrowing down a list should show you what
      // each entry would give you.
      readonly property string ghost: pathBar.pick >= 0
        ? Terminus.ghostFor([pathBar.hits[pathBar.pick]], pathBar.ctx.frag)
        : Terminus.ghostFor(pathBar.hits, pathBar.ctx.frag)

      // WHICH ROW TAB WOULD TAKE, or -1 when Tab would extend the shared
      // prefix instead of choosing anything.
      //
      // `pick` is what the arrow keys moved and it starts at -1, so until you
      // pressed Down nothing was highlighted and the list gave no clue which
      // of eight candidates Tab was about to commit to. This is the same
      // decision `step`'s caller makes, read out loud: a lone candidate or an
      // ambiguity with nothing further in common is taken whole, and anything
      // else grows the ghost rather than picking a row.
      readonly property int tabTarget: pathBar.pick >= 0 ? pathBar.pick
        : (pathBar.hits.length === 1 || pathBar.ghost === "" ? 0 : -1)

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
        completeProc.command = ["sh", "-c", Terminus.completeCommand(d)];
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
          pathBar.setPath(Terminus.completedPath(pathBar.ctx.dir, one));
          pathBar.pick = -1;
          pathBar.reload();
          return;
        }

        // Rewrites the fragment rather than appending to it, so the result
        // carries the directory's real capitalisation: "doc" completes to
        // "Documents", not "documents".
        const pre = Terminus.completePrefix(pathBar.hits, pathBar.ctx.frag);
        if (pre !== "" && pre.length > pathBar.ctx.frag.length) {
          pathBar.setPath(Terminus.joinPath(pathBar.ctx.dir, pre));
          pathBar.reload();
          return;
        }

        // Several candidates that share nothing further — a fuzzy match with
        // no prefix to agree on. The best-ranked one is the honest guess.
        pathBar.setPath(Terminus.completedPath(pathBar.ctx.dir, pathBar.hits[0]));
        pathBar.pick = -1;
        pathBar.reload();
      }

      // MOVES THE HIGHLIGHT AND NOTHING ELSE.
      //
      // It used to write the highlighted candidate into the field, which broke
      // it twice over. The field's own onTextChanged resets `pick` to -1, so
      // every press was immediately undone and Down could never reach the
      // second entry. And completing into a directory changes the directory
      // being completed against, so the list you were arrowing through was
      // replaced by that directory's children mid-keystroke.
      //
      // Arrowing is a look, not a choice. Tab or Return is the choice, and
      // both already read `pick`.
      //
      // Wraps, like the listing behind it.
      function step(d) {
        const n = pathBar.hits.length;
        if (n === 0) return;
        const i = pathBar.pick < 0 ? (d > 0 ? 0 : n - 1) : pathBar.pick + d;
        pathBar.pick = (i + n) % n;
      }

      // Enter goes. A directory is entered; a FILE lands you in its parent
      // with the cursor on it, because "go to this path" said something real
      // even when what you named was not somewhere you can stand.
      function accept() {
        // A highlighted candidate is what Return means, the same as Tab: you
        // arrowed to it, so going there is not a second decision.
        if (pathBar.pick >= 0) {
          pathBar.setPath(
            Terminus.completedPath(pathBar.ctx.dir, pathBar.hits[pathBar.pick]));
          pathBar.pick = -1;
        }
        const target = Terminus.expandPath(pathField.text, Paths.home(), root.cwd);
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
              root.goTo(Terminus.dirname(t));
              return;
            }
            root.status = "no such path";
          }
        }
      }

      InputShield { onClicked: pathBar.dismiss() }

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

        // the card keeps its own clicks — see InputShield
        InputShield {}

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
              font.pixelSize: 18
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
              font.pixelSize: 18
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

              readonly property bool target: index === pathBar.tabTarget

              Rectangle {
                anchors.fill: parent
                color: target ? Zenon.selBg
                  : (hitHov.hovered ? Zenon.hoverTint : "transparent")
              }
              HoverHandler { id: hitHov }

              // The bar alone says "this one"; the caret says "and Tab takes
              // it", which is the half that was missing.
              Text {
                anchors.left: parent.left
                anchors.leftMargin: 22
                anchors.verticalCenter: parent.verticalCenter
                visible: target
                text: "\u276F"
                color: Zenon.cyan
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 13
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: 43
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: modelData
                elide: Text.ElideMiddle
                color: target ? Zenon.white : Zenon.keyInk
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 16
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  pathBar.setPath(Terminus.completedPath(pathBar.ctx.dir, modelData));
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
              font.pixelSize: 14
            }
          }
        }
      }
    }

    // ── the dialogs' keyboard ─────────────────────────────────────────
    // ONE ITEM THAT ACTUALLY HAS FOCUS.
    //
    // The confirm card used to carry `focus: confirm.open` on an item of its
    // own, which makes that item focused within ITS scope and nothing more —
    // `content` holds the window's active focus, so the card's Return never
    // arrived. The card appeared, showed you two buttons and would not take an
    // answer from the keyboard: "delete doesn't work".
    //
    // Putting the dispatch in content's own handler is not enough either,
    // because that only works while content is the thing with focus. So this
    // ASKS for the keyboard when a dialog opens, keeps asking until it has it
    // the way the window's focusClaim does, and hands it back on the way out.
    //
    // prompt is excluded: it holds a TextInput that takes focus for itself and
    // needs the letters.
    Item {
      id: dialogKeys
      anchors.fill: parent
      z: 20
      readonly property bool anyOpen:
        confirm.open || perms.open || props.open || prefs.open
      enabled: dialogKeys.anyOpen

      onAnyOpenChanged: {
        if (dialogKeys.anyOpen) { dialogClaim.tries = 0; dialogClaim.restart(); }
        else content.forceActiveFocus();
      }

      Timer {
        id: dialogClaim
        interval: 30
        repeat: true
        property int tries: 0
        onTriggered: {
          if (!dialogKeys.anyOpen || dialogKeys.activeFocus
              || dialogClaim.tries++ > 20) {
            dialogClaim.stop();
            return;
          }
          dialogKeys.forceActiveFocus();
        }
      }

      Keys.onPressed: (event) => {
        event.accepted = true;

        if (confirm.open) {
          if (event.key === Qt.Key_Escape) { confirm.dismiss(); return; }
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            confirm.choose(confirm.pick);
            return;
          }
          const n = Math.max(1, confirm.choices.length);
          if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
            confirm.pick = (confirm.pick + n - 1) % n;
            return;
          }
          if (event.key === Qt.Key_Right || event.key === Qt.Key_L
              || event.key === Qt.Key_Tab) {
            confirm.pick = (confirm.pick + 1) % n;
            return;
          }
          // A number picks one outright: "2" on a three-way overwrite prompt
          // is faster than two arrows and a Return.
          if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            const i = event.key - Qt.Key_1;
            if (i < confirm.choices.length) confirm.choose(i);
            return;
          }
          return;
        }

        if (event.key === Qt.Key_Escape) {
          props.open = false;
          perms.open = false;
          prefs.open = false;
          content.forceActiveFocus();
          return;
        }

        // The settings panel has no keyboard of its own — it is a panel of
        // switches you point at. It is listed here so the LISTING does not get
        // the keys while it is up: `d` behind an open panel was a file in the
        // trash you never asked to send there.
        if (prefs.open) return;

        if (perms.open) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            perms.apply();
          } else if (event.key === Qt.Key_Left) {
            perms.cursor = (perms.cursor + 8) % 9;
          } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
            perms.cursor = (perms.cursor + 1) % 9;
          } else if (event.key === Qt.Key_Up) {
            perms.cursor = (perms.cursor + 6) % 9;
          } else if (event.key === Qt.Key_Down) {
            perms.cursor = (perms.cursor + 3) % 9;
          } else if (event.key === Qt.Key_Space) {
            perms.toggleCursor();
          }
          return;
        }

        // properties: Return closes it, and the one thing in it you can ask
        // for is the checksum
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          props.open = false;
          content.forceActiveFocus();
        } else if (event.key === Qt.Key_S) {
          props.computeChecksum();
        }
      }
    }

    // ── what the pointer carries while dragging ───────────────────────
    //
    // A platform drag has no picture unless one is given to it: Drag.imageSource
    // takes a URL, and grabToImage renders a live item into one. So the card
    // below is drawn for real — off to one side and fully transparent, but in
    // the scene, because grabToImage renders an item's subtree and an item
    // that is `visible: false` is not in the graph to render.
    //
    // It is grabbed at the moment a drag begins rather than kept up to date,
    // because what it says depends on what is being dragged and that is not
    // known until then. The result object has to be held onto: its url stays
    // valid only as long as it is alive, and a collected one leaves the drag
    // carrying a broken image.
    Item {
      id: dragCard
      opacity: 0
      z: -100
      x: -4000
      height: 38

      // SIZED FROM THE TEXT, NOT FROM A ROW'S LAID-OUT WIDTH.
      //
      // This is what made the FIRST drag of a session carry a squashed card.
      // grabToImage sizes its target from the item's width at the moment it is
      // CALLED, and dragPicture calls it in the same tick that it fills the
      // labels in. A Row sets its own width during polish, at the end of the
      // frame — so the width read back was the one the card had before the
      // labels existed, a few pixels, and the picture was cut to it. Every
      // drag after that inherited the previous drag's width, which is exactly
      // why only the first one looked wrong.
      //
      // implicitWidth on a Text is an ordinary property: changing `text`
      // re-evaluates the bindings that read it, synchronously, in the tick
      // that changed it. So by the time grabToImage looks, the width is right.
      // Which is also why the children below are anchored rather than
      // positioned — a Row here would put the polish step back.
      readonly property real pad: 12
      width: dragCard.pad * 2 + dragGlyphText.implicitWidth
        + (root.dragGlyph !== "" ? 8 : 0) + dragLabelText.implicitWidth
        + (root.dragCount > 1 ? 8 + dragBadge.width : 0)

      Rectangle {
        anchors.fill: parent
        radius: 6
        color: Zenon.layerBg
        border.width: 1
        border.color: Zenon.cyan
      }

      Text {
        id: dragGlyphText
        anchors.left: parent.left
        anchors.leftMargin: dragCard.pad
        anchors.verticalCenter: parent.verticalCenter
        text: root.dragGlyph
        color: root.dragInk
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 16
      }

      Text {
        id: dragLabelText
        anchors.left: dragGlyphText.right
        anchors.leftMargin: root.dragGlyph !== "" ? 8 : 0
        anchors.verticalCenter: parent.verticalCenter
        text: root.dragLabel
        color: Zenon.white
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: 15
      }

      // the count rides along only when there is more than one, because
      // "1" beside a filename is noise
      Rectangle {
        id: dragBadge
        anchors.left: dragLabelText.right
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        visible: root.dragCount > 1
        width: countText.implicitWidth + 12
        height: 20
        radius: 10
        color: Zenon.cyan

        Text {
          id: countText
          anchors.centerIn: parent
          text: root.dragCount
          color: Zenon.black
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 13
          font.weight: Font.Medium
        }
      }
    }

    // ── the settings panel ────────────────────────────────────────────
    // What the hamburger at the end of the breadcrumb bar opens. Built like
    // the right-click menu — one `shade` driving the whole arrival, a full-
    // window catcher behind it so anywhere else dismisses it — because they
    // are the same object with different contents, and a second set of
    // animation numbers to keep in step would drift from the first.
    Item {
      id: prefs
      anchors.fill: parent
      z: 14
      visible: prefs.shade > 0.01
      opacity: prefs.shade

      property real shade: 0
      Behavior on shade {
        NumberAnimation { duration: Zenon.fast; easing.type: Easing.OutCubic }
      }
      onOpenChanged: prefs.shade = prefs.open ? 1 : 0

      property bool open: false
      // where the card's TOP RIGHT corner goes, in this item's coordinates
      property real px: 0
      property real py: 0

      function openFrom(item) {
        const p = item.mapToItem(prefs, item.width, item.height);
        prefs.px = p.x;
        prefs.py = p.y + 6;
        prefs.open = true;
      }
      function toggleFrom(item) {
        if (prefs.open) { prefs.open = false; content.forceActiveFocus(); }
        else prefs.openFrom(item);
      }

      InputShield {
        onClicked: { prefs.open = false; content.forceActiveFocus(); }
      }

      Rectangle {
        id: prefsCard
        // Rounded, for the reason the menu card's position is: the corner it
        // hangs from is measured off a bar that sits on a fractional pixel,
        // and an item on a half pixel renders its text through a filter.
        x: Math.round(Math.max(4,
             Math.min(prefs.px - prefsCard.width, prefs.width - prefsCard.width - 4)))
        y: Math.round(Math.max(4,
             Math.min(prefs.py, prefs.height - prefsCard.height - 4)))
        // 292, not 272: the sort strip carries five buttons while the
        // disk-usage mode is on, and "usage" does not fit in a fifth of the
        // old width.
        width: 292
        height: prefsCol.implicitHeight
        color: Zenon.black
        border.color: Zenon.surface
        border.width: 1
        radius: 8
        transformOrigin: Item.TopRight
        scale: 0.96 + 0.04 * prefs.shade

        // The same shadow the menu carries — blurMax is the softness, not
        // shadowBlur, which is spent at 1.0.
        layer.enabled: true
        layer.effect: MultiEffect {
          shadowEnabled: true
          shadowColor: Qt.rgba(0, 0, 0, 1.0)
          blurMax: 128
          shadowBlur: 1.0
          shadowScale: 1.06
          shadowVerticalOffset: 14
          shadowHorizontalOffset: 0
          autoPaddingEnabled: true
        }

        // The card eats its own clicks. Without this, the gaps between rows
        // fall through to the catcher behind and dismiss the panel you were
        // reaching into.
        InputShield {}

        Column {
          id: prefsCol
          width: parent.width
          topPadding: 4
          bottomPadding: 10

          SideHead { label: "VIEW"; first: true }

          // The three views as three buttons rather than as `v` pressed until
          // the right one comes round. While the window is split, columns is
          // not in the ring — six columns of listing in half a window each —
          // so it is shown refusing rather than quietly doing nothing.
          PrefSeg {
            options: ["columns", "list", "grid"]
            current: root.viewMode
            allowed: root.viewRing
            onChose: (v) => root.setView(v)
          }

          // The two zooms are deliberately independent — the grid scales its
          // pictures and everything else scales its text — so the row says
          // which one it is holding rather than reading "zoom" and meaning
          // something different in each view.
          PrefSlider {
            label: root.viewMode === "grid" ? "Thumbnails" : "Text size"
            value: root.activeZoom
            from: root.zoomMin
            to: root.zoomMax
            neutral: 1.0
            readout: Math.round(root.activeZoom * 100) + "%"
            onMoved: (v) => root.setZoom(v)
          }

          SideHead { label: "SORT" }

          // The column headings do this too, by clicking them — but only in
          // list view, and the grid and columns had no way to reach the order
          // at all except by learning `,` sequences.
          //
          // USAGE joins the ring only while the disk-usage mode is on, which
          // is the only time it means anything. Without it, turning the mode
          // on left all four buttons unlit and the panel looking broken.
          PrefSeg {
            options: root.usage
              ? ["name", "kind", "size", "time", "usage"]
              : ["name", "kind", "size", "time"]
            current: root.sortKey
            onChose: (v) => {
              // a second press on the key already in force turns it round,
              // exactly as clicking the heading twice does
              if (root.sortKey === v) root.sortDesc = !root.sortDesc;
              else { root.sortKey = v; root.sortDesc = false; }
            }
          }

          PrefRow {
            label: "Descending"
            on: root.sortDesc
            onToggled: root.sortDesc = !root.sortDesc
          }

          SideHead { label: "LISTING" }

          PrefRow {
            label: "Hidden files"
            hint: "."
            on: root.showHidden
            onToggled: root.showHidden = !root.showHidden
          }

          PrefRow {
            label: "Disk usage"
            hint: ", u"
            on: root.usage
            onToggled: root.toggleUsage()
          }

          PrefRow {
            label: "Remember per folder"
            on: root.perDirView
            onToggled: {
              root.perDirView = !root.perDirView;
              // Recorded on the way ON, so the folder you are standing in is
              // remembered from here rather than from the next one you walk
              // into — and applied at once, so turning it back on returns the
              // view this folder had rather than waiting for you to leave.
              if (root.perDirView) { root.rememberView(); root.applyDirView(); }
              viewSave.restart();
            }
          }

          SideHead { label: "WINDOW" }

          PrefRow {
            label: "Sidebar"
            on: root.sidebar
            onToggled: root.sidebar = !root.sidebar
          }

          PrefRow {
            label: "Restore session"
            on: root.sessionReplay
            onToggled: {
              root.sessionReplay = !root.sessionReplay;
              viewSave.restart();
            }
          }

          PrefRow {
            label: "Split view"
            hint: "\\"
            on: root.dual
            onToggled: root.toggleDual()
          }

          PrefSlider {
            label: "Opacity"
            value: root.winAlpha
            from: root.winAlphaMin
            to: 1.0
            neutral: 1.0
            readout: Math.round(root.winAlpha * 100) + "%"
            onMoved: (v) => root.setAlpha(v)
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
      // Kept alive through the fade OUT, which is the whole reason a menu
      // needs an opacity rather than just a visible: a card that vanishes on
      // the frame you click it never shows you which row you clicked.
      visible: menu.shade > 0.01
      opacity: menu.shade

      // 0 closed, 1 open. Everything about the card's arrival — its opacity,
      // its scale, the shade behind it — is a function of this one number, so
      // there is one animation to tune rather than four to keep in step.
      property real shade: 0
      Behavior on shade {
        NumberAnimation { duration: Zenon.fast; easing.type: Easing.OutCubic }
      }
      onOpenChanged: menu.shade = menu.open ? 1 : 0

      property bool open: false
      property real mx: 0
      property real my: 0

      readonly property var target: root.currentRow()
      readonly property bool isImage:
        !!menu.target && !menu.target.isDir && Terminus.isImage(menu.target.name)

      // on a row: everything applies to it
      function openAt(item, mouse) {
        const p = item.mapToItem(menu, mouse.x, mouse.y);
        menu.mx = p.x;
        menu.my = p.y;
        menu.here = false;
        menu.subAt = -1;
        menu.subSel = -1;
        menu.open = true;
        // after `open`, so `items` has been rebuilt for this target
        menu.at = menu.step(menu.items, -1, 1);
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
        menu.subSel = -1;
        menu.open = true;
        menu.at = menu.step(menu.items, -1, 1);
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
        { label: "Kind", act: () => root.setSort("kind") },
        { sep: true },
        // A mode rather than an order, which is why it says what it will do
        // rather than naming a column.
        { label: root.usage ? "Leave disk usage" : "Disk usage",
          key: ", u", act: () => root.toggleUsage() },
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
          // the ID, captured per iteration. Not the scanned file: that is the
          // first one found, which may be a stale user override — see
          // openWithCommand. An entry the scan could not locate at all still
          // has nothing to run.
          const id = apps[i].id;
          if (!id || !apps[i].file) continue;
          out.push({ label: apps[i].name, act: () => root.openWith(id, t.path) });
        }
        return out;
      }

      // which item's submenu is showing, or -1
      property int subAt: -1

      // ── the keyboard's place in the card ────────────────────────────
      // The menu was mouse-only: every key but Escape was dropped while it was
      // up, so the Menu key could open a card you then had to reach for the
      // mouse to use. `at` is the cursor in the parent card and `subSel` the
      // one in the submenu, with -1 meaning "the keyboard is not in there".
      property int at: -1
      property int subSel: -1

      // The next selectable row in a direction, wrapping, skipping separators
      // — a separator is a line, not a place you can be. Returns -1 for a list
      // with nothing selectable in it at all.
      function step(list, from, dir) {
        const n = list ? list.length : 0;
        if (n === 0) return -1;
        let i = from;
        for (let k = 0; k < n; ++k) {
          i = (i + dir + n) % n;
          if (!list[i].sep) return i;
        }
        return -1;
      }

      readonly property var subItems: {
        if (menu.subAt < 0) return [];
        const it = menu.items[menu.subAt];
        return (it && it.sub) ? it.sub : [];
      }

      // THE ACTION IS READ BEFORE THE MENU CLOSES, for the reason spelled out
      // on the rows themselves: close() empties the Repeater's model, an
      // emptied Repeater destroys its delegates, and modelData goes with them.
      function run(act) {
        menu.close();
        if (act) act();
      }

      function activateAt() {
        const it = menu.items[menu.at];
        if (!it || it.sep) return;
        // a parent row opens its children rather than doing anything
        if (it.sub) { menu.subAt = menu.at; menu.subSel = menu.step(it.sub, -1, 1); return; }
        menu.run(it.act);
      }

      function activateSub() {
        const it = menu.subItems[menu.subSel];
        if (!it || it.sep) return;
        menu.run(it.act);
      }

      // Down and up, in whichever card the keyboard is actually in.
      function move(dir) {
        if (menu.subSel >= 0) menu.subSel = menu.step(menu.subItems, menu.subSel, dir);
        else menu.at = menu.step(menu.items, menu.at, dir);
      }

      function close() {
        menu.open = false;
        menu.subAt = -1;
        menu.at = -1;
        menu.subSel = -1;
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
            out.push({ label: "Paste here", key: "p", act: () => root.paste() });
            out.push({ label: "Paste as symlink", act: () => root.pasteLink(true) });
            out.push({ label: "Paste as hard link", act: () => root.pasteLink(false) });
          }
          out.push({ label: "New directory\u2026", key: "a /", act: () => root.beginMkdir() });
          out.push({ label: "New file\u2026", key: "a", act: () => root.beginCreate() });
          out.push({ sep: true });
          out.push({ label: "Sort by", key: ",", sub: menu.sortItems });
          if (root.undoStack.length > 0)
            out.push({ label: root.undoLabel, key: "u", act: () => root.undo() });
          out.push({ sep: true });
          out.push({ label: root.isBookmarked(root.cwd)
              ? "Remove bookmark" : "Bookmark this directory",
            key: "b a",
            act: () => root.toggleBookmark() });
          if (root.inTrash)
            out.push({ label: "Empty the trash\u2026", danger: true,
                       act: () => root.emptyTrash() });
          out.push({ label: "Open shell here", key: ";", act: () => root.openShell() });
          out.push({ label: root.dual ? "Close second pane" : "Second pane",
                     key: "\\", act: () => root.toggleDual() });
          // Braced. Both of these are about the SECOND PANE and both were
          // meant to be behind `root.dual` — but only the first was, so a
          // one-pane window offered to swap sides with a pane that was not
          // there. The indentation had said what was intended all along.
          if (root.dual) {
            out.push({ label: "Step into other pane", key: "tab", act: () => root.stepOver() });
            out.push({ label: "Swap sides", act: () => root.swapSides() });
          }
          out.push({ label: "Select all", key: "ctrl a", act: () => root.selectAll() });
          out.push({ sep: true });
          // THIS directory, not whatever the cursor is resting on. Last, where
          // every other file manager puts it.
          out.push({ label: "Properties\u2026",
                     act: () => props.askPath(root.cwd) });
          return out;
        }
        const t = menu.target;
        if (!t) return [];
        // the cheap counter, so labels stay right without depending on the
        // whole selection array
        const n = root.markedCount > 0 ? root.markedCount : 1;
        const many = n > 1 ? " (" + n + ")" : "";
        const out = [
          { label: t.isDir ? "Open directory" : "Open", key: "return", act: () => root.activate() }
        ];
        // Directly under Open, because it is the other way to open this — and
        // only for a directory, which is the only thing with a listing to give
        // a tab. The same gesture is on the middle mouse button.
        if (t.isDir)
          out.push({ label: "Open in new tab", key: root.mouseKey(3),
                     act: () => root.openInNewTab(t.path) });
        // Opening is one kind of thing and moving is another; the rule below
        // holds them apart. Cut first: the pair is ordered by how much of a
        // commitment it is, and the one that takes the file away is the one
        // you want to have to read past to reach.
        out.push({ sep: true });
        out.push(
          { label: "Cut" + many, key: "x", act: () => root.yank("move") },
          { label: "Copy" + many, key: "y", act: () => root.yank("copy") },
          // The path is another thing you can take from the row, so it belongs
          // with the two above rather than down among the dialogs.
          { label: "Copy path", key: "c c", act: () => root.copyPath() });
        out.push({ sep: true });
        if (root.pending)
          out.push({ label: "Paste here", key: "p", act: () => root.paste() });
        out.push({ label: "Rename\u2026", key: "r", act: () => root.beginRename() });
        if (n > 1)
          out.push({ label: "Bulk rename\u2026" + many,
                     act: () => root.beginBulkRename() });
        if (root.pending) {
          out.push({ label: "Paste as symlink", act: () => root.pasteLink(true) });
          out.push({ label: "Paste as hard link", act: () => root.pasteLink(false) });
        }
        // Only where it can do something: an Extract on a text file and a
        // Restore outside the trash are entries that exist to be greyed out.
        if (t.isDir)
          out.push({ label: "Calculate size" + many, key: "z",
                     act: () => root.measureDirs() });
        if (root.dual && root.otherCwd !== "" && root.otherCwd !== root.cwd) {
          out.push({ label: "Copy to other pane" + many, key: "f5",
                     act: () => root.sendToOther("copy") });
          out.push({ label: "Move to other pane" + many, key: "f6",
                     act: () => root.sendToOther("move") });
        }
        if (Terminus.isArchive(t.name) && !t.isDir)
          out.push({ label: "Extract here" + many, act: () => root.extractSelected() });
        out.push({ label: "Compress" + many, key: "c a", sub: menu.formatItems });
        if (root.inTrash) {
          out.push({ label: "Restore" + many, act: () => root.restoreSelected() });
          out.push({ label: "Empty the trash\u2026", danger: true,
                     act: () => root.emptyTrash() });
        }
        if (!t.isDir)
          out.push({ label: "Open with", sub: menu.appItems });
        out.push({ label: "Sort by", key: ",", sub: menu.sortItems });
        if (t.isDir)
          out.push({ label: root.isBookmarked(t.path)
              ? "Remove bookmark" : "Bookmark",
            key: "b b",
            act: () => root.toggleBookmarkFor(t.path) });
        // The two that open a card of their own, together at the bottom behind
        // a rule — everything above acts on the row and returns you to it.
        out.push({ sep: true });
        out.push({ label: "Permissions\u2026", key: "c m", act: () => perms.ask() });
        out.push({ label: "Properties\u2026", key: "alt return", act: () => props.ask() });
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
        out.push({ label: "Trash" + many, key: "d", danger: true, act: () => root.trash() });
        return out;
      }

      ClippingRectangle {
        id: menuCard
        // Grows out of the pointer rather than appearing at full size. The
        // origin is the corner the pointer is at, so the card unfolds FROM the
        // click instead of expanding around its own middle.
        transformOrigin: Item.TopLeft
        scale: 0.94 + 0.06 * menu.shade

        // A REAL shadow, not a rectangle behind the card.
        //
        // The first attempt was an offset black rectangle, which is exactly as
        // soft as its own edges: a hard grey step three pixels out, which reads
        // as a printing error rather than as depth. MultiEffect blurs properly
        // and autoPadding grows the layer so the blur is not clipped by the
        // card's own bounds.
        layer.enabled: true
        layer.effect: MultiEffect {
          shadowEnabled: true
          shadowColor: Qt.rgba(0, 0, 0, 1.0)
          // shadowBlur is only the FRACTION of the kernel that gets used, so at
          // 1.0 it was already spent — the real softness knob is blurMax, the
          // kernel size itself. At the default 32 the falloff finished inside a
          // few pixels, which is what read as a defined band around the card.
          // At 128 the same ink is spread over four times the distance, so the
          // edge dissolves instead of stopping. Spreading it that thin is also
          // why the colour goes back to full black: a wide gradient needs the
          // density or it disappears.
          blurMax: 128
          shadowBlur: 1.0
          shadowScale: 1.08
          shadowVerticalOffset: 16
          shadowHorizontalOffset: 2
          autoPaddingEnabled: true
        }
        // kept inside the window: a menu opened near the right edge that
        // hangs off it is a menu with items you cannot reach
        // Rounded. The position comes from a pointer, which lands on
        // fractions of a pixel, and an item on a half pixel renders its text
        // through a filter — which is what "blurry" was.
        x: Math.round(Math.max(4, Math.min(menu.mx, menu.width - width - 4)))
        y: Math.round(Math.max(4, Math.min(menu.my, menu.height - height - 4)))
        width: 240
        // EXACTLY the column, which already carries 4px of padding at each
        // end. The extra 8 here was a second bottom padding — the column sits
        // at the card's top, so every pixel of it landed underneath the last
        // row and nowhere else.
        height: menuCol.implicitHeight
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
              id: menuRow
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
                // the keyboard's row counts as highlighted only while the
                // keyboard is in THIS card — with a submenu open the cursor
                // has moved into it and the parent row keeps its subAt tint
                color: itemHov.hovered || menu.subAt === index
                       || (menu.subSel < 0 && menu.at === index)
                  ? Zenon.surface : "transparent"
              }
              HoverHandler {
                id: itemHov
                enabled: !modelData.sep
                // Hovering a row with children opens them and hovering one
                // without closes whatever was open — so moving down the card
                // never leaves an orphaned second card beside an unrelated row.
                onHoveredChanged: if (hovered) {
                  menu.subAt = modelData.sub ? index : -1;
                  // so a keystroke after a hover carries on from the row under
                  // the pointer rather than from wherever the keyboard was
                  menu.at = index;
                  menu.subSel = -1;
                }
              }

              // BOUNDED ON THE RIGHT by whatever is over there, which is what
              // it was missing: a left-anchored Text with no right edge is as
              // wide as its string, so "Open in new tab" simply drew straight
              // through the "middle click" beside it and the two were printed
              // on top of each other. Now it stops short and elides.
              Text {
                id: menuLabel
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.right: menuKey.visible ? menuKey.left
                             : (menuChev.visible ? menuChev.left : parent.right)
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                visible: !modelData.sep
                text: modelData.label || ""
                color: modelData.danger ? Zenon.red : Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 16
              }

              // The key that does the same thing, so the menu teaches the
              // keyboard rather than competing with it. A footnote to the
              // entry, not a second label — but it was drawn in msgBorder,
              // which is a BORDER colour carrying 30% alpha, so it came out
              // barely there. keyInk is the palette's name for exactly this:
              // dimmer than the label, still meant to be read.
              KeyChip {
                id: menuKey
                anchors.right: menuChev.visible ? menuChev.left : parent.right
                anchors.rightMargin: modelData.sub ? 8 : 12
                anchors.verticalCenter: parent.verticalCenter
                visible: !modelData.sep && !!modelData.key
                label: modelData.key || ""
              }

              // the chevron that says there is more to the right
              Text {
                id: menuChev
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                visible: !!modelData.sub
                text: "\uf105"   // nf-fa-angle_right
                color: Zenon.muted
                font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: 15
              }

              // The row FLASHES, then the card closes, then the thing happens.
              //
              // A menu that disappears on mouse-down leaves you unsure which
              // row you hit — and for the destructive entries that is a bad
              // moment to be unsure in. The delay is long enough to see and
              // short enough that it is not a wait.
              property real chosen: 0
              SequentialAnimation {
                id: chosenAnim
                NumberAnimation { target: menuRow; property: "chosen"; to: 1;
                                  duration: 60; easing.type: Easing.OutQuad }
                NumberAnimation { target: menuRow; property: "chosen"; to: 0;
                                  duration: 130; easing.type: Easing.InQuad }
                ScriptAction {
                  script: {
                    const act = menuRow.pending;
                    menuRow.pending = null;
                    menu.close();
                    if (act) act();
                  }
                }
              }
              property var pending: null

              Rectangle {
                anchors.fill: parent
                visible: menuRow.chosen > 0
                color: Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b,
                               0.55 * menuRow.chosen)
              }

              MouseArea {
                anchors.fill: parent
                enabled: !modelData.sep && !chosenAnim.running
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  // a parent row opens its children rather than doing anything
                  if (modelData.sub) { menu.subAt = index; return; }
                  menuRow.pending = modelData.act;
                  chosenAnim.restart();
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

        layer.enabled: true
        layer.effect: MultiEffect {
          shadowEnabled: true
          shadowColor: Qt.rgba(0, 0, 0, 1.0)
          // shadowBlur is only the FRACTION of the kernel that gets used, so at
          // 1.0 it was already spent — the real softness knob is blurMax, the
          // kernel size itself. At the default 32 the falloff finished inside a
          // few pixels, which is what read as a defined band around the card.
          // At 128 the same ink is spread over four times the distance, so the
          // edge dissolves instead of stopping. Spreading it that thin is also
          // why the colour goes back to full black: a wide gradient needs the
          // density or it disappears.
          blurMax: 128
          shadowBlur: 1.0
          shadowScale: 1.08
          shadowVerticalOffset: 16
          shadowHorizontalOffset: 2
          autoPaddingEnabled: true
        }

        readonly property var items: menu.subItems

        readonly property real rowTop: {
          let y = 4;   // menuCol's top padding
          for (let i = 0; i < menu.subAt && i < menu.items.length; ++i) {
            y += menu.items[i].sep ? 7 : 30;
          }
          return y;
        }

        width: subCard.items.length > 0 && subCard.items[0].hint ? 330 : 200
        height: subCol.implicitHeight
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
              id: subRow
              required property var modelData
              // needed by the keyboard cursor's highlight below; the parent
              // card's rows have always declared it
              required property int index
              width: subCol.width
              height: modelData.sep ? 7 : 30

              // The action is READ BEFORE THE MENU CLOSES, and that ordering is
              // the whole reason these rows do anything at all.
              //
              // close() sets subAt back to -1, which makes subCard.items answer
              // with an empty list, which empties this Repeater's model — and an
              // emptied Repeater destroys its delegates. `modelData` belongs to
              // the delegate, so calling modelData.act() after close() is a call
              // on something that no longer exists. Every entry under Compress,
              // Open with and Sort by was silently dead for exactly that reason.
              //
              // Holding it in `pending` also buys the same flash the parent
              // card's rows get, so a choice in a submenu confirms itself the
              // same way a choice in the menu does.
              property real chosen: 0
              property var pending: null
              SequentialAnimation {
                id: subChosenAnim
                NumberAnimation { target: subRow; property: "chosen"; to: 1;
                                  duration: 60; easing.type: Easing.OutQuad }
                NumberAnimation { target: subRow; property: "chosen"; to: 0;
                                  duration: 130; easing.type: Easing.InQuad }
                ScriptAction {
                  script: {
                    const act = subRow.pending;
                    subRow.pending = null;
                    menu.close();
                    if (act) act();
                  }
                }
              }

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
                color: subHov.hovered || menu.subSel === subRow.index
                  ? Zenon.surface : "transparent"
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
                font.pixelSize: 16
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
                font.pixelSize: 13
              }

              Rectangle {
                anchors.fill: parent
                visible: subRow.chosen > 0
                color: Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b,
                               0.55 * subRow.chosen)
              }

              MouseArea {
                anchors.fill: parent
                enabled: !modelData.sep && !subChosenAnim.running
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (!modelData.act) return;
                  subRow.pending = modelData.act;
                  subChosenAnim.restart();
                }
              }
            }
          }
        }
      }

    }

    // ── bulk rename ───────────────────────────────────────────────────
    // Forty names, edited where the forty files are.
    //
    // Two columns and nothing else: what a thing is called now, and what it
    // would be called. The pattern field above them is the reason this exists
    // at all — "replace .JPEG with .jpg across all of them" is one gesture,
    // and the per-row fields are there for the handful the pattern got wrong.
    //
    // NOTHING IS APPLIED UNTIL THE BUTTON. The rules are checked live and
    // written on the offending row, so an empty name or two files that would
    // end up with the same name is something you see before you commit rather
    // than a refusal afterwards.
    Rectangle {
      id: bulk
      anchors.fill: parent
      z: 15
      visible: opacity > 0.01
      opacity: bulk.open ? 1 : 0
      color: Qt.rgba(0, 0, 0, 0.55)
      Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

      property bool open: false
      // Which row has the keyboard. A delegate cannot be told to take focus
      // from outside, so it watches this and claims it for itself.
      property int at: 0
      // Bumped to ask row `at` to take the keyboard AGAIN even when `at` did
      // not change — tabbing out of the pattern fields and back into the row
      // it was already on has nothing to change but still has to move the
      // caret. A counter, for the reason openPulse is one.
      property int atPulse: 0

      function focusRow(i) {
        const n = root.bulkNames.length;
        if (n === 0) return;
        bulk.at = Math.max(0, Math.min(n - 1, i));
        bulk.atPulse++;
      }

      // Tab walks the whole card and wraps: find, replace, every row, back to
      // find. One ring rather than two halves that cannot reach each other,
      // which is what the pattern fields and the rows were before.
      function tabFromRow(i) {
        if (i < root.bulkNames.length - 1) bulk.focusRow(i + 1);
        else findField.claim();
      }
      function backTabFromRow(i) {
        if (i > 0) bulk.focusRow(i - 1);
        else replField.claim();
      }

      // What is wrong with each proposed name, from the same function the
      // commit gate reads — see Terminus.bulkIssues.
      readonly property var issues:
        Terminus.bulkIssues(root.bulkNames, root.bulkEdits)
      readonly property bool sound: {
        for (let i = 0; i < bulk.issues.length; ++i)
          if (bulk.issues[i] !== "") return false;
        return true;
      }
      readonly property int changes: {
        let n = 0;
        for (let i = 0; i < root.bulkNames.length; ++i)
          if (root.bulkEdits[i] !== root.bulkNames[i]) n++;
        return n;
      }

      function dismiss() {
        bulk.open = false;
        content.forceActiveFocus();
      }

      onOpenChanged: {
        if (!bulk.open) return;
        bulk.at = 0;
        findField.text = "";
        replField.text = "";
        bulkClaim.tries = 0;
        bulkClaim.restart();
      }

      // ASK UNTIL IT HAS IT. The card is animating in from opacity 0 when the
      // first request goes out, and forceActiveFocus() on an item the scene
      // has not placed yet is silently dropped — the same trap the rename
      // field and the create prompt both carry a retry for.
      Timer {
        id: bulkClaim
        interval: 40
        repeat: true
        property int tries: 0
        onTriggered: {
          if (!bulk.open || bulkKeys.activeFocus || bulkClaim.tries++ > 12) {
            bulkClaim.stop();
            return;
          }
          bulkKeys.forceActiveFocus();
          // and the first row within it, which is where you would start
          // typing. The delegate may well have existed already — the model is
          // just a count, so re-opening on the same number of files reuses the
          // rows and their Component.onCompleted never runs again.
          bulk.focusRow(0);
        }
      }

      InputShield { onClicked: bulk.dismiss() }

      // Escape from anywhere in the card, including from inside a field that
      // has not handled it — so there is always one key that gets you out.
      FocusScope {
        id: bulkKeys
        anchors.fill: parent
        // Escape from anywhere in the card, and nothing else out of it.
        //
        // The fields are deeper than this, so they see their own keys first
        // and this only ever gets what they did not want — which must not
        // travel on to the listing's key handler. Before this, a key the
        // pattern fields ignored acted on the rows behind the card.
        Keys.onPressed: (e) => {
          e.accepted = true;
          if (e.key === Qt.Key_Escape) bulk.dismiss();
        }

        ClippingRectangle {
          anchors.centerIn: parent
          width: Math.min(760, parent.width - 80)
          height: Math.min(parent.height - 100, bulkCol.implicitHeight)
          color: Zenon.black
          border.color: Zenon.surface
          border.width: 1
          radius: 10
          transform: Translate { y: (1 - bulk.opacity) * 10 }

          // the card eats its own clicks, so the scrim behind it does not
          InputShield {}

          Column {
            id: bulkCol
            width: parent.width

            // The thing, not the word — the same bar the properties and
            // permissions cards wear.
            Rectangle {
              width: parent.width
              height: 26
              color: Zenon.cyan
              Text {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: root.bulkNames.length === 1 ? "Rename 1 item"
                  : "Rename " + root.bulkNames.length + " items"
                color: Zenon.black
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: Font.Bold
                font.pixelSize: 14
              }
            }

            // ── the pattern ───────────────────────────────────────
            // Return in either field applies it. A BUTTON rather than a live
            // binding: the replace runs from the original names, so making it
            // live would wipe a hand edit every time the caret moved through
            // the pattern.
            Item {
              id: patRow
              width: parent.width
              height: 46
              // Anchored rather than laid out in a Row: the button sizes
              // itself to its own label, so the two fields are whatever is
              // left over after it — and a Row would have to be told that
              // number twice.
              readonly property real cell:
                Math.max(60, (patRow.width - 72 - replBtn.width) / 2)

              BulkField {
                id: findField
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                width: patRow.cell
                ghost: "find"
                onAccepted: root.applyBulkReplace(findField.text, replField.text)
                onTabbed: replField.claim()
                onBackTabbed: bulk.focusRow(root.bulkNames.length - 1)
              }

              Text {
                id: patArrow
                anchors.left: findField.right
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 14
                horizontalAlignment: Text.AlignHCenter
                text: "\u2192"
                color: Zenon.muted
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 15
              }

              BulkField {
                id: replField
                anchors.left: patArrow.right
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: patRow.cell
                ghost: "replace with"
                onAccepted: root.applyBulkReplace(findField.text, replField.text)
                onTabbed: bulk.focusRow(0)
                onBackTabbed: findField.claim()
              }

              DialogButton {
                id: replBtn
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                label: "Replace"
                ink: Zenon.cyan
                ready: findField.text !== ""
                onClicked: root.applyBulkReplace(findField.text, replField.text)
              }
            }

            Rectangle {
              width: parent.width
              height: 1
              color: Zenon.msgBorder
            }

            // ── the two columns ───────────────────────────────────
            Rectangle {
              width: parent.width
              height: 22
              color: Zenon.headBg

              Text {
                x: 46
                width: (parent.width - 60) * 0.42
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: "NOW"
                color: Zenon.muted
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 12
              }

              Text {
                x: 46 + (parent.width - 60) * 0.42 + 12
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: "TO"
                color: Zenon.muted
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 12
              }

              Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: Zenon.msgBorder
              }
            }

            Item {
              width: parent.width
              // Sized to what it holds, up to the room the card has left. A
              // fixed height left a band of empty card under three names and
              // could not show thirty.
              height: Math.max(34, Math.min(bulkList.contentHeight,
                bulk.height - 100 - 26 - 46 - 1 - 22 - 52))

              ListView {
                id: bulkList
                anchors.fill: parent
                clip: true
                model: root.bulkNames.length
                // The fields are live TextInputs holding unsaved text, and a
                // recycled delegate would carry one row's caret into another.
                reuseItems: false

                delegate: Item {
                  id: bulkRow
                  required property int index
                  width: bulkList.width
                  height: 30

                  readonly property string issue:
                    bulk.issues[bulkRow.index] === undefined
                      ? "" : bulk.issues[bulkRow.index]
                  readonly property bool moved:
                    root.bulkEdits[bulkRow.index] !== root.bulkNames[bulkRow.index]

                  Rectangle {
                    anchors.fill: parent
                    color: bulkRow.issue !== ""
                      ? Qt.rgba(Zenon.red.r, Zenon.red.g, Zenon.red.b, 0.10)
                      : (bulk.at === bulkRow.index ? Zenon.selBg : "transparent")
                  }

                  // The row number, because the duplicate warning names one.
                  Text {
                    x: 0
                    width: 40
                    height: parent.height
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                    text: bulkRow.index + 1
                    color: Zenon.muted
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 12
                  }

                  Text {
                    id: wasName
                    x: 46
                    width: (parent.width - 60) * 0.42
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    text: root.bulkNames[bulkRow.index] || ""
                    elide: Text.ElideMiddle
                    // Dimmed once the row is going to change: the old name is
                    // then history, and the eye should be on the new one.
                    color: bulkRow.moved ? Zenon.muted : Zenon.keyInk
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 14
                  }

                  TextInput {
                    id: toName
                    x: wasName.x + wasName.width + 12
                    width: parent.width - x - 14 - (issueText.visible ? issueText.width + 10 : 0)
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    text: root.bulkEdits[bulkRow.index] || ""
                    color: bulkRow.issue !== "" ? Zenon.red
                      : (bulkRow.moved ? Zenon.cyan : Zenon.white)
                    selectionColor: Zenon.selBg
                    selectedTextColor: Zenon.white
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.weight: bulkRow.moved ? Font.Bold : Font.Medium
                    font.pixelSize: 14
                    clip: true

                    onTextEdited: root.setBulkEdit(bulkRow.index, toName.text)
                    onActiveFocusChanged: if (activeFocus) bulk.at = bulkRow.index

                    // Down and up walk the list, which is what a column of
                    // fields is for; Tab walks the whole card, pattern fields
                    // included. Return commits the batch from any of them, so
                    // the common case never needs the pointer.
                    Keys.onPressed: (e) => {
                      if (e.key === Qt.Key_Tab) {
                        e.accepted = true; bulk.tabFromRow(bulkRow.index); return;
                      }
                      if (e.key === Qt.Key_Backtab) {
                        e.accepted = true; bulk.backTabFromRow(bulkRow.index); return;
                      }
                    }
                    Keys.onDownPressed: (e) => {
                      e.accepted = true;
                      bulk.focusRow(bulkRow.index + 1);
                    }
                    Keys.onUpPressed: (e) => {
                      e.accepted = true;
                      bulk.focusRow(bulkRow.index - 1);
                    }
                    Keys.onReturnPressed: (e) => {
                      e.accepted = true;
                      if (bulk.sound) root.commitBulkRename();
                    }
                    Keys.onEnterPressed: (e) => {
                      e.accepted = true;
                      if (bulk.sound) root.commitBulkRename();
                    }

                    // A delegate cannot be handed focus from outside, so it
                    // takes it when the card says this row is the one. The
                    // STEM is selected and the extension is not, for the same
                    // reason the in-place rename does it: a bulk rename is
                    // almost never about the type.
                    Connections {
                      target: bulk
                      function onAtPulseChanged() {
                        if (bulk.at !== bulkRow.index) return;
                        toName.forceActiveFocus();
                        const st = Terminus.stem(toName.text);
                        toName.select(0, st.length > 0 ? st.length : toName.text.length);
                      }
                    }
                    Component.onCompleted: {
                      if (bulk.at !== bulkRow.index) return;
                      toName.forceActiveFocus();
                      const st = Terminus.stem(toName.text);
                      toName.select(0, st.length > 0 ? st.length : toName.text.length);
                    }
                  }

                  // WHY the row is red, on the row. A card that only greyed
                  // out its own button left you comparing thirty names by eye
                  // to find the two that collided.
                  Text {
                    id: issueText
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    visible: bulkRow.issue !== ""
                    text: bulkRow.issue
                    color: Zenon.red
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 12
                  }
                }
              }

              ScrollRail {
                target: bulkList
                anchors.top: bulkList.top
                anchors.bottom: bulkList.bottom
                x: bulkList.x + bulkList.width - width - 2
              }
            }

            Rectangle {
              width: parent.width
              height: 1
              color: Zenon.msgBorder
            }

            // ── what it will do, and the two answers ──────────────
            Item {
              width: parent.width
              height: 52

              Text {
                anchors.left: parent.left
                anchors.leftMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                text: !bulk.sound ? "fix the marked names"
                  : (bulk.changes === 0 ? "nothing changed"
                    : bulk.changes + (bulk.changes === 1
                        ? " name will change" : " names will change"))
                color: !bulk.sound ? Zenon.red
                  : (bulk.changes === 0 ? Zenon.muted : Zenon.cyan)
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 14
              }

              Row {
                anchors.right: parent.right
                anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10

                DialogButton {
                  label: "Cancel"
                  ink: Zenon.muted
                  onClicked: bulk.dismiss()
                }

                DialogButton {
                  label: "Rename"
                  ink: Zenon.cyan
                  primary: true
                  ready: bulk.sound && bulk.changes > 0
                  onClicked: root.commitBulkRename()
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
      // Which of the nine boxes the keyboard is on, read across then down:
      // owner r w x, group r w x, other r w x — the order chmod writes them
      // and the order they are drawn in. The dialog was mouse-only.
      property int cursor: 0
      readonly property int cursorBit:
        [4, 2, 1][perms.cursor % 3] << (6 - Math.floor(perms.cursor / 3) * 3)
      function toggleCursor() { perms.mode = perms.mode ^ perms.cursorBit; }

      function ask() {
        const rows = root.acting();
        if (rows.length === 0) return;
        perms.paths = rows.map((r) => r.path);
        // the cursor's mode is the starting point even for a multi-select:
        // there is no single answer for a mixed set, and picking one of them
        // is more honest than showing zero
        perms.mode = rows[0].mode || 0;
        perms.cursor = 0;
        perms.open = true;
      }

      function apply() {
        root.run(Terminus.chmodCommand(perms.paths, perms.mode));
        perms.open = false;
        content.forceActiveFocus();
      }

      InputShield {
        onClicked: { perms.open = false; content.forceActiveFocus(); }
      }

      ClippingRectangle {
        anchors.centerIn: parent
        // Sized to the grid it holds: 78 label + 3x62 boxes + 40 for the
        // row's octal digit is 304, and 40 either side of that is the margin
        // everything else in the card lines up to.
        width: 384
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

        // the card keeps its own clicks — see InputShield
        InputShield {}

        Column {
          id: permsCol
          width: parent.width

          // ONE RHYTHM. Everything below the title is 12px apart and the grid
          // is centred rather than left-padded — it used to start 40px in and
          // end 146px short of the right edge, which is what made the card
          // look like it was leaning.
          readonly property int gap: 12
          readonly property int labelW: 78
          readonly property int cellW: 62
          readonly property int octW: 40

          // WHAT IT IS BEING APPLIED TO, in the bar itself.
          //
          // The card used to open with the word "Permissions" across a 38px
          // band and the filename repeated in muted grey on its own line
          // underneath — a title saying nothing and a subtitle saying the one
          // thing worth saying. One line, and the band is a caption rather
          // than a banner. The properties card is built the same way.
          Rectangle {
            width: parent.width
            height: 26
            color: Zenon.cyan
            Text {
              anchors.fill: parent
              anchors.leftMargin: 14
              anchors.rightMargin: 14
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: perms.paths.length === 1
                ? Terminus.basename(perms.paths[0])
                : perms.paths.length + " items"
              elide: Text.ElideMiddle
              color: Zenon.black
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 14
            }
          }

          Item { width: 1; height: permsCol.gap }

          // The answer in both spellings on one line — the octal you would
          // type at chmod and the rwx string ls prints. They are the same
          // number said twice, so they belong side by side rather than stacked.
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 16

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: ("000" + (perms.mode & 511).toString(8)).slice(-3)
              color: Zenon.cyan
              font.family: "JetBrainsMono Nerd Font Mono"
              font.weight: Font.Bold
              font.pixelSize: 30
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 1
              height: 24
              color: Zenon.msgBorder
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: Terminus.modeString(perms.mode)
              color: Zenon.sand
              font.family: "JetBrainsMono Nerd Font Mono"
              font.weight: Font.Bold
              font.pixelSize: 21
            }
          }

          Item { width: 1; height: permsCol.gap }

          // The four modes anyone actually types. A permissions dialog whose
          // quickest route to 755 is nine clicks is a dialog that has not
          // finished the job.
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8

            Repeater {
              model: [
                ["644", 420], ["755", 493], ["600", 384], ["700", 448]
              ]

              delegate: Rectangle {
                required property var modelData
                readonly property bool on: (perms.mode & 511) === modelData[1]
                width: 62
                height: 24
                radius: 4
                color: on ? Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.20)
                  : (presetHov.hovered ? Zenon.hoverTint : "transparent")
                border.width: 1
                border.color: on ? Zenon.cyan : Zenon.msgBorder
                Behavior on color {
                  ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
                }

                Text {
                  anchors.centerIn: parent
                  text: modelData[0]
                  color: parent.on ? Zenon.cyan : Zenon.muted
                  font.family: "JetBrainsMono Nerd Font Mono"
                  font.pixelSize: 14
                }

                HoverHandler { id: presetHov }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  // the high bits — setuid and friends — are left alone: this
                  // is a shortcut for the nine, not a reset of the whole mode
                  onClicked: perms.mode = (perms.mode & ~511) | modelData[1]
                }
              }
            }
          }

          Item { width: 1; height: permsCol.gap + 2 }

          Rectangle {
            width: parent.width
            height: 1
            color: Zenon.msgBorder
          }

          Item { width: 1; height: permsCol.gap }

          // A GRID with its columns named, rather than three unlabelled rows
          // of three: r, w and x are not obvious from the boxes alone, and the
          // heading costs one row of small type.
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            height: 18

            Item { width: permsCol.labelW; height: 1 }
            Repeater {
              model: ["read", "write", "exec"]
              delegate: Text {
                required property var modelData
                width: permsCol.cellW
                height: 18
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: modelData
                color: Zenon.msgBorder
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 12
              }
            }
            Item { width: permsCol.octW; height: 1 }
          }

          // three rows of three, in the order chmod writes them
          Repeater {
            model: [["owner", 6], ["group", 3], ["other", 0]]

            delegate: Row {
              id: permRow
              required property var modelData
              required property int index
              readonly property int shift: modelData[1]
              anchors.horizontalCenter: parent.horizontalCenter
              height: 34

              Text {
                width: permsCol.labelW
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: modelData[0]
                color: Zenon.white
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 16
              }

              Repeater {
                model: [["r", 4], ["w", 2], ["x", 1]]

                delegate: Item {
                  required property var modelData
                  required property int index
                  width: permsCol.cellW
                  height: parent.height

                  readonly property int bit: modelData[1] << permRow.shift
                  readonly property bool on: (perms.mode & bit) !== 0
                  readonly property bool here:
                    perms.cursor === permRow.index * 3 + index

                  Rectangle {
                    anchors.centerIn: parent
                    width: 50
                    height: 26
                    radius: 4
                    color: parent.on
                      ? Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.20)
                      : (bitHov.hovered ? Zenon.hoverTint : "transparent")
                    border.width: parent.here ? 2 : 1
                    border.color: parent.here ? Zenon.sand
                      : (parent.on ? Zenon.cyan : Zenon.msgBorder)
                    Behavior on color {
                      ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
                    }

                    Text {
                      anchors.centerIn: parent
                      text: modelData[0]
                      color: parent.parent.on ? Zenon.cyan : Zenon.muted
                      font.family: "JetBrainsMono Nerd Font Mono"
                      font.weight: Font.Bold
                      font.pixelSize: 16
                    }
                  }

                  HoverHandler { id: bitHov }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      perms.cursor = permRow.index * 3 + parent.index;
                      perms.mode = perms.mode ^ parent.bit;
                    }
                  }
                }
              }

              // This row's own octal digit, so the three boxes and the number
              // at the top are visibly the same statement.
              Text {
                width: permsCol.octW
                height: parent.height
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: String((perms.mode >> permRow.shift) & 7)
                color: Zenon.muted
                font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: 15
              }
            }
          }

          Item { width: 1; height: permsCol.gap + 2 }

          Rectangle {
            width: parent.width
            height: 1
            color: Zenon.msgBorder
          }

          Item {
            width: parent.width
            height: 54

            Row {
              anchors.centerIn: parent
              spacing: 12

              DialogButton {
                label: "Cancel"
                ink: Zenon.muted
                onClicked: { perms.open = false; content.forceActiveFocus(); }
              }

              DialogButton {
                label: "Apply"
                ink: Zenon.cyan
                primary: true
                onClicked: perms.apply()
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
      // Which choice the keyboard is on. Starts at 0 — the verb, listed first
      // — so Return still means what it always meant.
      property int pick: 0
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
        confirm.pick = 0;
        confirm.heading = heading;
        confirm.detail = detail;
        confirm.choices = all;
        // focus is not claimed here: the item that reads these keys is
        // dialogKeys, which watches `open` on all three dialogs and takes
        // focus itself, with a retry — a delegate that the scene has not
        // finished placing silently drops forceActiveFocus().
        confirm.open = true;
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

      InputShield { onClicked: confirm.dismiss() }


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

        // the card keeps its own clicks — see InputShield
        InputShield {}

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
              font.pixelSize: 18
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
              font.pixelSize: 16
            }
          }

          Row {
            width: parent.width
            height: 32

            Repeater {
              model: confirm.choices

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width / Math.max(1, confirm.choices.length)
                height: parent.height

                DialogButton {
                  anchors.centerIn: parent
                  width: parent.width - 16
                  label: modelData.label
                  ink: modelData.ink
                  onHovered: confirm.pick = index
                  // The one Return takes, which the arrow keys move.
                  primary: index === confirm.pick
                  // one definition of what choosing means — Return goes
                  // through choose(0) and so does a click
                  onClicked: confirm.choose(index)
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
      readonly property string error: Terminus.nameError(promptField.text)

      // as pathBar: whatever the field did not take stops here
      Keys.onPressed: (event) => { event.accepted = true; }

      function ask(heading, initial, onDone) {
        prompt.heading = heading;
        prompt.onDone = onDone;
        prompt.open = true;
        promptField.text = initial;
        // the stem, not the extension — renaming almost never means retyping
        // ".tar.gz", and selecting the lot means you have to click to avoid it
        // The stem, and for an archive that means BOTH halves of the
        // extension. lastIndexOf(".") alone selected "name.tar" out of
        // "name.tar.zst" and left ".zst" behind, so typing a new name gave you
        // a bare zstd file rather than the tarball the menu just promised —
        // the one thing the format menu exists to get right.
        const bare = Terminus.stripArchiveExt(initial);
        const dot = initial.lastIndexOf(".");
        prompt.selectTo = bare.length < initial.length ? bare.length
                        : (dot > 0 ? dot : initial.length);
        promptField.select(0, prompt.selectTo);
        promptClaim.tries = 0;
        promptClaim.restart();
      }

      // The card is INVISIBLE at the moment ask() runs.
      //
      // `visible` follows opacity, opacity is animated, and the animation has
      // not started yet on the frame that opens the prompt — so opacity is
      // still 0, visible is still false, and an invisible item silently
      // refuses active focus. The prompt appeared, took no keystrokes, and
      // ignored Return, which is what "compress does not work" looked like
      // from the outside. Retrying until the card is really on screen is the
      // same fix the confirm dialog and the inline rename field both needed.
      property int selectTo: 0
      Timer {
        id: promptClaim
        interval: 30
        repeat: true
        property int tries: 0
        onTriggered: {
          if (!prompt.open || promptClaim.tries++ > 20) { promptClaim.stop(); return; }
          if (promptField.activeFocus) { promptClaim.stop(); return; }
          promptField.forceActiveFocus();
          // the selection is re-applied with the focus: taking focus moves the
          // cursor, and a name you have to re-select is a name you retype
          promptField.select(0, prompt.selectTo);
        }
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

      InputShield { onClicked: prompt.dismiss() }

      ClippingRectangle {
        anchors.centerIn: parent
        width: Math.min(460, parent.width - 60)
        height: 104
        color: Zenon.black
        border.color: Zenon.surface
        border.width: 1
        radius: 10
        transform: Translate { y: (1 - prompt.opacity) * 10 }

        // the card keeps its own clicks — see InputShield
        InputShield {}

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
              font.pixelSize: 18
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
                font.pixelSize: 17
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
            font.pixelSize: 15
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
  // ── one tile of a thumbnail view ────────────────────────────────────────
  // Lifted out of the grid's delegate so the SECOND PANE can be a grid too.
  // Both panes draw the same tile; what differs is which state it is bound to
  // and, for the inactive one, that its cursor is an outline rather than a
  // fill — see EntryRow.passive, which is the same rule for rows.
  component Tile: Item {
    id: tile
    property var entry: null
    property bool current: false
    property bool ticked: false
    property bool passive: false
    // A pending CUT, faded to say so — the same signal EntryRow gives a row.
    property bool dim: false
    // Whether this tile is in the grid the cursor moves through — the second
    // pane's grid draws tiles the rename verb was never about. Same property,
    // same meaning, as EntryRow.live.
    property bool live: false
    readonly property bool editing:
      root.renaming && tile.current && tile.live && !!tile.entry
    // the zoom this tile's pane is at, so two grids can be at two zooms
    property real tileZoom: root.thumbZoom

    // The POSITION rides along with the click, because the actions menu opens
    // where the pointer is and a signal that dropped it left right-click in
    // the grid doing nothing at all.
    signal chosen(bool right, bool shift, bool ctrl, real mx, real my)
    // middle click: this entry, in a tab of its own
    signal tabbed()
    signal opened()

    // true while a drag hovers THIS directory — see root.dropDirAt
    readonly property bool dropTarget: root.dropDir !== "" && !!tile.entry
      && tile.entry.isDir && root.dropDir === tile.entry.path

    // ── dragging this tile out ──────────────────────────────────────
    // The same shape as EntryRow's, and for the same reasons written there:
    // the attached Drag group belongs on the DELEGATE, and a DragHandler with
    // no target decides WHEN while the group decides WHAT. The grid had none
    // of this, so nothing in it could be dragged anywhere at all.
    Drag.active: false
    Drag.source: tile
    Drag.keys: ["text/uri-list"]
    Drag.mimeData: ({ "text/uri-list": tile.entry ? root.dragUris(tile.entry) : "" })
    Drag.supportedActions: Qt.CopyAction
    Drag.dragType: Drag.Automatic
    Drag.hotSpot.x: tile.width / 2
    Drag.hotSpot.y: tile.height / 2
    Drag.onDragFinished: (dropAction) => {
      tile.Drag.active = false;
      root.draggingRow = false;
    }

    DragHandler {
      id: tileDrag
      target: null
      enabled: !!tile.entry && !tile.editing && !root.modal
      onActiveChanged: {
        if (!tileDrag.active) return;
        root.draggingRow = true;
        root.dragPicture(tile.entry, (url) => {
          tile.Drag.imageSource = url;
          tile.Drag.active = true;
        });
      }
    }

    readonly property bool cursorOnly:
      tile.current
        && (tile.passive || (!tile.ticked && root.markedCount > 0))

    // A cyan flare on the tile that was just opened.
    //
    // Opening from a grid gives no feedback of its own — the window that comes
    // up is somewhere else, and if it takes a moment there is nothing to say
    // the keypress landed. This says it, on the tile it landed on, and is gone
    // before it can become clutter.
    property real glow: 0
    Connections {
      target: root
      function onOpenPulseChanged() { if (tile.current && !tile.passive) flare.restart(); }
    }
    SequentialAnimation {
      id: flare
      NumberAnimation { target: tile; property: "glow"; to: 1; duration: 90;
                        easing.type: Easing.OutQuad }
      NumberAnimation { target: tile; property: "glow"; to: 0; duration: 420;
                        easing.type: Easing.InQuad }
    }

    Rectangle {
      anchors.fill: parent
      anchors.margins: 4
      radius: 6
      color: tile.cursorOnly ? "transparent"
        : (tile.current ? Zenon.selBg
          : (tile.ticked ? Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.10)
            : "transparent"))
      border.width: tile.current ? 1 + tile.glow * 2 : 0
      // A tile has always carried a border, so the cursor keeps one
      // either way — it just stops being cyan, which is the colour
      // this window uses to mean "selected", and becomes the neutral
      // outline that only means "here". While the flare is running it
      // is cyan regardless, because that is the whole point of it.
      border.color: tile.glow > 0 ? Zenon.cyan
        : (tile.cursorOnly ? Zenon.msgBorder : Zenon.cyan)

      // the flare itself, over the tile's own fill
      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        visible: tile.glow > 0
        color: Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.22 * tile.glow)
      }
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
      // 68, not 62. The reserve has to hold the 8px gap, two lines of
      // label and the 4px the highlight is inset by — and the label
      // went from 15px to 16px, which is exactly enough for a name
      // long enough to wrap to overrun the bottom of its own tile.
      height: parent.height - 68

      // Rounded corners, and they belong to the PICTURE rather than
      // to the box holding it. The image is letterboxed inside
      // thumbBox — a portrait photo leaves a bar down each side — so
      // rounding the box would have curved empty space and left the
      // picture's own corners square.
      //
      // ClippingRectangle rather than `clip: true`: an item's clip is
      // a rectangle, always, and never follows a radius.
      //
      // The aspect ratio is taken from the Image's IMPLICIT size, the
      // decoded source, and NOT from paintedWidth/paintedHeight. The
      // painted size is derived from the item's own size, which is now
      // this rectangle's — reading it here would be a binding loop.
      ClippingRectangle {
        id: thumbClip
        anchors.centerIn: parent
        visible: thumb.status === Image.Ready
        color: "transparent"
        radius: 5

        readonly property real ar:
          thumb.implicitWidth > 0 && thumb.implicitHeight > 0
            ? thumb.implicitWidth / thumb.implicitHeight : 1
        width: Math.max(1, Math.min(thumbBox.width,
          thumbBox.height * thumbClip.ar))
        height: Math.max(1, Math.min(thumbBox.height,
          thumbBox.width / thumbClip.ar))

        Image {
          id: thumb
          anchors.fill: parent
          opacity: tile.dim ? 0.45 : 1
          // the cached 256px PNG if the batch has made it, the original
          // otherwise — so a folder is never blank while it renders, it
          // just gets cheaper a moment later
          // A video has no thumbnail until ffmpeg has pulled a frame
          // out of it, so unlike a picture there is nothing to fall back
          // to — it shows its glyph until the batch lands.
          // Zoomed past the cache, a PICTURE goes back to the original.
          //
          // The cached thumbnails are 480px, which is generous at the
          // default tile size and not enough at the top of the zoom
          // range — a 600px tile showing a 480px PNG is visibly soft,
          // and zooming in is precisely when you are looking closely. So
          // above the cache's own resolution the original file is decoded
          // instead, at the size actually needed. A VIDEO has no such
          // fallback: its thumbnail is a frame ffmpeg had to pull out of
          // it, so it keeps the cached one at any zoom.
          readonly property bool big: thumbBox.width > 480
          source: {
            const pic = Terminus.isImage(tile.entry.name);
            // a video's frame and an audio file's cover are both
            // CACHE-ONLY: there is no original to fall back to
            const cached = Terminus.isVideo(tile.entry.name)
              || Terminus.isAudio(tile.entry.name);
            if (!pic && !cached) return "";
            const ready = root.thumbFile[tile.entry.path];
            if (ready && !(thumb.big && pic))
              return "file://" + ready;
            return pic ? "file://" + tile.entry.path : "";
          }
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          // Decode at the size drawn, not at a fixed 320: below that it
          // was decoding more than it showed, above it, less.
          sourceSize.width: Math.max(320, Math.round(thumbBox.width))
          sourceSize.height: Math.max(320, Math.round(thumbBox.height))
        }
      }

      // the glyph is the fallback AND the placeholder: it is what a
      // non-image shows, and what an image shows until it has decoded
      Text {
        anchors.centerIn: parent
        visible: thumb.status !== Image.Ready
        opacity: tile.dim ? 0.45 : 1
        text: tile.entry.glyph
        color: root.inkFor(tile.entry)
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: Math.round(40 * tile.tileZoom)
      }

      // The bookmark, as a CORNER BADGE rather than beside the name: a tile's
      // label is centred and may wrap to two lines, so there is no "beside" to
      // put it in. Same glyph and the same reason as the list's — `b b` toggles
      // both ways and the tile should say which way.
      //
      // INSIDE the box rather than anchored to it from outside. As a sibling
      // of thumbBox anchored to thumbBox's edges it drew correctly and made
      // the LETTERBOX beside it oscillate: resizing the window in grid view
      // logged a binding loop on thumbClip's width and height, nineteen of
      // them for one resize, and none at all with this item taken out. A
      // cross-sibling anchor puts two items in one another's layout pass;
      // anchoring to `parent` from within keeps it in one.
      Text {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: 6
        anchors.topMargin: 4
        visible: !!tile.entry && root.isBookmarked(tile.entry.path)
        text: "\uF02E"
        color: Zenon.sand
        opacity: tile.dim ? 0.5 : 1
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: Math.round(14 * tile.tileZoom)
      }
    }

    Text {
      anchors.top: thumbBox.bottom
      anchors.topMargin: 8
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: 8
      horizontalAlignment: Text.AlignHCenter
      id: tileName
      visible: !tile.editing
      text: tile.entry.name
      opacity: tile.dim ? 0.5 : 1
      elide: Text.ElideMiddle
      maximumLineCount: 2
      wrapMode: Text.Wrap
      color: root.inkFor(tile.entry)
      font.family: "JetBrainsMono Nerd Font Propo"
      font.weight: tile.current ? Font.Bold : Font.Medium
      // NOT scaled by zoom, unlike the tile and the glyph above it.
      // Zoom in a thumbnail view is about how big the PICTURES are;
      // scaling the filenames with them meant zooming out to fit more
      // on screen also shrank the labels towards unreadable, and
      // zooming in to inspect an image blew its name up to a headline.
      // The 62px the tile reserves for this text is a constant too, so
      // two lines always fit at every zoom.
      font.pixelSize: 16
    }

    // ── renaming, on the tile ───────────────────────────────────────
    // The grid needs its own field: EntryRow's lives in a row and this is not
    // one. Without it `a` in a thumbnail view made the file and left you with
    // no way to name it, and `r` did nothing at all — the two views disagreed
    // about whether renaming existed.
    // Behind a Loader, for the reason EntryRow's is — a grid of thumbnails
    // keeps a lot of tiles alive and only one of them is ever being renamed.
    Loader {
      id: tileEditBox
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: 6
      anchors.rightMargin: 6
      anchors.top: tileName.top
      height: tileName.height
      active: tile.editing
      sourceComponent: tileEditField
    }

    Component {
      id: tileEditField

      TextInput {
      id: tileEdit
      anchors.fill: parent
      horizontalAlignment: Text.AlignHCenter
      color: Zenon.white
      selectionColor: Zenon.selBg
      selectedTextColor: Zenon.white
      font.family: "JetBrainsMono Nerd Font Propo"
      font.weight: Font.Bold
      font.pixelSize: 16
      clip: true

      cursorDelegate: Rectangle {
        width: 2
        color: Zenon.cyan
        SequentialAnimation on opacity {
          running: tileEdit.activeFocus
          loops: Animation.Infinite
          NumberAnimation { to: 0.2; duration: 620; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1.0; duration: 620; easing.type: Easing.InOutQuad }
        }
      }

      property bool hadFocus: false

      Component.onCompleted: {
        tileEdit.hadFocus = false;
        tileEdit.text = tile.entry ? tile.entry.name : "";
        const stem = Terminus.stem(tileEdit.text);
        tileEdit.select(0, stem.length > 0 ? stem.length : tileEdit.text.length);
        tileEdit.forceActiveFocus();
        tileClaim.tries = 0;
        tileClaim.restart();
      }

      // asks until it has the keyboard — see EntryRow's editClaim
      Timer {
        id: tileClaim
        interval: 40
        repeat: true
        property int tries: 0
        onTriggered: {
          if (!tile.editing || tileEdit.activeFocus || tileClaim.tries++ > 12) {
            tileClaim.stop();
            return;
          }
          tileEdit.forceActiveFocus();
        }
      }

      Keys.onReturnPressed: (e) => {
        e.accepted = true; root.commitRename(tile.entry, tileEdit.text);
      }
      Keys.onEnterPressed: (e) => {
        e.accepted = true; root.commitRename(tile.entry, tileEdit.text);
      }
      Keys.onEscapePressed: (e) => { e.accepted = true; root.endRename(true); }
      onActiveFocusChanged: {
        if (activeFocus) { tileEdit.hadFocus = true; return; }
        if (tile.editing && tileEdit.hadFocus) root.endRename(false);
      }
      }
    }

    // Lit while a drag is over this directory — the grid's answer to the same
    // question the list row answers with its own outline.
    Rectangle {
      anchors.fill: parent
      anchors.margins: 4
      z: 6
      visible: tile.dropTarget
      color: Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.12)
      border.width: 2
      border.color: Zenon.cyan
      radius: 6
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      enabled: !tile.editing
      cursorShape: Qt.PointingHandCursor
      // ALL FIVE arguments, always. The signal is typed, and emitting it with
      // three left QML raising "Insufficient arguments" before the handler
      // ran — so every click in the grid did nothing at all while hovering
      // still worked, which is a very quiet way to break a view.
      //
      // Middle click is its own signal rather than a sixth argument: adding
      // one to a typed signal means every emit has to grow with it, and that
      // is exactly the mistake the note above is about.
      onClicked: (m) => {
        if (m.button === Qt.MiddleButton) { tile.tabbed(); return; }
        tile.chosen(m.button === Qt.RightButton,
                    (m.modifiers & Qt.ShiftModifier) !== 0,
                    (m.modifiers & Qt.ControlModifier) !== 0,
                    m.x, m.y);
      }
      onDoubleClicked: tile.opened()
    }
  }

  component EntryRow: Item {
    id: entryRow

    property var entry: null
    property bool current: false
    property bool ticked: false
    // size and modified, which only the full-width list has room for
    property bool showMeta: true
    // A row a pending CUT will take away, faded to say so. It was written for
    // the parent and preview columns, which turned out to read worse at 65%
    // than at full strength, and then sat unused — this is the question it was
    // the right answer to all along.
    property bool dim: false
    property bool clickable: true
    // Whether this row is in THE LISTING THE CURSOR MOVES THROUGH.
    //
    // False in the parent column, in the preview, and in the second pane —
    // all of which draw an EntryRow with a `current` row of their own that the
    // cursor has nothing to do with. Two things hang off it: renaming in place
    // is only ever about the active listing, and so is the sweep. Without it
    // every cursor move animated the parent column's highlighted row as well,
    // which is why the parent directory kept flashing at you.
    property bool live: false
    readonly property bool editable: entryRow.live
    readonly property bool editing:
      root.renaming && entryRow.current && entryRow.editable && !!entryRow.entry
    // Whether a right-click on this row opens the actions menu. False in the
    // panes that are not the active listing — the second pane, and the parent
    // and preview columns — because the menu acts on the ACTIVE selection, so
    // opening it from over there offers a set of verbs aimed at rows you are
    // not pointing at.
    property bool actionable: true

    // The column widths, from the same two sets the headings read — so a cell
    // is under the heading that names it by construction rather than by two
    // lists of numbers being kept in step by hand. Only the LIVE listing grows
    // a WHERE column: results replace the active pane and nothing else.
    // Set on a pane that has room for the WHERE column but not for the
    // numbers beside it — the miller middle column, and nothing else so far.
    property bool whereOnly: false
    readonly property var frac:
      (root.searchMode !== "" && entryRow.live)
        ? (entryRow.whereOnly ? root.colFoundNarrow : root.colFound)
        : root.colPlain

    // What was held down when it was clicked. The row does not decide what
    // that means — clickRow does — because the same three modifiers have to
    // mean the same three things in all three views.
    signal chosen(bool right, bool shift, bool ctrl)
    signal opened()
    // middle click: a directory in a tab of its own, the way a browser opens
    // a link. Files have nothing sensible to do with it and ignore it.
    signal tabbed()

    // true while a drag hovers THIS directory — see root.dropDirAt
    readonly property bool dropTarget: root.dropDir !== "" && !!entryRow.entry
      && entryRow.entry.isDir && root.dropDir === entryRow.entry.path

    height: root.rowH

    // ── dragging this row out ───────────────────────────────────────
    // Copied from artemis, which drags into other applications successfully;
    // terminus' own version did not, and the differences were all here.
    //
    // The attached Drag group is on the DELEGATE, not on a child Item that
    // fills it — terminus had it on a child, and a child that merely fills its
    // parent is not the same thing to Qt's drag machinery. `Drag.source` and
    // `Drag.keys` were both missing entirely, and startDrag() returned false
    // with no warning: the drag began and nothing anywhere would accept it.
    //
    // CopyAction only, like artemis. A move offered over the wayland data-device
    // means the source has to delete the file when the target says it took it,
    // and nothing here implements that half — so offering it would be a
    // promise terminus cannot keep. Moving between terminus windows is `x` then `p`.
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
    // The cursor of a pane the keyboard is NOT in. Still plainly where that
    // side's cursor is; no longer claiming to be a selection. Two filled
    // highlights on screen at once, one of them in a pane no key reaches, read
    // as terminus having chosen something on its own — which is exactly what it
    // was reported as.
    property bool passive: false

    readonly property bool cursorOnly:
      entryRow.current
        && (entryRow.passive || (!entryRow.ticked && root.markedCount > 0))

    // A light passing across the bar as the row is OPENED — Return, or a
    // double click. The same acknowledgement the grid's tiles have always
    // flared with, so a directory opened from a list and the same directory
    // opened from thumbnails answer the same way.
    //
    // NOT when the cursor arrives on it. That was the first version, and it
    // fired on every j, every k, every click and every pointer drift across
    // the list — a light washing over rows you were only passing through,
    // which reads as the window flashing at the pointer rather than as an
    // answer to anything.
    //
    // Driven by a COUNTER the window bumps, not by `current` changing. The
    // list recycles its delegates, so `current` goes true again whenever a row
    // is reused for the cursor's index — which would replay the sweep on every
    // scroll and every return to a tab.
    Connections {
      target: root
      function onOpenPulseChanged() {
        if (entryRow.live && entryRow.current) rowSweep.restart();
      }
      // and a fuller flash for a row that has just been made, so `a` shows you
      // where the new thing went before you have typed a character of its name
      function onMadePulseChanged() {
        if (entryRow.live && entryRow.current) rowBorn.restart();
      }
    }

    property real bornGlow: 0
    SequentialAnimation {
      id: rowBorn
      NumberAnimation { target: entryRow; property: "bornGlow"; to: 1;
                        duration: 110; easing.type: Easing.OutQuad }
      NumberAnimation { target: entryRow; property: "bornGlow"; to: 0;
                        duration: 520; easing.type: Easing.InQuad }
    }

    Rectangle {
      anchors.fill: parent
      clip: true
      // No hover tint. The cursor is already marked and a selection is already
      // marked; a third highlight that follows the pointer just made the list
      // twitch as it crossed.
      color: entryRow.cursorOnly ? "transparent"
        : (entryRow.current ? Zenon.selBg
          : (entryRow.ticked ? Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.10)
            : "transparent"))

      Rectangle {
        anchors.fill: parent
        visible: entryRow.bornGlow > 0
        color: Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b,
                       0.30 * entryRow.bornGlow)
      }

      Rectangle {
        id: rowSweepBar
        width: parent.width * 0.45
        height: parent.height
        visible: rowSweep.running
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: "transparent" }
          GradientStop {
            position: 0.5
            color: Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.30)
          }
          GradientStop { position: 1.0; color: "transparent" }
        }
      }

      NumberAnimation {
        id: rowSweep
        target: rowSweepBar
        property: "x"
        from: -rowSweepBar.width
        to: rowSweepBar.parent ? rowSweepBar.parent.width : 0
        duration: 340
        easing.type: Easing.OutCubic
      }

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

    // The gesture that starts a drag. Artemis' shape: a DragHandler with no
    // target, which sets Drag.active imperatively once it activates — the
    // handler decides WHEN, the attached group above decides WHAT.
    DragHandler {
      id: rowDrag
      target: null
      enabled: entryRow.clickable && !!entryRow.entry && !root.modal
      onActiveChanged: {
        if (!rowDrag.active) return;
        root.draggingRow = true;
        // The picture first, then the drag: Drag.imageSource has to be set
        // before active goes true, or the platform has already taken the
        // gesture and started carrying nothing.
        root.dragPicture(entryRow.entry, (url) => {
          entryRow.Drag.imageSource = url;
          entryRow.Drag.active = true;
        });
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
        if (right && entryRow.actionable) root.openMenuAt(entryRow, m);
      }
      onDoubleClicked: entryRow.opened()
    }

    // Lit while a drag is over this directory, so a drop says where it is
    // going before you let go of it.
    Rectangle {
      anchors.fill: parent
      z: 6
      visible: entryRow.dropTarget
      color: Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.12)
      border.width: 1
      border.color: Zenon.cyan
      radius: 4
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

      // the same inner-width arithmetic the headings use, so a cell is always
      // under the heading that names it
      Item {
        width: (parent.width - 24)
          * (entryRow.showMeta ? entryRow.frac.name : 1.0)
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
          // a step above the name it sits beside, as it always was
          font.pixelSize: Math.round(18 * root.zoom)
        }

        // ── the bookmark, beside the name ─────────────────────────
        // So that `b b` is a key you can aim. The toggle goes both ways and
        // the only way to know which way it will go was to open the sidebar
        // and read the list; now the row says so itself. Same glyph the
        // sidebar lists it under, because it is the same fact.
        Text {
          id: entryBookmark
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          visible: !!entryRow.entry && root.isBookmarked(entryRow.entry.path)
          text: "\uF02E"
          color: Zenon.sand
          opacity: entryRow.dim ? 0.65 : 1
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: Math.round(13 * root.zoom)
        }

        Text {
          id: entryName
          anchors.left: entryGlyph.right
          anchors.leftMargin: 12
          anchors.right: entryBookmark.visible ? entryBookmark.left : parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          visible: !entryRow.editing
          text: entryRow.entry
            ? entryRow.entry.name + (entryRow.entry.isLink ? " →" : "") : ""
          elide: Text.ElideMiddle
          color: entryRow.rowInk
          // The leading dot already says a file is hidden. Dimming it as well
          // said it twice and made half of ~ harder to read for nothing.
          opacity: entryRow.dim ? 0.65 : 1
          font.family: "JetBrainsMono Nerd Font Propo"
          font.weight: entryRow.current ? Font.Bold : Font.Medium
          // 16, the same number the grid's tile labels and the preview pane's
          // metadata rows use. Three different places were showing the same
          // filename at three different sizes, and a window reads as one thing
          // or it does not.
          font.pixelSize: Math.round(16 * root.zoom)
        }

        // ── renaming, IN PLACE ──────────────────────────────────────
        // The name is edited where the name is. A dialog for this asked you to
        // read the old name off a card that was covering the list it came
        // from, and answered a question you could see the answer to.
        //
        // The STEM is selected and the extension is not: renaming is almost
        // always about the name and almost never about the type, and a
        // selection that includes ".jpg" makes the common case start with an
        // arrow key.
        //
        // BEHIND A LOADER, and that is a performance change rather than a
        // structural one. A TextInput is among the heaviest items Qt Quick
        // has — an input-method bridge, a selection model, a cursor delegate —
        // and with reuseItems and a cacheBuffer this deep a directory keeps
        // upwards of a hundred delegates alive, every one of which was
        // carrying an edit field and its retry Timer for a rename that only
        // ever happens on one row. Now the field exists while there is
        // something to type into, which is also why the setup moved from
        // onVisibleChanged to Component.onCompleted: being created IS the
        // event.
        Loader {
          id: entryEditBox
          anchors.left: entryGlyph.right
          anchors.leftMargin: 12
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          height: entryRow.height
          active: entryRow.editing
          sourceComponent: entryEditField
        }

        Component {
          id: entryEditField

          TextInput {
          id: entryEdit
          anchors.fill: parent
          verticalAlignment: Text.AlignVCenter
          color: Zenon.white
          selectionColor: Zenon.selBg
          selectedTextColor: Zenon.white
          font.family: "JetBrainsMono Nerd Font Propo"
          font.weight: Font.Bold
          font.pixelSize: Math.round(16 * root.zoom)
          clip: true

          Component.onCompleted: {
            entryEdit.hadFocus = false;
            entryEdit.text = entryRow.entry ? entryRow.entry.name : "";
            const stem = Terminus.stem(entryEdit.text);
            entryEdit.select(0, stem.length > 0 ? stem.length : entryEdit.text.length);
            entryEdit.forceActiveFocus();
            editClaim.tries = 0;
            editClaim.restart();
          }

          // ASK UNTIL IT HAS IT, the same as the window's own focusClaim.
          //
          // A rename opened by `r` is asking for focus on an item that has
          // been on screen for a while, and that works first time. Creating
          // something does not: the row is built by the listing that arrives
          // after the file is made, so the forceActiveFocus above lands on an
          // item the scene has not finished placing and is dropped. The field
          // was visible and the keyboard was still in the listing, which is
          // exactly "it makes the file and will not let me name it".
          Timer {
            id: editClaim
            interval: 40
            repeat: true
            property int tries: 0
            onTriggered: {
              if (!entryRow.editing || entryEdit.activeFocus
                  || editClaim.tries++ > 12) {
                editClaim.stop();
                return;
              }
              entryEdit.forceActiveFocus();
            }
          }

          Keys.onReturnPressed: (e) => {
            e.accepted = true;
            root.commitRename(entryRow.entry, entryEdit.text);
          }
          Keys.onEnterPressed: (e) => {
            e.accepted = true;
            root.commitRename(entryRow.entry, entryEdit.text);
          }
          Keys.onEscapePressed: (e) => { e.accepted = true; root.endRename(true); }
          // Clicking away is not an answer either way, so it is a cancel —
          // the same as Escape, and never a silent rename you did not ask for.
          // Clicking away is not an answer either way, so it is a cancel — but
          // only once the field has actually HAD the keyboard, or the retry
          // above would be cancelling the very edit it is trying to open.
          onActiveFocusChanged: {
            if (activeFocus) { entryEdit.hadFocus = true; return; }
            if (entryRow.editing && entryEdit.hadFocus) root.endRename(false);
          }
          // Nothing to reset per edit any more — the field IS the edit now,
          // and it is destroyed with it. It used to be one field per recycled
          // row, which is why this had to be cleared by hand or a row would
          // carry "I once had focus" into the next file it was reused for and
          // cancel the moment anything blinked.
          property bool hadFocus: false
          }
        }
      }

      // WHERE it was found, and only while there is a search to have found it.
      //
      // A result carries its whole path and the NAME column shows the last
      // component of it, which for a search across a tree is the half you
      // cannot act on: two files called notes.md are the same row twice until
      // this column says which is which. Written relative to the directory the
      // search started in — see Terminus.whereOf — because the absolute path
      // is mostly a prefix repeated down every row.
      Text {
        width: (parent.width - 24) * entryRow.frac.where
        height: parent.height
        visible: entryRow.showMeta && entryRow.frac.where > 0
        verticalAlignment: Text.AlignVCenter
        text: entryRow.entry && entryRow.frac.where > 0
          ? Terminus.whereOf(entryRow.entry.path, root.cwd) : ""
        // The FRONT is what repeats. Two results deep in the same tree differ
        // at the end of the path, so eliding the tail would leave two rows
        // reading the same and eliding the head keeps them apart.
        elide: Text.ElideLeft
        color: Zenon.muted
        opacity: entryRow.dim ? 0.65 : 1
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: Math.round(13 * root.zoom)
      }

      // What KIND of thing it is, under the heading that sorts by it. The word
      // rather than the extension: the sort groups by kind, so the column has
      // to show the thing being grouped or the arrangement looks arbitrary.
      Text {
        width: (parent.width - 24) * entryRow.frac.kind
        height: parent.height
        visible: entryRow.showMeta && entryRow.frac.kind > 0
        verticalAlignment: Text.AlignVCenter
        text: entryRow.entry ? entryRow.entry.kind : ""
        elide: Text.ElideRight
        color: Zenon.muted
        opacity: entryRow.dim ? 0.65 : 1
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: Math.round(13 * root.zoom)
      }

      // ── the size cell, and in the usage view its bar ────────────
      //
      // The bar itself lives in UsageBar.qml, shared with the disks down the
      // sidebar — the same measurement drawn the same way in both halves of
      // the window. What is decided here is only what this column measures
      // against, and how far along it this row sits.
      Item {
        id: sizeCell
        width: (parent.width - 24) * entryRow.frac.size
        height: parent.height
        visible: entryRow.showMeta && entryRow.frac.size > 0

        readonly property bool on: root.usage && !!entryRow.entry
        // ONE call, not three. usageOf was asked once by `frac` and twice by
        // `biggest`, and it reads root.dirSizes — so the read has to stay a
        // property read for the dependency, but it only has to happen once.
        readonly property real bytes:
          sizeCell.on ? root.usageOf(entryRow.entry) : 0
        // This row's share of the biggest thing here. 0 before anything is
        // measured, which draws an empty track rather than a lie.
        readonly property real frac: (sizeCell.on && root.usageMax > 0)
          ? sizeCell.bytes / root.usageMax : 0
        // The row the mode was opened to find. Warmer, so "which is the big
        // one" is answered before any bar has been compared to any other.
        readonly property bool biggest: sizeCell.on && root.usageMax > 0
          && sizeCell.bytes >= root.usageMax
        // Measured, or still being walked. An empty track says "asked, no
        // answer yet"; no track at all would say "not part of this".
        readonly property bool pending: sizeCell.on && !!entryRow.entry
          && entryRow.entry.isDir && root.dirSizes[entryRow.entry.path] === undefined

        UsageBar {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.rightMargin: 6
          anchors.verticalCenter: parent.verticalCenter
          height: parent.height - 9
          // outside the usage mode this column is a figure, not a proportion
          bars: sizeCell.on
          // grows leftwards, so it ends where the number ends and the two
          // share an edge rather than merely overlapping
          fromRight: true
          frac: sizeCell.frac
          pending: sizeCell.pending
          accent: sizeCell.biggest ? Zenon.sand : Zenon.cyan
          // Brighter in the usage view than the muted grey it uses elsewhere,
          // because grey on a tinted band is the one place that colour stops
          // being readable.
          ink: sizeCell.on
            ? (sizeCell.biggest ? Zenon.sand : Zenon.white) : Zenon.muted
          fontSize: Math.round(14 * root.zoom)
          fontWeight: sizeCell.on ? Font.Medium : Font.Normal
          label: {
            const e = entryRow.entry;
            if (!e) return "";
            if (!e.isDir) return e.sizeText;
            // a dash until someone asks, and the real number afterwards
            const walked = root.dirSizes[e.path];
            return walked === undefined ? "\u2014" : Terminus.formatSize(walked);
          }
        }
      }

      Text {
        width: (parent.width - 24) * entryRow.frac.time
        height: parent.height
        visible: entryRow.showMeta && entryRow.frac.time > 0
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: entryRow.entry ? entryRow.entry.when : ""
        color: Zenon.muted
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: Math.round(14 * root.zoom)
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
      id: railThumb
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

      // preventStealing holds off the FLICKABLE, and that was enough while the
      // Flickable was the only thing above the rows. It is not any more: the
      // rubber band is a DragHandler declaring CanTakeOverFromAnything, and
      // below the last row — where hoverRow is false, so the band is armed —
      // it took the gesture off the rail mid-stroke and the thumb stopped
      // following the pointer. A handler cannot be out-ranked, so it is told
      // instead: while the rail has the pointer, the band is not armed.
      onPressed: (m) => {
        const top = railThumb.y;
        if (m.y >= top && m.y <= top + rail.thumbH) {
          railArea.grab = m.y - top;
        } else {
          // clicked the bare track: take the thumb by its middle and go there
          railArea.grab = rail.thumbH / 2;
          railArea.scrollTo(m.y - railArea.grab);
        }
        root.railDragging = true;
      }
      onReleased: { railArea.grab = -1; root.railDragging = false; }
      onCanceled: { railArea.grab = -1; root.railDragging = false; }
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
      font.pixelSize: 12
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
    // A bookmark can be taken off the list from the row itself. Middle-click
    // already did it and always will, but a middle click is not a thing you
    // find — it is a thing you are told about.
    property bool showRemove: false

    // 0..1 for a mounted disk, -1 when there is nothing to show a gauge from
    property real used: -1

    signal chosen()
    signal removed()
    signal toggledMount()

    // The colour a gauge is drawn in. Nearly full is worth saying in colour
    // rather than making you read the number and do the arithmetic.
    readonly property color gaugeInk: sideRow.used > 0.95 ? Zenon.red
      : (sideRow.used > 0.85 ? Zenon.yellow : Zenon.cyan)

    // A gauged row is two lines — the name, and the band with the figure in
    // it — so it is taller. A bookmark has one line and keeps the old height:
    // the sidebar should not grow by a third to hold rows with nothing to
    // measure.
    height: sideRow.used >= 0 ? 46 : 32

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
      font.pixelSize: 15
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
      anchors.right: sideDetail.visible ? sideDetail.left
        : (mountBtn.visible ? mountBtn.left
          : (removeBtn.visible ? removeBtn.left : sideRow.right))
      anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      // Above the band rather than centred on the row, once there is a band.
      anchors.verticalCenterOffset: sideRow.used >= 0 ? -11 : 0
      text: sideRow.label
      elide: Text.ElideMiddle
      color: sideRow.active ? Zenon.white : Zenon.keyInk
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 15
    }

    Text {
      id: sideDetail
      anchors.right: mountBtn.visible ? mountBtn.left : parent.right
      anchors.rightMargin: mountBtn.visible ? 8 : 12
      anchors.verticalCenter: sideLabel.verticalCenter
      // Only when there is no band to put it in. A mounted disk writes its
      // figure INSIDE the gauge — the size column does the same thing, and one
      // reading beside a bar plus another on it would be the same number twice.
      visible: sideRow.detail !== "" && sideRow.used < 0
      text: sideRow.detail
      color: Zenon.muted
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 13
    }

    // How full it is, under the name it belongs to, and how much is left
    // written inside it. A figure tells you the amount; a bar tells you whether
    // that is a lot — and which of three disks is the one filling up.
    //
    // THE SAME BAR the size column draws, from UsageBar.qml. It used to be a
    // 2px hairline with the figure sitting off to the side, which was a second
    // answer to a question the listing had already settled on an answer for.
    // Only for a mounted filesystem: an unmounted one reports no figures, and
    // a bar drawn from a guess is worse than no bar.
    UsageBar {
      id: gauge
      anchors.left: sideGlyph.right
      anchors.leftMargin: 8
      anchors.right: mountBtn.visible ? mountBtn.left : parent.right
      anchors.rightMargin: mountBtn.visible ? 8 : 12
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 7
      height: 16
      visible: sideRow.used >= 0
      // a disk fills from the left, the way every gauge does
      frac: sideRow.used
      accent: sideRow.gaugeInk
      label: sideRow.detail
      ink: sideRow.used > 0.85 ? sideRow.gaugeInk
        : (sideRow.active ? Zenon.white : Zenon.keyInk)
      fontSize: 13
    }

    Text {
      id: removeBtn
      anchors.right: parent.right
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      // Only while the row is under the pointer: a column of crosses down the
      // sidebar would be four ways to delete something you were only trying to
      // click on.
      visible: sideRow.showRemove && sideHover.hovered
      text: "\uf00d"   // nf-fa-times
      color: removeHov.hovered ? Zenon.red : Zenon.muted
      font.family: "JetBrainsMono Nerd Font Mono"
      font.pixelSize: 13

      HoverHandler { id: removeHov }
      MouseArea {
        anchors.fill: parent
        anchors.margins: -6
        cursorShape: Qt.PointingHandCursor
        onClicked: sideRow.removed()
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
      font.pixelSize: 14

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
  // ── the row of column headings ──────────────────────────────────────────
  // Both panes need one and neither can borrow the other's, because each is
  // its own view at its own width. The single-pane case still uses the strip
  // above the body; this is what goes inside a half.
  // ── a button ────────────────────────────────────────────────────────────
  // The picker's shape, used by every dialog as well. There were four sets of
  // them — the picker's bordered pills, the confirm card's tinted half-widths,
  // the permissions card's two flat words, the properties card's one — and
  // they agreed on nothing: not the height, not the corner, not what "this is
  // the one Return takes" looks like.
  //
  // `ink` is the colour it answers in and `primary` says it is the default.
  // The primary one BREATHES, because a card whose default action is the
  // dangerous one should say which is which without being read twice.
  // ── a row of exclusive choices in the settings panel ────────────────────
  // The view and the sort key are the same control twice — a strip of buttons
  // where exactly one is lit — so they are one component rather than two
  // Repeaters that would drift apart the first time either was touched.
  component PrefSeg: Item {
    id: seg
    property var options: []
    property string current: ""
    // Values that can actually be picked. null means all of them; anything
    // left out is shown REFUSING rather than hidden, because a button that
    // vanishes teaches nothing about why.
    property var allowed: null
    signal chose(string value)

    width: parent ? parent.width : 0
    height: 34

    Row {
      id: segRow
      anchors.left: parent.left
      anchors.leftMargin: 14
      anchors.right: parent.right
      anchors.rightMargin: 14
      anchors.verticalCenter: parent.verticalCenter
      height: 28
      spacing: 6

      Repeater {
        model: seg.options

        delegate: Rectangle {
          id: segBtn
          required property var modelData
          width: (segRow.width - 6 * Math.max(0, seg.options.length - 1))
            / Math.max(1, seg.options.length)
          height: 28
          radius: 5
          readonly property bool ok: seg.allowed === null
            || seg.allowed.indexOf(segBtn.modelData) >= 0
          readonly property bool on: seg.current === segBtn.modelData
          color: segBtn.on
            ? Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.18)
            : (segHov.hovered && segBtn.ok ? Zenon.surface : "transparent")
          border.width: 1
          border.color: segBtn.on ? Zenon.cyan : Zenon.msgBorder
          opacity: segBtn.ok ? 1 : 0.35
          Behavior on color { ColorAnimation { duration: Zenon.fast } }

          Text {
            anchors.fill: parent
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: segBtn.modelData
            elide: Text.ElideRight
            color: segBtn.on ? Zenon.cyan : Zenon.keyInk
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 14
          }

          HoverHandler { id: segHov; enabled: segBtn.ok }
          MouseArea {
            anchors.fill: parent
            enabled: segBtn.ok
            cursorShape: Qt.PointingHandCursor
            onClicked: seg.chose(segBtn.modelData)
          }
        }
      }
    }
  }

  // ── a continuous setting in the settings panel ──────────────────────────
  // Opacity and zoom are both a narrow useful range where the difference
  // between two neighbouring values is something you judge by looking at the
  // window rather than by counting presses. Which is a slider, twice.
  component PrefSlider: Item {
    id: sl
    property string label: ""
    property real value: 0
    property real from: 0
    property real to: 1
    property string readout: ""
    // dimmed when the value is the ordinary one, so it reads as "normal"
    // rather than as something you have changed
    property real neutral: -1
    // Wide enough for the longest label the panel actually uses. At 88 "Text
    // size" came out as "Text s…", which is a slider labelled by a guess.
    property real labelW: 116
    signal moved(real v)

    width: parent ? parent.width : 0
    height: 34

    readonly property real span: sl.to - sl.from
    readonly property real frac: sl.span > 0
      ? Math.max(0, Math.min(1, (sl.value - sl.from) / sl.span)) : 0

    Text {
      anchors.left: parent.left
      anchors.leftMargin: 14
      anchors.right: slTrack.left
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      text: sl.label
      elide: Text.ElideRight
      color: Zenon.white
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 15
    }

    Text {
      id: slRead
      anchors.right: parent.right
      anchors.rightMargin: 14
      anchors.verticalCenter: parent.verticalCenter
      width: 38
      horizontalAlignment: Text.AlignRight
      text: sl.readout
      color: (sl.neutral >= 0 && Math.abs(sl.value - sl.neutral) < 0.001)
        ? Zenon.muted : Zenon.cyan
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 13
    }

    Rectangle {
      id: slTrack
      anchors.left: parent.left
      anchors.leftMargin: sl.labelW
      anchors.right: slRead.left
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      height: 4
      radius: 2
      color: Qt.rgba(Zenon.white.r, Zenon.white.g, Zenon.white.b, 0.10)

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Math.round(sl.frac * slTrack.width)
        radius: 2
        color: Zenon.cyan
      }

      Rectangle {
        x: Math.round(sl.frac * slTrack.width) - 6
        anchors.verticalCenter: parent.verticalCenter
        width: 12
        height: 12
        radius: 6
        color: slArea.pressed ? Zenon.white : Zenon.cyan
        border.width: 1
        border.color: Zenon.black
      }

      // GRABBABLE, which a 4px line is not. The negative margins give the
      // pointer ten pixels either side — and mean a position has to have
      // those ten taken back off it before it is a fraction of the track.
      MouseArea {
        id: slArea
        anchors.fill: parent
        anchors.margins: -10
        cursorShape: Qt.PointingHandCursor

        function seek(x) {
          if (slTrack.width <= 0) return;
          const f = Math.max(0, Math.min(1, (x - 10) / slTrack.width));
          sl.moved(sl.from + f * sl.span);
        }
        onPressed: (m) => slArea.seek(m.x)
        onPositionChanged: (m) => { if (slArea.pressed) slArea.seek(m.x); }
      }
    }
  }

  // ── one switch in the settings panel ────────────────────────────────────
  // A name, the key that does the same thing, and the state as something you
  // can click. Its own component because four of these written out by hand is
  // four chances for one to drift from the other three.
  component PrefRow: Item {
    id: pref
    property string label: ""
    // The key that already did this. The panel's job is partly to teach them.
    property string hint: ""
    property bool on: false
    signal toggled()

    width: parent ? parent.width : 0
    height: 32

    Rectangle {
      anchors.fill: parent
      // the menu card's own highlight, so the two cards behave alike
      color: prefHov.hovered ? Zenon.surface : "transparent"
    }
    HoverHandler { id: prefHov }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: pref.toggled()
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: 14
      anchors.right: prefHint.visible ? prefHint.left : prefSwitch.left
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      text: pref.label
      elide: Text.ElideRight
      color: Zenon.white
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 15
    }

    Text {
      id: prefHint
      anchors.right: prefSwitch.left
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      visible: pref.hint !== ""
      text: pref.hint
      color: Zenon.muted
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 12
    }

    // A SWITCH, not a tick. A tick says "chosen from a list" and these are not
    // a list — they are four things that are each either on or off, and the
    // knob moving is what makes flipping one feel like flipping a switch.
    Rectangle {
      id: prefSwitch
      anchors.right: parent.right
      anchors.rightMargin: 14
      anchors.verticalCenter: parent.verticalCenter
      width: 30
      height: 16
      radius: 8
      color: pref.on
        ? Qt.rgba(Zenon.cyan.r, Zenon.cyan.g, Zenon.cyan.b, 0.32)
        : Qt.rgba(Zenon.white.r, Zenon.white.g, Zenon.white.b, 0.07)
      border.width: 1
      border.color: pref.on ? Zenon.cyan : Zenon.msgBorder
      Behavior on color { ColorAnimation { duration: Zenon.fast } }
      Behavior on border.color { ColorAnimation { duration: Zenon.fast } }

      Rectangle {
        y: 3
        x: pref.on ? parent.width - width - 3 : 3
        width: 10
        height: 10
        radius: 5
        color: pref.on ? Zenon.cyan : Zenon.muted
        Behavior on x {
          NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
        }
        Behavior on color { ColorAnimation { duration: Zenon.fast } }
      }
    }
  }

  // ── a small field on a card ─────────────────────────────────────────────
  // The bulk rename card's two pattern boxes. A bare TextInput on a black card
  // has no frame to say where it is or that it can be typed into, so two of
  // them side by side read as two floating words.
  // ── the shield a modal card stands behind ───────────────────────────────
  //
  // Everything a dialog has to STOP, in one place, because seven dialogs each
  // had a bare `MouseArea { anchors.fill: parent }` and each one leaked the
  // same three ways.
  //
  // ACCEPTS EVERY BUTTON. A MouseArea takes the left button only, so a right
  // click over the scrim went straight through to the listing and opened the
  // actions menu behind the card.
  //
  // EATS THE WHEEL, which a MouseArea does not see at all — so the rows kept
  // scrolling underneath a panel that was describing one of them, and the
  // cursor came back to a list that had moved.
  //
  // And the CARD gets one of its own, below its contents. A card is a plain
  // Rectangle: a press on its empty space is not accepted by anything, falls
  // through to the scrim behind, and dismissed the dialog you were filling in.
  // Declared first inside a card so the buttons and fields above it still get
  // their own clicks.
  // ── a key, drawn as a key ─────────────────────────────────────────────
  // The context menu and the F1 list are both answering the same question —
  // what do I press — and they were answering it in two different voices: one
  // in a border colour at 30% alpha that barely arrived on screen, the other
  // as plain bold text that read as a second label competing with the first.
  //
  // One shape for both. A chip says "this is a thing you type" without having
  // to be loud about it, which is what lets the ink come back up to something
  // legible: it is the outline doing the separating now, not the dimness.
  component KeyChip: Rectangle {
    id: chip
    property string label: ""
    // the menu is a compact card and the F1 list is a page you read across the
    // room, so the same chip has to be able to be both sizes
    property int fontSize: 12
    implicitWidth: chipLabel.implicitWidth + Math.round(chip.fontSize * 1.15)
    implicitHeight: chip.fontSize + 8
    radius: 5
    color: Qt.rgba(Zenon.keyInk.r, Zenon.keyInk.g, Zenon.keyInk.b, 0.10)
    border.width: 1
    border.color: Qt.rgba(Zenon.keyInk.r, Zenon.keyInk.g, Zenon.keyInk.b, 0.30)
    visible: chip.label !== ""

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: chip.label
      color: Zenon.keyInk
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: chip.fontSize
    }
  }

  component InputShield: MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    // claimed as well, so nothing behind lights up under the pointer
    hoverEnabled: true
    WheelHandler {
      // every device, and nothing passed on
      onWheel: (e) => { e.accepted = true; }
    }
  }

  component BulkField: Rectangle {
    id: fld
    property string ghost: ""
    property alias text: fldIn.text
    signal accepted()
    // Where Tab goes from here. The card owns the ring — a field should not
    // know what is next to it.
    signal tabbed()
    signal backTabbed()

    function claim() { fldIn.forceActiveFocus(); fldIn.selectAll(); }

    height: 26
    radius: 4
    color: Qt.rgba(Zenon.white.r, Zenon.white.g, Zenon.white.b, 0.05)
    border.width: 1
    border.color: fldIn.activeFocus ? Zenon.cyan : Zenon.msgBorder
    Behavior on border.color { ColorAnimation { duration: Zenon.fast } }

    // Declared FIRST, so the input above it still gets the clicks that place
    // its own caret. This one only catches the padding either side of the
    // text, which is otherwise a strip of field that does not focus it.
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.IBeamCursor
      onClicked: fldIn.forceActiveFocus()
    }

    Text {
      anchors.fill: parent
      anchors.leftMargin: 8
      verticalAlignment: Text.AlignVCenter
      visible: fldIn.text === ""
      text: fld.ghost
      color: Zenon.muted
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 14
    }

    TextInput {
      id: fldIn
      anchors.fill: parent
      anchors.leftMargin: 8
      anchors.rightMargin: 8
      verticalAlignment: Text.AlignVCenter
      color: Zenon.white
      selectionColor: Zenon.selBg
      selectedTextColor: Zenon.white
      font.family: "JetBrainsMono Nerd Font Propo"
      font.pixelSize: 14
      clip: true
      // Before the specific handlers below, which is where Tab has to be
      // caught: a TextInput otherwise hands it to the scene's own focus chain,
      // which in a card full of list delegates lands somewhere arbitrary.
      Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Tab) { e.accepted = true; fld.tabbed(); return; }
        if (e.key === Qt.Key_Backtab) { e.accepted = true; fld.backTabbed(); return; }
      }
      Keys.onReturnPressed: (e) => { e.accepted = true; fld.accepted(); }
      Keys.onEnterPressed: (e) => { e.accepted = true; fld.accepted(); }
    }
  }

  component DialogButton: Rectangle {
    id: btn
    property string label: ""
    property color ink: Zenon.muted
    property bool primary: false
    property bool ready: true
    signal clicked()
    // so a card can keep its keyboard highlight and the pointer in step
    signal hovered()

    implicitWidth: Math.max(96, btnText.implicitWidth + 34)
    implicitHeight: 28
    radius: 4
    // three states, and the pressed one is the point: a button that looks the
    // same under the finger as it does under the pointer has not confirmed
    // anything
    color: !btn.ready ? "transparent"
      : Qt.rgba(btn.ink.r, btn.ink.g, btn.ink.b,
                btnArea.pressed ? 0.45 : (btnHover.hovered ? 0.22
                  : (btn.primary ? 0.12 : 0.0)))
    border.width: 1
    border.color: btn.ready ? btn.ink : Zenon.msgBorder
    opacity: btn.ready ? 1 : 0.55

    Behavior on color {
      ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
    }

    // The pulse lives on a child rather than on the button, so hovering can
    // brighten it without fighting an animation for the same property.
    Rectangle {
      anchors.fill: parent
      radius: parent.radius
      color: "transparent"
      border.width: 1
      border.color: btn.ink
      visible: btn.primary && btn.ready
      SequentialAnimation on opacity {
        running: btn.primary && btn.ready
        loops: Animation.Infinite
        NumberAnimation { to: 0.15; duration: 900; easing.type: Easing.InOutQuad }
        NumberAnimation { to: 0.85; duration: 900; easing.type: Easing.InOutQuad }
      }
    }

    Text {
      id: btnText
      anchors.centerIn: parent
      text: btn.label
      color: btn.ready ? btn.ink : Zenon.muted
      font.family: "JetBrainsMono Nerd Font Propo"
      font.weight: Font.Bold
      font.pixelSize: 15
    }

    HoverHandler {
      id: btnHover
      enabled: btn.ready
      onHoveredChanged: if (hovered) btn.hovered()
    }
    MouseArea {
      id: btnArea
      anchors.fill: parent
      enabled: btn.ready
      cursorShape: Qt.PointingHandCursor
      onClicked: btn.clicked()
    }
  }

  component ColHeadBar: Rectangle {
    id: headBar
    y: 0
    height: 22
    color: Zenon.headBg
    // Below this the size and date columns are dropped and the name gets the
    // whole width — a half-width pane cannot carry three columns, and trying
    // ran "5.2 KiB" straight through the end of the filename. Matched by
    // EntryRow.showMeta, so the headings and the rows always agree.
    readonly property bool meta: headBar.width >= root.metaMinWidth
    // False on the pane the keyboard is NOT in. Search results only ever
    // replace the ACTIVE listing, so only the active half grows a WHERE column
    // — the other pane is still showing a directory and would have headed an
    // empty column with it.
    property bool live: true
    readonly property var frac:
      (root.searchMode !== "" && headBar.live) ? root.colFound : root.colPlain

    Row {
      anchors.fill: parent
      leftPadding: 12
      rightPadding: 12

      // THE FRACTIONS ARE OF THE INNER WIDTH, not of the whole row, and they
      // come from root.colPlain / root.colFound so the rows underneath cannot
      // disagree with the headings.
      //
      // A Row's padding comes out of the space its children have, and these
      // used to sum to 0.96 of the full width — which happened to leave about
      // enough for the 24px of padding and no more. Adding the KIND column
      // took them to a round 1.00 and the last one, MODIFIED, was pushed 24px
      // past the right edge: the "sunken" column. Subtracting the padding
      // first makes the arithmetic exact at any width, and makes the headings
      // line up with the cells under them by construction.
      ColHead {
        width: (parent.width - 24) * (headBar.meta ? headBar.frac.name : 1.0)
        label: "NAME"
        sortKey: "name"
      }
      // Only while there are results to place. No sort key: the order of a
      // search is the order the search returned, and a heading that changed it
      // would be offering to re-rank the answer by the one field the ranking
      // was never about.
      ColHead {
        width: headBar.meta ? (parent.width - 24) * headBar.frac.where : 0
        visible: headBar.meta && headBar.frac.where > 0
        label: "WHERE"
      }
      // Sorting by kind arrived without a column to click, so it was the one
      // arrangement you could only reach through a menu or a two-key sequence.
      ColHead {
        width: headBar.meta ? (parent.width - 24) * headBar.frac.kind : 0
        visible: headBar.meta
        label: "KIND"
        sortKey: "kind"
      }
      ColHead {
        width: headBar.meta ? (parent.width - 24) * headBar.frac.size : 0
        visible: headBar.meta
        // The heading says which question the column is answering: in the
        // usage mode it is no longer "how big is this file" but "how much of
        // this directory is this", and the bars under it are not sizes.
        label: root.usage ? "USAGE" : "SIZE"
        sortKey: root.usage ? "usage" : "size"
        rightAlign: true
      }
      ColHead {
        width: headBar.meta ? (parent.width - 24) * headBar.frac.time : 0
        visible: headBar.meta
        label: "MODIFIED"
        sortKey: "time"
        rightAlign: true
        // flush, like the times below it
        padRight: 0
      }
    }

    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width
      height: 1
      color: Zenon.msgBorder
    }
  }

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
      text: head.sortKey !== "" && root.sortKey === head.sortKey
        ? head.label + (root.sortDesc ? " ▾" : " ▴") : head.label
      color: head.sortKey !== "" && root.sortKey === head.sortKey ? Zenon.cyan
        : (headMa.containsMouse ? Zenon.keyInk : Zenon.muted)
      font.family: "JetBrainsMono Nerd Font"
      font.pixelSize: 12
    }

    MouseArea {
      id: headMa
      anchors.fill: parent
      hoverEnabled: true
      // A heading with no key sorts nothing, so it does not offer to: the
      // pointer stays an arrow rather than promising a click that would set
      // the sort key to the empty string and leave the list in no order at all.
      enabled: head.sortKey !== ""
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (root.sortKey === head.sortKey) root.sortDesc = !root.sortDesc;
        else { root.sortKey = head.sortKey; root.sortDesc = false; }
      }
    }
  }


}
