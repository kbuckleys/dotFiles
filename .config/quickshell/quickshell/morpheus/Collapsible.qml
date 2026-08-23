// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
// A bar slot that eases to zero width when it has nothing to show, so the pill
// shrink-wraps instead of reserving a dead gap. Children are ordinary children:
// they clip away as the slot narrows and stop taking input once it is closed.

import QtQuick
import "."

Item {
  id: root

  // true while the slot has something worth showing
  property bool active: true
  // the slot's content width when open
  property real openWidth: 0

  // Only the open/shut transition is animated — `openWidth` passes straight
  // through. Putting a Behavior directly on implicitWidth would make a nested
  // or content-driven slot chase a moving target and rubber-band.
  property real factor: root.active ? 1 : 0
  Behavior on factor {
    NumberAnimation { duration: Zenon.normal; easing.type: Easing.OutCubic }
  }

  implicitWidth: root.openWidth * root.factor
  implicitHeight: 32
  opacity: root.factor
  // leave the layout, and stop taking input, only once fully collapsed
  visible: root.factor > 0.01
  clip: true
}
