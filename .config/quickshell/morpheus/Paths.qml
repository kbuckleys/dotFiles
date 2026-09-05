// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// PATHS — where this user's things live, read from the environment once.
//
// home() had five identical definitions across the layers' .js files and
// cacheDir() three. All eight were byte-for-byte the same, which is the
// harmless end of duplication — but it is still eight places to edit the day
// one of them should have honoured XDG_HOME, and eight places for the next
// reader to check before believing any of them.
//
// A SINGLETON for the same reason Strings is one: a layer's .js cannot import
// a shared library without losing the QML document's scope, and losing that
// scope is losing `Quickshell.env` — which is the only thing these functions
// do. A singleton the host document imports stays in reach.

pragma Singleton

import QtQuick
import Quickshell

QtObject {
  function home() {
    return Quickshell.env("HOME");
  }

  // XDG's own fallbacks, spelled out rather than assumed: a machine that sets
  // XDG_CACHE_HOME somewhere other than ~/.cache is entitled to be obeyed.
  function cacheDir() {
    return Quickshell.env("XDG_CACHE_HOME") || Paths.home() + "/.cache";
  }

  function tmpDir() {
    return Quickshell.env("TMPDIR") || "/tmp";
  }

  // Where other programs' configuration lives, for the times this shell reads
  // someone else's file rather than its own — hermes takes its icon map
  // straight out of the yazi flavor instead of keeping a second copy of it.
  function configDir() {
    return Quickshell.env("XDG_CONFIG_HOME") || Paths.home() + "/.config";
  }
}
