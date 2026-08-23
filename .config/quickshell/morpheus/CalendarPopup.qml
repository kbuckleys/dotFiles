// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import "."

CursorAnchor {
  id: popup

  // Re-read on every open. Evaluated once at component creation, the date
  // froze at whatever day the shell was started on.
  property var now: new Date()
  onShowChanged: if (popup.show) popup.now = new Date();

  readonly property string monthName: [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"
  ][popup.now.getMonth()]
  readonly property int year: popup.now.getFullYear()
  readonly property int today: popup.now.getDate()
  readonly property string weekdayName: ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][popup.now.getDay()]

  implicitWidth: bg.implicitWidth
  implicitHeight: bg.implicitHeight

  Rectangle {
    id: bg
    implicitWidth: content.implicitWidth + 16
    implicitHeight: content.implicitHeight + 16
    opacity: popup.showFactor
    color: Zenon.panelBg
    border.color: Zenon.surface
    border.width: 1
    radius: 6

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
