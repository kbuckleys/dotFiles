// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
// A divider that eases away with the group it separates, so an empty side of
// the bar never leaves a seam floating against the pill edge.

import QtQuick
import "."

Collapsible {
  openWidth: rule.implicitWidth
  Divider { id: rule; anchors.centerIn: parent }
}
