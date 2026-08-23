// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import "."
import "helpers.js" as Helpers

CursorAnchor {
  id: popup

  required property string text
  property bool styled: false
  property var history: []
  property color historyLineColor: Zenon.cyan
  property color historyFillColor: Zenon.cyan

  implicitWidth: background.implicitWidth
  implicitHeight: background.implicitHeight

  Rectangle {
    id: background
    implicitWidth: layout.width
    implicitHeight: layout.height
    opacity: popup.showFactor
    color: Zenon.panelBg
    border.color: Zenon.surface
    border.width: 1
    radius: 6

    Column {
      id: layout
      width: Math.max(content.implicitWidth, spark.visible ? spark.width + 40 : content.implicitWidth)
      height: content.implicitHeight + (spark.visible ? spark.height + 10 + 6 : 0)
      spacing: 0

      Text {
        id: content
        width: parent.width
        leftPadding: 20
        rightPadding: 20
        topPadding: 10
        bottomPadding: spark.visible ? 6 : 10
        text: popup.styled ? Helpers.tooltip(popup.text) : popup.text
        textFormat: popup.styled ? Text.StyledText : Text.PlainText
        color: Zenon.white
        font.family: "JetBrainsMono Nerd Font Propo"
        font.weight: Font.Bold
        font.pixelSize: 16
        horizontalAlignment: Text.AlignLeft
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.NoWrap
      }

      Sparkline {
        id: spark
        visible: popup.history && popup.history.length >= 2
        width: Math.max(160, content.implicitWidth - 20)
        height: 32
        anchors.horizontalCenter: parent.horizontalCenter
        values: popup.history
        lineColor: popup.historyLineColor
        fillColor: popup.historyFillColor
        fillOpacity: 0.18
      }

      Item { width: 1; height: spark.visible ? 10 : 0 }
    }
  }
}
