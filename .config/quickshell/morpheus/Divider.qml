// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import QtQuick.Effects
import "."

// Carries its own gap on both sides, so a divider is dropped straight into the
// bar with no flanking spacers and every divider is spaced identically.
Item {
  id: root
  implicitWidth: Zenon.gap * 2 + 1
  implicitHeight: Zenon.slot

  property bool glow: false

  Rectangle {
    id: line
    anchors.centerIn: parent
    width: 1
    height: parent.height
    color: root.glow ? Zenon.cyan : Zenon.surface
    opacity: root.glow ? 0.95 : 1

    layer.enabled: root.glow
    layer.effect: MultiEffect {
      shadowEnabled: true
      shadowColor: Zenon.cyan
      shadowBlur: 1.0
      shadowScale: 1.25
      blurMax: 32
      shadowOpacity: line.opacity
      shadowHorizontalOffset: 0
      shadowVerticalOffset: 0
    }

    Behavior on color { ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
    Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
  }
}
