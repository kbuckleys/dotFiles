// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// Which player is the one that matters, and what it is playing. Three things
// ask — the transport glyph, the track name beside it, and the hover panel
// behind both — and they must never be describing different tracks.
//
// Polled rather than bound: picking the active player means scanning the list,
// and a binding over Mpris.players does not re-run when one of those players
// starts or stops. Once a player IS picked, its own properties are bound
// normally, so play/pause is instant.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Mpris

Singleton {
  id: root

  property var player: null
  property string title: ""
  property string artist: ""
  property string album: ""
  property string artUrl: ""

  readonly property bool active: root.player !== null
  readonly property bool playing: root.player ? root.player.isPlaying : false

  // A player that has gone away mid-call leaves playerctl as the fallback, so
  // the buttons still do something rather than silently failing.
  function previous() {
    if (root.player) root.player.previous();
    else Quickshell.execDetached(["playerctl", "previous"]);
  }

  function next() {
    if (root.player) root.player.next();
    else Quickshell.execDetached(["playerctl", "next"]);
  }

  function toggle() {
    if (root.player) root.player.togglePlaying();
    else Quickshell.execDetached(["playerctl", "play-pause"]);
  }

  // playing beats paused beats nothing
  function scan() {
    const players = Mpris.players.values;
    let paused = null;
    for (let i = 0; i < players.length; ++i) {
      const p = players[i];
      if (p.isPlaying) { root.adopt(p); return; }
      if (paused === null && p.playbackState === MprisPlaybackState.Paused) paused = p;
    }
    root.adopt(paused);
  }

  function adopt(p) {
    root.player = p ?? null;
    root.title  = p ? p.trackTitle  : "";
    root.artist = p ? p.trackArtist : "";
    root.album  = p ? p.trackAlbum  : "";
    root.artUrl = p ? p.trackArtUrl : "";
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.scan()
  }

  Component.onCompleted: root.scan()
}
