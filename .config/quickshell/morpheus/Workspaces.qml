// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Hyprland
import "helpers.js" as Helpers
import "."

Item {
  id: root
  implicitWidth: row.implicitWidth
  implicitHeight: Zenon.slot

  property string specialName: "special"

  readonly property var specialWorkspace: {
    var values = Hyprland.workspaces.values;
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].name).startsWith("special:")) return values[i];
    }
    return null;
  }

  // monitor-agnostic: any special focused on any monitor counts
  property string _activeSpecialName: ""
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "activespecial") {
        const parts = String(event.data).split(",");
        root._activeSpecialName = parts[0] ? parts[0].trim() : "";
      }
    }
  }
  readonly property bool specialFocused: {
    if (root.specialWorkspace === null) return false;
    if (root._activeSpecialName !== "") return true;
    try {
      const fw = Hyprland.focusedWorkspace;
      if (fw && String(fw.name).startsWith("special:")) return true;
    } catch (e) {}
    const sw = root.specialWorkspace;
    return sw.focused === true;
  }

  MouseArea {
    anchors.fill: parent
    visible: root.specialWorkspace !== null
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      var sp = root.specialWorkspace !== null
          ? root.specialWorkspace.name.replace(/^special:/, "")
          : root.specialName;
      Hyprland.dispatch('hl.dsp.workspace.toggle_special("' + sp + '")');
    }
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    Repeater {
      model: Hyprland.workspaces

      delegate: Collapsible {
        id: btn
        required property var modelData

        property bool isActive: modelData.focused

        // workspaces appear and vanish as they are used; ease the gap shut
        active: !String(modelData.name).startsWith("special:")
        openWidth: wsBox.implicitWidth + Zenon.padModule * 2

        Item {
          id: wsBox
          anchors.centerIn: parent
          implicitWidth: Math.max(wsGhost.implicitWidth, wsLabel.implicitWidth)
          implicitHeight: Zenon.slot

          BarText {
            id: wsGhost
            anchors.centerIn: parent
            text: "8"
            numeric: true
            color: Zenon.trough(Zenon.cyan)
          }

          BarText {
            id: wsLabel
            anchors.centerIn: parent
            text: {
              return ["1", "2", "3", "4", "5"].includes(String(modelData.id)) ? String(modelData.id) : " ";
            }
            numeric: true
            color: {
              if (root.specialWorkspace !== null && root.specialFocused)
                return btn.isActive ? Zenon.pink : Zenon.trough(Zenon.pink)
              return btn.isActive ? Zenon.cyan : Zenon.dim
            }
            font.weight: {
              if (root.specialWorkspace !== null && btn.isActive)
                return Font.Black
              return btn.isActive ? Font.ExtraBold : Font.Bold
            }
          }
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
