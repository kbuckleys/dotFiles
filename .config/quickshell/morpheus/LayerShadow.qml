// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// The drop shadow a layer casts on the desktop behind it. One definition, so
// the whole set can be retuned from Zenon rather than layer by layer, and so
// a layer picks it up in a single line:
//
//     LayerShadow { panel: bgRoot; morphed: popup.morphMode }
//
// It goes BEHIND its panel as a sibling, never as a child: a panel that clips
// (most of them do, to keep content inside their rounded corners) would clip
// its own shadow away.

import QtQuick
import QtQuick.Effects
import "."

RectangularShadow {
  id: root

  // the panel this falls behind — anchored to it, so it tracks every size
  // and morph animation without a binding per layer
  property Item panel: null
  // matched by hand rather than read off the panel: `radius` is a Rectangle
  // property, and a layer is free to hand in a panel that is not one
  property real cornerRadius: 10
  // a layer that is currently wearing the pill must not cast a shadow — it is
  // the pill at that moment, and the pill is the ground floor
  property bool morphed: false

  anchors.fill: root.panel
  radius: root.cornerRadius
  blur: Zenon.shadowBlur
  spread: 0
  offset: Qt.vector2d(0, Zenon.shadowLift)
  color: Zenon.shadowInk
  z: -1

  opacity: root.morphed ? 0 : 1
  visible: opacity > 0.01
  Behavior on opacity {
    NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease }
  }
}
