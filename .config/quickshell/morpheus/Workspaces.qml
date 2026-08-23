// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell.Hyprland
import "helpers.js" as Helpers
import "."

Item {
  id: root
  implicitWidth: row.implicitWidth
  implicitHeight: 32

  property string specialName: "special"

  readonly property var specialWorkspace: {
    var values = Hyprland.workspaces.values;
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].name).startsWith("special:")) return values[i];
    }
    return null;
  }

  property bool specialFocused: false

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "activespecial") {
        root.specialFocused = String(event.data).startsWith("special:");
      }
    }
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    Collapsible {
      id: special
      active: root.specialWorkspace !== null
      openWidth: specialLabel.implicitWidth + 12

      BarText {
        id: specialLabel
        anchors.centerIn: parent
        text: "\uF2D2 "
        color: root.specialFocused ? Zenon.red : Zenon.cyan
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          var sp = root.specialWorkspace !== null
              ? root.specialWorkspace.name.replace(/^special:/, "")
              : root.specialName;
          Hyprland.dispatch('hl.dsp.workspace.toggle_special("' + sp + '")');
        }
      }
    }

    Repeater {
      model: Hyprland.workspaces

      delegate: Collapsible {
        id: btn
        required property var modelData

        property bool isActive: modelData.focused

        // workspaces appear and vanish as they are used; ease the gap shut
        active: !String(modelData.name).startsWith("special:")
        openWidth: label.implicitWidth + 16

        BarText {
          id: label
          anchors.centerIn: parent
          text: {
            return ["1", "2", "3", "4", "5"].includes(String(modelData.id)) ? String(modelData.id) : " ";
          }
          color: btn.isActive ? Zenon.cyan : Zenon.dim
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            Hyprland.dispatch('hl.dsp.focus({ workspace = "' + modelData.name + '" })');
          }
        }
      }
    }
  }
}
