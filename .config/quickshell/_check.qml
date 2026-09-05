import QtQuick
import Quickshell
import Quickshell.Wayland
import "morpheus"

ShellRoot {
  PanelWindow {
    id: w
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors { top: true; left: true }
    implicitWidth: 10
    implicitHeight: 10
    color: "transparent"

    Item {
      id: card
      opacity: 0
      z: -100
      x: -4000
      width: 160
      height: 38
      Rectangle { anchors.fill: parent; radius: 6; color: "#cc000000"
                  border.width: 1; border.color: "#9bbfbf" }
      Text { anchors.centerIn: parent; text: "two items"; color: "#dfdfdd"
             font.family: "JetBrainsMono Nerd Font Propo"; font.pixelSize: 15 }
    }

    // once the window is really up, which is when a drag would happen
    Timer {
      interval: 1500
      running: true
      onTriggered: {
        const ok = card.grabToImage((res) => {
          console.log("CHECK callback url=" + res.url);
          res.saveToFile("/tmp/claude-1000/-home-buck/ff77707c-411e-48d3-938e-3dccef51c493/scratchpad/dragcard.png");
        });
        console.log("CHECK grabToImage returned " + ok);
      }
    }
  }
}
