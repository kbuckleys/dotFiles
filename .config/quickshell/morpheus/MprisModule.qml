// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import "helpers.js" as Helpers
import "."

Collapsible {
  id: root
  // no player at all -> the slot eases away instead of leaving a gap
  active: root.player !== null
  openWidth: row.implicitWidth

  property var player: null
  property string title: ""
  property string artist: ""
  property string album: ""

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    BarText {
      id: label
      text: {
        if (!root.player) return "";
        return root.player.isPlaying ? "\uF04B" : "\uF04C";
      }
      color: Zenon.green
    }
  }

  property bool hovered: mouse.containsMouse
  property var mousePos: mouse.containsMouse ? Qt.point(mouse.mouseX, mouse.mouseY) : null
  property string mprisTooltipText: {
    if (!root.player) return "";
    const parts = [root.title, root.artist, root.album].filter((s) => s && s !== "");
    return parts.join("\n");
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: (mouse) => {
      if (mouse.button !== Qt.LeftButton) return;
      if (root.player) root.player.previous();
      else Quickshell.execDetached(["playerctl", "previous"]);
    }
    onPressed: (mouse) => {
      if (mouse.button === Qt.RightButton) {
        if (root.player) root.player.next();
        else Quickshell.execDetached(["playerctl", "next"]);
      } else if (mouse.button === Qt.MiddleButton) {
        if (root.player) root.player.togglePlaying();
        else Quickshell.execDetached(["playerctl", "play-pause"]);
      }
    }
  }

  Timer {
    id: refresh
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()

  function refresh() {
    const players = Mpris.players.values;
    let paused = null;
    for (let i = 0; i < players.length; ++i) {
      const p = players[i];
      if (p.isPlaying) {
        root.player = p;
        root.title = p.trackTitle;
        root.artist = p.trackArtist;
        root.album = p.trackAlbum;
        return;
      }
      if (paused === null && p.playbackState === MprisPlaybackState.Paused) paused = p;
    }
    if (paused) {
      root.player = paused;
      root.title = paused.trackTitle;
      root.artist = paused.trackArtist;
      root.album = paused.trackAlbum;
    } else {
      root.player = null;
      root.title = "";
      root.artist = "";
      root.album = "";
    }
  }
}
