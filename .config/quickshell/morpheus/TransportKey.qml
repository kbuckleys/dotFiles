// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// One transport button — previous, play/pause, next. Shared by the song
// toast's hover row and the now-playing panel, which drew the same three
// glyphs with the same hover behaviour twice.

import QtQuick
import "."

Text {
  id: key

  property string glyph: ""
  property color ink: Zenon.white
  property int size: 20
  signal activated()

  text: key.glyph
  color: key.ink
  font.family: "JetBrainsMono Nerd Font Propo"
  font.weight: Font.Bold
  font.pixelSize: key.size
  // dim until pointed at, so a row of three reads as three targets rather
  // than three decorations
  opacity: keyArea.containsMouse ? 1 : 0.55
  Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

  MouseArea {
    id: keyArea
    anchors.fill: parent
    // a glyph is a small target; grow the hit area past its ink
    anchors.margins: -6
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: key.activated()
  }
}
