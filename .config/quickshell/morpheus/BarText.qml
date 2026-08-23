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

  text: root.styled ? Helpers.apply(root.src) : Helpers.collapse(root.src)
  textFormat: root.styled ? Text.StyledText : Text.PlainText
  color: root.textColor
  font.family: "JetBrainsMono Nerd Font Propo"
  font.weight: Font.Bold
  font.pixelSize: 16
  verticalAlignment: Text.AlignVCenter
  horizontalAlignment: Text.AlignHCenter
  renderType: Text.QtRendering

  // every module tints through BarText (usage thresholds, active/idle,
  // connected/disconnected), so easing here smooths all of them at once
  Behavior on color {
    ColorAnimation { duration: Zenon.normal; easing.type: Zenon.ease }
  }
}
