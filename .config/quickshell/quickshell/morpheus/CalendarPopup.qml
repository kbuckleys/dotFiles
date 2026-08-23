// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import "helpers.js" as Helpers
import "."

PanelWindow {
  id: popup

  required property Item anchorItem
  property bool show: false
  property int gap: 5

  // cursor position in anchorItem coordinates; calendar spawns there
  property var cursorPos: null

  readonly property var now: new Date()
  readonly property string monthName: [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"
  ][popup.now.getMonth()]
  readonly property int year: popup.now.getFullYear()
  readonly property int today: popup.now.getDate()
  readonly property string weekdayName: ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][popup.now.getDay()]

  visible: popup.show && anchorItem.QsWindow.window !== null
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  aboveWindows: true
  screen: anchorItem.QsWindow.window?.screen ?? null

  mask: Region {}

  implicitWidth: bg.implicitWidth
  implicitHeight: bg.implicitHeight

  anchors { top: true; left: true }

  readonly property var barWin: anchorItem.QsWindow.window

  readonly property real targetX: {
    if (!barWin || !anchorItem) return 0;
    const px = cursorPos ? cursorPos.x : anchorItem.width / 2;
    const p = barWin.contentItem.mapFromItem(anchorItem, px, 0);
    return p.x - popup.implicitWidth / 2;
  }

  margins.left: !barWin || !popup.screen ? 0 :
    Math.max(8, Math.min(Math.round(popup.targetX), Math.round(popup.screen.width - popup.implicitWidth - 8))) | 0
  margins.top: !barWin || !popup.screen ? 0 :
    (popup.screen.height - barWin.height - popup.gap - popup.implicitHeight) | 0

  Rectangle {
    id: bg
    implicitWidth: content.implicitWidth + 16
    implicitHeight: content.implicitHeight + 16
    color: Zenon.panelBg
    border.color: Zenon.surface
    border.width: 1
    radius: 4

    Column {
      id: content
      anchors.centerIn: parent
      spacing: 10

      Column {
        width: parent.width
        spacing: 2

        Text {
          text: popup.monthName
          color: Zenon.white
          font.family: "JetBrainsMono Nerd Font Propo"
          font.weight: Font.Bold
          font.pixelSize: 14
          font.capitalization: Font.Capitalize
          horizontalAlignment: Text.AlignHCenter
          anchors.horizontalCenter: parent.horizontalCenter
        }

        Text {
          text: popup.year + "  " + popup.weekdayName
          color: Zenon.muted
          font.family: "JetBrainsMono Nerd Font Propo"
          font.weight: Font.Bold
          font.pixelSize: 14
          horizontalAlignment: Text.AlignHCenter
          anchors.horizontalCenter: parent.horizontalCenter
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Zenon.surface
        radius: 1
      }

      Row {
        Repeater {
          model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
          delegate: Text {
            required property string modelData
            required property int index
            width: 34
            height: 18
            text: modelData
            color: index >= 5 ? Zenon.muted : Zenon.dim
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: Font.Bold
            font.pixelSize: 14
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }
        }
      }

      Grid {
        columns: 7
        columnSpacing: 2
        rowSpacing: 0

        Repeater {
          model: popup.monthCells()
          delegate: Rectangle {
            required property int modelData
            required property int index
            width: 34
            height: 28
            radius: 3
            color: "transparent"

            Text {
              anchors.centerIn: parent
              text: modelData === 0 ? "" : String(modelData)
              color: modelData === popup.today ? Zenon.cyan : (index % 7 >= 5 ? Zenon.muted : Zenon.white)
              opacity: modelData === 0 ? 0 : 1
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: modelData === popup.today ? Font.Black : Font.Bold
              font.pixelSize: 14
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }
          }
        }
      }
    }
  }

  function monthCells() {
    const y = popup.year;
    const m = popup.now.getMonth();
    const first = new Date(y, m, 1);
    const offset = (first.getDay() + 6) % 7;
    const days = new Date(y, m + 1, 0).getDate();
    const cells = [];
    for (let i = 0; i < 42; ++i) {
      cells.push(i < offset || i >= offset + days ? 0 : i - offset + 1);
    }
    return cells;
  }
}
