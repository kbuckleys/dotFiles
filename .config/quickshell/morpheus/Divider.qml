// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import "."

// Carries its own gap on both sides, so a divider is dropped straight into the
// bar with no flanking spacers and every divider is spaced identically.
Item {
  id: root
  implicitWidth: Zenon.gap * 2 + 1
  implicitHeight: 32

  Rectangle {
    anchors.centerIn: parent
    width: 1
    height: parent.height
    color: Zenon.surface
  }
}
