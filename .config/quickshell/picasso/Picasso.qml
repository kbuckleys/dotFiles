// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// PICASSO — the wallpaper store. Quickshell is the daemon itself here: there
// is no swww or hyprpaper to talk to, the background is just another layer
// surface this shell owns. This singleton holds what is chosen and where the
// choices live; PicassoDaemon paints them and PicassoPopup picks them.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../morpheus"
import "../morpheus/thumbs.js" as Thumbs
import "picasso.js" as Art

Singleton {
  id: root

  // Not a literal path: Paths.home() reads $HOME, so this stays the same
  // string on any machine. One property, so pointing it elsewhere is one edit.
  readonly property string dir: Paths.home() + "/Pictures/Wallpapers"

  // Where the thumbnails live and how big they are is morpheus/thumbs.js'
  // business, not picasso's — see scan(), which builds both from Thumbs so a
  // wallpaper terminus has already thumbnailed is found here under the same
  // name. Picasso carried its own cacheDir and thumbSize until that move and
  // then kept them, unread, describing a size and a directory neither of which
  // was in use any more.

  // How an image that is not the monitor's shape gets fitted. Cover by
  // default: this setup pairs a 2560x1440 with a rotated 1080x1920, and
  // anything else letterboxes one of them badly.
  property int fillMode: Image.PreserveAspectCrop

  readonly property var extensions: ["jpg", "jpeg", "png", "webp", "bmp", "gif", "jxl", "avif"]

  // every wallpaper found, sorted, newest scan wins
  property var files: []
  property bool scanning: false
  property string scanError: ""

  // ── what is on screen ────────────────────────────────────────────────
  // monitor name -> path, plus "*" for the one every other monitor uses.
  // Keyed by name rather than index because a monitor's index changes when
  // you unplug the other one, and the wallpaper should not follow it.
  property var assignment: ({})

  readonly property string fallbackKey: "*"

  // Trigger for replaying the wallpaper zoom on unlock — bumped by shell
  // when Cerberus releases the session, watched by PicassoDaemon per-screen.
  property int introTick: 0
  property int holdTick: 0
  function replayIntro() { root.introTick++ }
  function holdIntro() { root.holdTick++ }

  // ── ordering ─────────────────────────────────────────────────────────
  // Newest first by default: a wallpaper you just dropped in is the one you
  // are most likely opening the picker to find. Held here rather than in the
  // popup so the choice survives closing and reopening it.
  readonly property var sortModes: ["recent", "name", "size"]
  property int sortIndex: 0
  readonly property string sortMode: root.sortModes[root.sortIndex]

  function cycleSort() {
    root.sortIndex = (root.sortIndex + 1) % root.sortModes.length;
  }

  function wallpaperFor(screenName) {
    const a = root.assignment;
    if (a[screenName]) return a[screenName];
    if (a[root.fallbackKey]) return a[root.fallbackKey];
    return "";
  }

  // one wallpaper everywhere: clears the per-monitor overrides too, otherwise
  // "set everywhere" would quietly leave an old override in place
  function setAll(path) {
    root.assignment = { [root.fallbackKey]: path };
    saveTimer.restart();
  }

  function setFor(screenName, path) {
    const next = Object.assign({}, root.assignment);
    next[screenName] = path;
    root.assignment = next;
    saveTimer.restart();
  }

  function clearAll() {
    root.assignment = ({});
    saveTimer.restart();
  }

  // ── scanning ─────────────────────────────────────────────────────────

  // Scan and thumbnail in one pass. It generates only what is missing, so the
  // cost is paid once per new wallpaper and never again — the picker used to
  // re-decode every full-size original on every filter keystroke.
  //
  // The cache key is path+mtime+size, which means replacing a wallpaper with a
  // different image of the same name produces a NEW cache filename. That is
  // what lets the picker turn Qt's image cache back on: a changed file is
  // never the same URL, so a decode failure can never be cached against it.
  function scan() {
    root.scanning = true;
    root.scanError = "";
    const exts = root.extensions.join("\\|");
    const dirQ = Strings.shellQuote(root.dir);
    // The KEY AND THE SIZE ARE NOT PICASSO'S ANY MORE. Both come from
    // morpheus/thumbs.js, so a wallpaper terminus has already thumbnailed is
    // found here under the name terminus' generator gave it, and vice versa.
    // find only has to produce the path now: the shared expression stats the
    // file itself, which is also what guarantees both sides hash exactly the
    // same bytes rather than two spellings of the same mtime.
    scanProc.command = ["sh", "-c",
      'mkdir -p ' + Strings.shellQuote(Thumbs.dir()) + '; ' +
      // Recursive: wallpapers arrive in per-pack subdirectories, and a
      // depth limit silently hid most of them. Dot-directories are pruned so
      // a stray .thumbnails or version-control dir is not treated as art.
      'find ' + dirQ + " -type f -not -path '*/.*' -iregex '.*\\.\\(" + exts + "\\)$' " +
      "-print 2>/dev/null | sort | " +
      'while IFS= read -r p; do ' +
      '  set -- "$p"; ' +
      Thumbs.keyExpr() +
      '  [ -s "$out" ] || magick "$1"[0] -auto-orient -thumbnail '
        + Thumbs.size() + 'x' + Thumbs.size() + ' -strip "$out" 2>/dev/null; ' +
      // path, thumb, mtime, size — the last two so the picker can order by
      // them without going back to the disk on every sort change
      '  if [ -s "$out" ]; then printf \'%s\\t%s\\t%s\\t%s\\n\' "$1" "$out" "$mt" "$sz"; ' +
      '  else printf \'%s\\t\\t%s\\t%s\\n\' "$1" "$mt" "$sz"; fi; ' +
      'done; ' +
      // The pool is shared, so "delete anything no wallpaper claims" would
      // delete every thumbnail terminus made. Age is the only question either
      // side can answer about the other's entries.
      Thumbs.sweep(30)];
    scanProc.running = true;
  }

  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      // `text` is StdioCollector's own property, not a signal parameter.
      // Declaring it as one shadowed the property with undefined, and the
      // scan quietly returned nothing at all.
      onStreamFinished: {
        root.files = Art.parseRows(text);
        root.scanning = false;
      }
    }
  }

  // The top of the tree is watched, so dropping a new image or a new pack in
  // pre-generates its thumbnail before the picker is ever opened. Only the top:
  // a watch per subdirectory would be a lot of machinery for a head start, and
  // the picker rescans on open regardless, so nothing is ever missed — a file
  // added deep in the tree just pays its 0.2s thumbnail on first open.
  FileView {
    id: dirWatch
    path: root.dir
    watchChanges: true
    printErrors: false
    onFileChanged: rescanDebounce.restart()
  }

  Timer {
    id: rescanDebounce
    // copying a batch of files in fires this repeatedly; scan once at the end
    interval: 500
    onTriggered: root.scan()
  }

  // ── persistence ──────────────────────────────────────────────────────

  FileView {
    id: stateFile
    path: Quickshell.statePath("picasso.json")
    blockLoading: true
    printErrors: false
  }

  Timer {
    id: saveTimer
    interval: 250
    onTriggered: stateFile.setText(Art.serialize(root.assignment))
  }

  Component.onCompleted: {
    root.assignment = Art.parse(stateFile.text());
    root.scan();
  }
}
