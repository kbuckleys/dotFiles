// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// DESKTOP — where an application's .desktop file lives, and how to run one.
//
// Three layers launch applications and all three had their own answer. Two of
// them called `gtk-launch`, which runs an entry's Exec line and NOTHING else —
// so an entry declaring Terminal=true (nvim, htop, anything meant to be read
// in a terminal) was started with no terminal around it and died instantly,
// silently, because the launch itself had succeeded. Every row under cynosure's
// app list and icarus' desktop menu was quietly broken for those.
//
// `gio launch` honours Terminal=true and spawns the terminal. It wants the
// desktop FILE rather than the id, which is the other half of this file: the
// search path, written once so terminus, cynosure and icarus cannot disagree
// about where an entry lives.
//
// And it is the XDG path, not the two directories that were hardcoded before.
// $XDG_DATA_HOME then each of $XDG_DATA_DIRS, with the spec's own defaults —
// which is what makes an entry installed by a Flatpak, or by a distribution
// that uses /usr/local, findable at all.
//
// A SINGLETON for the same reason Strings and Paths are: a layer's .js cannot
// import a shared library without losing the QML document's scope, and a
// singleton the document already imports is in reach from both.

pragma Singleton

import QtQuick
import Quickshell
import "."

QtObject {
  // The search path as a shell WORD LIST, ready to drop into `for d in …`.
  //
  // Unquoted expansion of the second half is deliberate: XDG_DATA_DIRS is
  // colon-separated by specification, so splitting it on spaces afterwards is
  // exactly the intent. A data directory with a space in its name would be
  // mangled, and no such directory exists on any system this shell runs on.
  function dirsExpr() {
    return "\"${XDG_DATA_HOME:-$HOME/.local/share}/applications\" "
      + "$(printf %s \"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}\" "
      + "| tr : '\\n' | sed 's|$|/applications|' | tr '\\n' ' ')";
  }

  // The desktop id as a FILE NAME.
  //
  // DesktopEntry.id is the id, not the file: quickshell hands back `mpv`,
  // `discord`, `org.kde.okular` — never the `.desktop` on the end. Every path
  // built here is checked with `[ -f ]` against a real directory, so an id
  // without the suffix matches nothing, every directory in the search path is
  // skipped, and the loop falls through to `exit 1`. The caller redirects to
  // /dev/null, so all three launching layers failed in complete silence.
  //
  // Appended conditionally because a caller that already holds a file name
  // (terminus reads real directory entries) would otherwise ask for
  // `mpv.desktop.desktop`.
  function fileName(id) {
    const s = String(id);
    return s.endsWith(".desktop") ? s : s + ".desktop";
  }

  // Launch an application by its desktop id, trying every place it is
  // installed until one of them actually runs.
  //
  // THE FIRST MATCH IS NOT NECESSARILY THE RIGHT ONE. A user entry in
  // ~/.local/share/applications shadows the system's, which is the whole point
  // of that directory — but a shadowing entry can also be stale, and gio
  // refuses to load an entry whose Exec binary is not on PATH. Stopping at the
  // first file that EXISTS therefore fails for exactly the case the search
  // path exists to handle. Stopping at the first that LAUNCHES falls through
  // to the system's copy instead, which is what the user meant either way.
  //
  // gtk-launch, which this replaced, never noticed: it runs the Exec line
  // without checking anything, so a stale override failed silently at the
  // shell instead of loudly here.
  //
  // `arg` is optional and is handed to the entry as its file or url argument.
  function launchCommand(id, arg) {
    const a = (arg === undefined || arg === null || arg === "")
      ? "" : " " + Strings.shellQuote(arg);
    return "for d in " + dirsExpr() + "; do\n"
      + "  f=\"$d/\"" + Strings.shellQuote(fileName(id)) + "\n"
      + "  [ -f \"$f\" ] || continue\n"
      + "  gio launch \"$f\"" + a + " >/dev/null 2>&1 && exit 0\n"
      + "done\n"
      + "exit 1\n";
  }
}
