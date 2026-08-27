// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Io
import "helpers.js" as Helpers
import "."

Collapsible {
  id: root
  active: root.hasUpdates
  openWidth: row.implicitWidth

  property bool hasUpdates: false
  property string countText: ""
  property string tooltipText: ""
  property int officialCount: 0
  property int aurCount: 0
  property bool hovered: false

  property string notified: ""

  FileView {
    id: notifiedFile
    path: Quickshell.statePath("updates-notified")
    blockLoading: true
    printErrors: false
  }

  function updateKey(o) {
    return (o.text ?? "") + "\u0000" + (o.tooltip ?? "");
  }

  function announce(o) {
    const key = root.updateKey(o);
    if (!root.hasUpdates) {
      if (root.notified !== "") {
        root.notified = "";
        notifiedFile.setText("");
      }
      return;
    }
    if (key === root.notified) return;
    root.notified = key;
    notifiedFile.setText(key);
    Quickshell.execDetached([
      "notify-send", "-a", "waybar-updates", "-u", "normal",
      root.countText + " updates available",
      Helpers.updateList(o.tooltip ?? "")
    ]);
  }

  function parseCounts(tt) {
    const m = tt.match(/\s*(\d+).*?\s*(\d+)/);
    if (m) {
      root.officialCount = parseInt(m[1]) || 0;
      root.aurCount = parseInt(m[2]) || 0;
    } else {
      root.officialCount = 0;
      root.aurCount = 0;
    }
  }

  function buildTooltip() {
    const lines = [];
    const tt = root.tooltipText;
    if (!tt) return "";
    const parts = tt.split("\n\n");
    const pkgLines = parts[1] ? parts[1].split("\n") : [];

    let officialPkgs = [];
    let aurPkgs = [];
    for (let i = 0; i < pkgLines.length; ++i) {
      const line = pkgLines[i].trim();
      if (!line) continue;
      if (i < root.officialCount) officialPkgs.push(line);
      else aurPkgs.push(line);
    }

    function fmtPkgs(pkgs) {
      return pkgs.map(p => {
        const arrow = p.indexOf("->");
        if (arrow > 0) {
          const before = p.substring(0, arrow).trim();
          const after = p.substring(arrow + 2).trim();
          const nameEnd = before.lastIndexOf(" ");
          const name = before.substring(0, nameEnd);
          const oldVer = before.substring(nameEnd + 1);
          return name + " <font color='#6b7089'>" + oldVer + "</font> <font color='#fab387'>\u2192</font> " + after;
        }
        return p;
      });
    }

    if (root.officialCount > 0) {
      lines.push("<font color='#7aa2f7'></font>  " + root.officialCount + " Updates");
      for (const p of fmtPkgs(officialPkgs)) {
        lines.push("    " + p);
      }
    }
    if (root.aurCount > 0) {
      if (root.officialCount > 0) lines.push("");
      lines.push("<font color='#c099ff'></font>  " + root.aurCount + " AUR Updates");
      for (const p of fmtPkgs(aurPkgs)) {
        lines.push("    " + p);
      }
    }
    return lines.join("\n");
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    Item {
      id: iconBox
      width: Math.max(iconGlyph.implicitWidth, countBox.implicitWidth)
      height: Zenon.slot
      anchors.verticalCenter: parent.verticalCenter

      BarText {
        id: iconGlyph
        anchors.centerIn: parent
        text: ""
        color: Zenon.yellow
        font.pixelSize: 18
        opacity: !root.hovered ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
      }

      Item {
        id: countBox
        anchors.centerIn: parent
        implicitWidth: Math.max(countGhost.implicitWidth, countLabel.implicitWidth)
        implicitHeight: Zenon.slot

        BarText {
          id: countGhost
          anchors.centerIn: parent
          text: "8".repeat(Math.max(1, String(root.countText).length))
          numeric: true
          color: Zenon.trough(Zenon.yellow)
        }

        BarText {
          id: countLabel
          anchors.centerIn: parent
          text: root.countText
          numeric: true
          color: Zenon.yellow
          opacity: root.hovered && root.hasUpdates ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
        }
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: root.hovered = true
    onExited: root.hovered = false
    onClicked: Quickshell.execDetached([
      "kitty", "-1", "-T", "ZENU", Helpers.home() + "/.config/scripts/ZENU.lua", "update"
    ])
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    text: root.buildTooltip()
    styled: true
    show: mouse.containsMouse && root.hasUpdates
  }

  Timer {
    id: updateTimer
    interval: 3600000
    onTriggered: {
      if (!proc.running) proc.running = true;
    }
  }

  Process {
    id: proc
    command: ["waybar-updates", "-d", "-c", "3600"]
    stdout: SplitParser {
      onRead: (line) => {
        try {
          const o = JSON.parse(line);
          root.hasUpdates = o.alt === "pending-updates";
          root.countText = o.text ?? "";
          root.tooltipText = o.tooltip ?? "";
          root.parseCounts(o.tooltip ?? "");
          root.announce(o);
        } catch (e) {}
      }
    }
    onRunningChanged: (running) => {
      if (running) updateTimer.stop();
      else updateTimer.start();
    }
  }

  Component.onCompleted: {
    root.notified = notifiedFile.text();
    proc.running = true;
  }
}
