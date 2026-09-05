// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import "helpers.js" as Helpers
import "."

Text {
  id: root
  property string src: ""
  property bool styled: false
  property color textColor: Zenon.white
  // Digits that belong to the clock's family rather than to body text —
  // counts and workspace numbers. One flag instead of the family and size
  // restated at every call site, so there is still one answer to "what does a
  // number look like in this bar".
  property bool numeric: false

  text: root.styled ? Helpers.apply(root.src) : Helpers.collapse(root.src)
  textFormat: root.styled ? Text.StyledText : Text.PlainText
  color: root.textColor
  font.family: root.numeric ? Zenon.clockFamily : "JetBrainsMono Nerd Font Propo"
  font.weight: Font.Bold
  font.pixelSize: root.numeric ? Zenon.clockSize : Zenon.textSize
  // Sized to the slot rather than to its own line. A bare BarText next to a
  // taller sibling in a Row would otherwise align to the TOP of the row —
  // which is what stranded the notification bell against the top of the pill.
  height: Zenon.slot
  verticalAlignment: Text.AlignVCenter
  horizontalAlignment: Text.AlignHCenter
  renderType: Text.QtRendering

  // every module tints through BarText (usage thresholds, active/idle,
  // connected/disconnected), so easing here smooths all of them at once
  Behavior on color {
    ColorAnimation { duration: Zenon.normal; easing.type: Zenon.ease }
  }
}
