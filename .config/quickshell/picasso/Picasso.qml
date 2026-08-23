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
import "../morpheus/helpers.js" as Helpers
import "picasso.js" as Art

Singleton {
  id: root

  // Not a literal path: Helpers.home() reads $HOME, so this stays the same
  // string on any machine. One property, so pointing it elsewhere is one edit.
  readonly property string dir: Helpers.home() + "/Pictures/Wallpapers"

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

  function clearFor(screenName) {
    const next = Object.assign({}, root.assignment);
    delete next[screenName];
    root.assignment = next;
    saveTimer.restart();
  }

  function clearAll() {
    root.assignment = ({});
    saveTimer.restart();
  }

  // ── scanning ─────────────────────────────────────────────────────────

  function scan() {
    root.scanning = true;
    root.scanError = "";
    // -iregex over a single find rather than one pass per extension, and
    // printf so a filename with a newline in it cannot forge a second entry
    const exts = root.extensions.join("\\|");
    scanProc.command = ["sh", "-c",
      "find " + Art.shellQuote(root.dir) + " -maxdepth 2 -type f -iregex '.*\\.\\(" +
      exts + "\\)$' -printf '%p\\n' 2>/dev/null | sort"];
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
        const list = String(text || "").split("\n").filter((s) => s.trim() !== "");
        root.files = list;
        root.scanning = false;
      }
    }
  }

  // The directory is watched, so dropping a new image in shows up without a
  // rescan being asked for. Cheap: it fires on directory mtime, not polling.
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
