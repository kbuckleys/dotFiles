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
  // single token in Zenon — 8:8 uniform
  property real cornerRadius: Zenon.pillRadius
  // a layer that is currently wearing the pill must not cast a shadow — it is
  // the pill at that moment, and the pill is the ground floor
  property bool morphed: false

  anchors.fill: root.panel
  radius: root.cornerRadius
  blur: Zenon.shadowBlur
  spread: Zenon.shadowGrow
  offset: Qt.vector2d(0, Zenon.shadowDrop)
  color: Zenon.shadowInk
  z: -1

  // And this is where `morphed` was always meant to land. It was wired through
  // from every caller and then never read, so a morphed layer went on casting
  // its full shadow — grown 4, blurred 24, 0.60 black. Morphed, the layer's
  // rect IS the pill's rect and this window sits on the OVERLAY layer, above
  // the bar: so that shadow was not falling under anything, it was painting a
  // black halo on top of the pill and spilling past its border. That is the
  // dark block that appeared around the pill's edge whenever a layer morphed
  // out of morpheus, and never when one opened standalone.
  //
  // Eased rather than switched, so handing the pill straight from one layer to
  // another cannot blink it.
  opacity: root.morphed ? 0 : 1
  Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
  visible: root.opacity > 0.01
}
