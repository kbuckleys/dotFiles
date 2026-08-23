// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Io
import "."
import "helpers.js" as Helpers

Item {
  id: root
  implicitWidth: row.implicitWidth
  implicitHeight: 32

  property int count: 0
  property string tooltipText: ""

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule
    spacing: 4

    BarText {
      id: icon
      text: "󰂚"
      color: root.count > 0 ? Zenon.red : Zenon.muted
    }

    Collapsible {
      active: root.count > 0
      openWidth: label.implicitWidth

      BarText {
        id: label
        anchors.centerIn: parent
        text: String(root.count)
        color: Zenon.red
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      if (root.count > 0) {
        Quickshell.execDetached(["/usr/bin/makoctl", "dismiss", "-a"]);
        root.stored = [];
        root.seenIds = {};
        root.count = 0;
        root.tooltipText = "";
      } else Quickshell.execDetached(["notify-send", "No notifications", "You're all caught up"])
    }
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    text: root.tooltipText !== "" ? root.tooltipText : (root.count === 0 ? "No notifications" : root.count + " notification" + (root.count > 1 ? "s" : ""))
    show: mouse.containsMouse
  }

  Timer {
    id: refresh
    interval: 1000
    running: true
    repeat: true
    onTriggered: {
      if (!proc.running) proc.running = true;
    }
  }

  // persistent store so count survives after mako's 4s timeout (history=0)
  property var stored: []
  property var seenIds: ({})

  function syncStored(list) {
    let changed = false;
    for (const n of list) {
      const id = String(n.id);
      if (!root.seenIds[id]) {
        root.seenIds[id] = true;
        root.stored.push(n);
        changed = true;
      }
    }
    if (changed) {
      root.stored = root.stored.slice();
      root.seenIds = Object.assign({}, root.seenIds);
    }
    root.count = root.stored.length;
    if (root.stored.length === 0) {
      root.tooltipText = "";
    } else {
      const lines = root.stored.slice(0, 8).map((n) => {
        const app = n.app_name || "unknown";
        const sum = n.summary || "";
        return app + ": " + sum;
      });
      let tip = lines.join("\n");
      if (root.stored.length > 8) tip += "\n… and " + (root.stored.length - 8) + " more";
      root.tooltipText = tip;
    }
  }

  Process {
    id: proc
    command: ["/usr/bin/makoctl", "list", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: (text) => {
        try {
          const arr = JSON.parse(text || "[]");
          if (Array.isArray(arr)) {
            root.syncStored(arr);
          }
        } catch (e) {
          // keep stored on parse error
        }
      }
    }
  }

  Component.onCompleted: proc.running = true
}
