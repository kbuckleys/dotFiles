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
  // Left by default, because most tooltips here are label/value lists and
  // ragged-right is what makes those scannable. A tooltip that is a couple of
  // short standalone lines reads better centred, and says so.
  property int align: Text.AlignLeft
  // Zero or more sparklines under the text, each { values, line, fill }.
  // A list rather than one series plus a colour pair: network has two
  // channels to plot, and a second set of history/historyLineColor/... would
  // have been a parallel way of saying the same thing.
  property var series: []

  // only the ones with enough points to draw; a Sparkline needs two
  readonly property var liveSeries: {
    const out = [];
    const src = popup.series ?? [];
    for (let i = 0; i < src.length; ++i) {
      const s = src[i];
      if (s && s.values && s.values.length >= 2) out.push(s);
    }
    return out;
  }

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
      width: Math.max(content.implicitWidth,
        sparks.visible ? sparks.implicitWidth + 40 : content.implicitWidth)
      height: content.implicitHeight
        + (sparks.visible ? sparks.implicitHeight + 10 + 6 : 0)
      spacing: 0

      Text {
        id: content
        width: parent.width
        leftPadding: 20
        rightPadding: 20
        topPadding: 10
        bottomPadding: sparks.visible ? 6 : 10
        text: popup.styled ? Helpers.tooltip(popup.text) : popup.text
        textFormat: popup.styled ? Text.StyledText : Text.PlainText
        color: Zenon.white
        font.family: "JetBrainsMono Nerd Font Propo"
        font.weight: Font.Bold
        font.pixelSize: 16
        horizontalAlignment: popup.align
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.NoWrap
      }

      Column {
        id: sparks
        visible: popup.liveSeries.length > 0
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 4

        // Modelled on the COUNT, not on the list itself. The list is rebuilt
        // every time its data changes — four times a second for network — and
        // a Repeater handed a new array destroys and recreates every delegate,
        // which is what made the traces flicker. A count that stays 2 leaves
        // the delegates alone and lets their bindings update in place.
        Repeater {
          model: popup.liveSeries.length

          delegate: Sparkline {
            required property int index
            readonly property var cfg: popup.liveSeries[index] ?? null
            width: Math.max(160, content.implicitWidth - 20)
            height: 32
            values: cfg ? cfg.values : []
            lineColor: cfg ? cfg.line : Zenon.cyan
            // most callers want the fill to be the line's own colour
            fillColor: cfg ? (cfg.fill ?? cfg.line) : Zenon.cyan
            fillOpacity: 0.18
          }
        }
      }

      Item { width: 1; height: sparks.visible ? 10 : 0 }
    }
  }
}
