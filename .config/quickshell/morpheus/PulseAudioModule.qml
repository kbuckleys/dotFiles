// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import "helpers.js" as Helpers
import "."

Item {
  id: root
  implicitWidth: row.implicitWidth
  implicitHeight: Zenon.slot

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    spacing: 6

    BarText {
      // only while muted: unmuted, the meter says everything the glyph would
      visible: Volume.muted
      text: ""
      color: Zenon.red
    }

    Meter {
      anchors.verticalCenter: parent.verticalCenter
      // a muted sink reads as empty rather than as its remembered level
      value: Volume.muted ? 0 : Volume.level
      accent: Volume.muted ? Zenon.red : Zenon.green
    }
  }

  // The panel is not declared here. It belongs to the audio group in
  // shell.qml, which spans this and the track name beside it: two modules
  // showing the same panel from two different anchors meant crossing between
  // them closed one and reopened the other somewhere else.
  property bool hovered: mouse.containsMouse

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: Quickshell.execDetached(["kitty", "-1", "-T", "Wiremix", "wiremix"])
    onPressed: (mouse) => { if (mouse.button === Qt.RightButton) Quickshell.execDetached(["pamixer", "-t"]) }
    onWheel: (wheel) => {
      Volume.nudge(wheel.angleDelta.y > 0 ? 0.01 : -0.01);
      wheel.accepted = true;
    }
  }
}
