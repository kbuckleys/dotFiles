// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// USAGE BAR — a measurement drawn as a length, with its own figure written
// inside it.
//
// One bar, two places: the size column in the disk-usage view, and the disks
// down the sidebar. They were drawn separately — a 15px band with the figure
// inside it in one, a 2px hairline with the figure sitting somewhere else in
// the other — which is two answers in one window to the same question.
//
// The number sits ON the bar. A bar and a caption beside it are two things to
// read; one band with its own value written in it is one. The TRACK is what
// makes a short bar mean anything: every row shows the full length as well as
// its own share, so "small" is read against "small compared to what" rather
// than floating in the dark.
//
// A FILE of its own rather than an inline component, because both callers are
// themselves inline components of TerminusWindow — and because the size column
// and the sidebar are as far apart as two parts of that document get.

import QtQuick
import "../morpheus"

Item {
  id: bar

  // 0..1. Clamped rather than drawn past the end of its own track.
  property real frac: 0
  // Asked for, not answered yet. An empty track says so; no track at all
  // would say this row is not part of the question.
  property bool pending: false
  // false takes the band away and leaves the figure — the size column with the
  // usage mode off, which is a number and not a proportion.
  property bool bars: true
  property string label: ""
  property color accent: Zenon.cyan
  property color ink: Zenon.white
  // The listing's bar grows leftwards to MEET its number at the right edge.
  // A disk fills from the left, the way every gauge does.
  property bool fromRight: false
  property real labelPad: 8
  property real barRadius: 4
  property int fontSize: 14
  property int fontWeight: Font.Medium

  readonly property real span: Math.max(0, Math.min(1, bar.frac))

  Rectangle {
    id: track
    anchors.fill: parent
    visible: bar.bars
    radius: bar.barRadius
    color: Qt.rgba(Zenon.white.r, Zenon.white.g, Zenon.white.b, 0.07)
  }

  Rectangle {
    id: fill
    visible: bar.bars
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.left: bar.fromRight ? undefined : parent.left
    anchors.right: bar.fromRight ? parent.right : undefined
    radius: bar.barRadius
    // No artificial minimum. A floor of a few pixels made 6 B and 0 B look
    // like the same measurement with a rendering fault, and the figure inside
    // already says which is which — so a share too small to draw is not drawn.
    width: (bar.pending || bar.span <= 0) ? 0 : Math.round(bar.span * bar.width)

    // Lit along the top edge. A flat block at this height reads as a slab; the
    // sheen is what makes it read as a bar. Two stops, so no gradient library.
    //
    // Kept CLOSE TO THE TRACK in tone on purpose. The fill's edge lands
    // wherever the measurement puts it, which for most rows is somewhere in
    // the middle of the number — and against a bright fill that edge cut the
    // digits in half. Softened, the length still reads at a glance while the
    // number stays one piece of text on one surface.
    gradient: Gradient {
      GradientStop {
        position: 0.0
        color: Qt.rgba(bar.accent.r, bar.accent.g, bar.accent.b, 0.30)
      }
      GradientStop {
        position: 1.0
        color: Qt.rgba(bar.accent.r, bar.accent.g, bar.accent.b, 0.17)
      }
    }

    // The leading edge, brighter than the fill it ends.
    //
    // An unmarked edge inside the number reads as the digits having been cut
    // in half; a deliberate line reads as a mark on a scale, which is what it
    // is. Hidden at the extremes, where there is nothing to mark: a full bar
    // has no interior edge and an empty one has no bar.
    Rectangle {
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.left: bar.fromRight ? parent.left : undefined
      anchors.right: bar.fromRight ? undefined : parent.right
      width: 1
      visible: bar.span > 0.01 && bar.span < 0.995
      color: Qt.rgba(bar.accent.r, bar.accent.g, bar.accent.b, 0.55)
    }

    Behavior on width {
      NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease }
    }
  }

  // Declared last so it draws over the band.
  Text {
    anchors.fill: parent
    horizontalAlignment: Text.AlignRight
    verticalAlignment: Text.AlignVCenter
    rightPadding: bar.labelPad
    text: bar.label
    color: bar.ink
    elide: Text.ElideRight
    font.family: "JetBrainsMono Nerd Font Propo"
    font.pixelSize: bar.fontSize
    // enough weight to stay one word where the fill's edge crosses it
    font.weight: bar.fontWeight
  }
}
