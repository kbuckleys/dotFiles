// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// STRINGS — the two string functions every layer needed a copy of.
//
// shellQuote had ten identical definitions and escapeHtml nine, one per
// layer's own .js. Nineteen copies of six lines, and two of them had already
// drifted: picasso and howler had grown a `?? ""` the others never got, so the
// same call was null-safe in two layers and threw in the rest. That is what
// duplicated logic does, and it is the whole argument for this file.
//
// A SINGLETON rather than a shared .js, which is not a style choice. A .js
// file gains its own scope the moment it carries an `.import` statement, and
// loses the QML document's — so a layer's .js that imported a helpers library
// would stop being able to reach `Quickshell.env`, which several of them call.
// A plain .js keeps the host document's scope, and a singleton the document
// imports is in it: verified before this file was written.
//
// The null-safe forms are the ones kept. They are supersets — the same result
// for every input the others accepted, and an answer instead of a throw for
// null and undefined.

pragma Singleton

import QtQuick
import "."

QtObject {
  // POSIX single-quoting: wrap in quotes and replace each embedded quote with
  // '\'' — close, escape, reopen. Safe for every byte a filename can hold,
  // which is why every layer that shells out reaches for it.
  function shellQuote(s) {
    return "'" + String(s ?? "").replace(/'/g, "'\\''") + "'";
  }

  // The palette as plain 6-digit hex strings, for the places that need colour
  // as TEXT rather than as a colour: rich-text markup, and janus' translation
  // of bat's ANSI output. Zenon owns the values; this is only the form.
  function zenonHex() {
    return {
      black: Zenon.hex(Zenon.black), white: Zenon.hex(Zenon.white),
      muted: Zenon.hex(Zenon.muted), red: Zenon.hex(Zenon.red),
      green: Zenon.hex(Zenon.green), yellow: Zenon.hex(Zenon.yellow),
      blue: Zenon.hex(Zenon.blue), magenta: Zenon.hex(Zenon.magenta),
      cyan: Zenon.hex(Zenon.cyan), pink: Zenon.hex(Zenon.pink),
      sand: Zenon.hex(Zenon.sand)
    };
  }

  // The three characters that turn text into markup. Enough for Qt's
  // StyledText and RichText, which is all this shell renders.
  function escapeHtml(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
}
