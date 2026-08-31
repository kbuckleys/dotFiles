// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import "."

Item {
  id: root
  implicitWidth: row.implicitWidth
  implicitHeight: Zenon.slot

  // Display only. The interface, the throughput, the smoothing and the learned
  // ceilings all live in Sysmon now — zeus graphs the same numbers this meter
  // shows, and neither of them samples /proc/net/dev a second time.
  readonly property string iface: Sysmon.netIface
  readonly property string ipaddr: Sysmon.netIp
  readonly property bool connected: Sysmon.netConnected
  readonly property string downText: Sysmon.netDownText
  readonly property string upText: Sysmon.netUpText
  readonly property real downLevel: Sysmon.netDownLevel
  readonly property real upLevel: Sysmon.netUpLevel
  readonly property var downHistory: Sysmon.netDownHistory
  readonly property var upHistory: Sysmon.netUpHistory

  readonly property int segCount: 6

  // Clicking the meter reports the click and nothing else. It used to launch
  // `sudo bandwhich` in a terminal — a TUI, behind a password prompt, showing
  // what this bar is already measuring. Zeus's net view is that reading, and
  // it opens with no prompt at all.
  signal activated()

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    // segmented stereo meter: blue download · magenta upload
    Item {
      // read off the meters themselves rather than restated as a number, so
      // changing a meter's thickness cannot leave this behind
      width: down.width * 2 + 5
      height: down.implicitHeight
      anchors.verticalCenter: parent.verticalCenter
      visible: root.connected

      Meter {
        id: down
        x: 0
        segCount: root.segCount
        value: root.downLevel / 100
        accent: Sysmon.netDownInk
      }

      Meter {
        x: parent.width - width
        segCount: root.segCount
        value: root.upLevel / 100
        accent: Sysmon.netUpInk
      }
    }

    BarText {
      visible: !root.connected
      src: "󰱟 "
      styled: true
      textColor: Zenon.red
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    // Where you are, then how fast it is moving: the address is the stable
    // fact you came to read, the throughput is the number that never sits
    // still, and a heading that changes four times a second is a poor one.
    text: {
      if (!root.connected) return "NO NETWORK SIGNAL";
      const speeds = "󱞡 " + root.downText + " ~ " + root.upText + " 󱞿";
      return root.iface !== ""
        ? root.iface + ": " + root.ipaddr + "\n" + speeds
        : speeds;
    }
    // two short standalone lines, not a list — centred reads better
    align: Text.AlignHCenter
    show: mouse.containsMouse
    // one trace per channel, in the same two inks the meter beside it uses
    series: root.connected
      ? [{ values: root.downHistory, line: Sysmon.netDownInk },
         { values: root.upHistory,   line: Sysmon.netUpInk }]
      : []
  }

}
