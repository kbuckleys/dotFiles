// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// The track name, and nothing else — the artist, the album and the controls
// all live one hover away in the panel. It also carries the state that a
// separate play/pause glyph used to, by inverting itself: playing is green
// filled with black text, paused is the plain green-on-nothing every other
// module wears. Swapping figure and ground reads from much further away than
// a halo did.

import QtQuick
import "."

Collapsible {
  id: root

  active: NowPlaying.active && NowPlaying.title !== ""
  openWidth: row.implicitWidth

  Row {
    id: row
    anchors.centerIn: parent
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    // Only the text lives here. The green behind it is drawn by the PILL, in
    // shell.qml: a takeover has to run to the pill's edge and round off with
    // its corner, and nothing inside the layout can reach past its own margin
    // to do that.
    Item {
      id: chip
      width: label.width + chip.pad * 2
      height: Zenon.slot
      anchors.verticalCenter: parent.verticalCenter
      readonly property int pad: 0

      BarText {
        id: label
        anchors.centerIn: parent
        text: NowPlaying.title
        // Green either way now: against a half-strength fill there is enough
        // dark showing through that the text can stay the accent colour, and
        // the state is carried by the wash appearing rather than by the words
        // inverting.
        color: Zenon.green
        // A title is arbitrarily long and the pill is only 1000px wide. Capped
        // and elided here rather than letting one song push every other module
        // off the end of the bar.
        width: Math.min(implicitWidth, 240)
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignLeft
        // Sized with the bar's numerals rather than at BarText's default.
        // Everything it sits beside — the counts, the workspaces, the clock —
        // is set at clockSize, so the default two pixels larger made the track
        // name read as the odd one out.
        font.pixelSize: Zenon.clockSize
      }
    }
  }

  // read by the audio group, which owns the shared panel
  property bool hovered: mouse.containsMouse

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    // the same middle-click toggle the transport glyph beside it takes
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onClicked: NowPlaying.toggle()
  }
}
