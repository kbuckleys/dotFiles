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

  // Spoot-like: big, soft, present. For quickshell layers the
  // shadow should show even when the layer is morphed into the pill —
  // spoot's panel and cards all cast, and the pill is not ground floor
  // in that design. Only morpheus/erebus/runner have no LayerShadow at
  // all, so this can stay visible.
  anchors.fill: root.panel
  radius: root.cornerRadius
  blur: Zenon.shadowBlur
  spread: Zenon.shadowGrow
  offset: Qt.vector2d(0, Zenon.shadowDrop)
  color: Zenon.shadowInk
  z: -1

  opacity: 1
  visible: true
}
