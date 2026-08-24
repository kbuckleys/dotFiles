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
  // collapses to zero width whenever there is nothing pending
  active: root.hasUpdates
  openWidth: row.implicitWidth

  property bool hasUpdates: false
  property string countText: ""
  property string tooltipText: ""

  // ── notification state ────────────────────────────────────────────────
  // waybar-updates is run WITHOUT -n and is treated as a pure data source.
  // Its "have I already announced these" memory is a set of checksums held
  // in the process, and they start empty — so its very first loop iteration
  // always looks like every pending update is brand new and fires a toast.
  // Quickshell restarts that process on every config reload and every cold
  // start, so the toast fired constantly for updates that had been sitting
  // there for days. Announcing from here instead puts the marker on disk,
  // where it survives a reload.
  property string notified: ""

  FileView {
    id: notifiedFile
    path: Quickshell.statePath("updates-notified")
    // read before the first line of output can arrive; a missing file on a
    // genuine cold start is the normal case, not an error worth logging
    blockLoading: true
    printErrors: false
  }

  // count and package list together: the list is capped at ten packages, so
  // the count is what catches an eleventh arriving
  function updateKey(o) {
    return (o.text ?? "") + "\u0000" + (o.tooltip ?? "");
  }

  function announce(o) {
    const key = root.updateKey(o);
    if (!root.hasUpdates) {
      // nothing pending: forget what we announced, so the next update that
      // does arrive is announced even if it is the same set as last time
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
      "-i", "software-update-available-symbolic",
      root.countText + " updates available",
      Helpers.updateList(o.tooltip ?? "")
    ]);
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    // Glyph and count are separate now: the count wears the clock's digits,
    // and DSEG has no nerd glyph to draw the package icon with.
    BarText {
      text: " "
      color: Zenon.yellow
    }

    BarText {
      id: label
      text: root.countText
      numeric: true
      color: Zenon.yellow
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: Quickshell.execDetached([
      "kitty", "-1", "-T", "ZENU", Helpers.home() + "/.config/scripts/ZENU.lua", "update"
    ])
  }

  Tooltip {
    anchorItem: root
    cursorArea: mouse
    text: root.tooltipText
    show: mouse.containsMouse && root.tooltipText !== ""
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
    // no -n: see the notification state block above
    command: ["waybar-updates", "-d", "-c", "3600"]
    stdout: SplitParser {
      onRead: (line) => {
        try {
          const o = JSON.parse(line);
          root.hasUpdates = o.alt === "pending-updates";
          root.countText = o.text ?? "";
          root.tooltipText = o.tooltip ?? "";
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
    // must land before the process can emit its first line
    root.notified = notifiedFile.text();
    proc.running = true;
  }
}
