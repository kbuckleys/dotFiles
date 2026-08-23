// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import "helpers.js" as Helpers
import "."

Item {
  id: root
  implicitWidth: row.implicitWidth
  implicitHeight: 32

  PwObjectTracker {
    objects: [Pipewire.defaultAudioSink]
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Zenon.padModule
    rightPadding: Zenon.padModule

    BarText {
      text: {
        const sink = Pipewire.defaultAudioSink;
        if (!sink || !sink.audio) return "";
        if (sink.audio.muted) return "";
        return String(Math.round(sink.audio.volume * 100));
      }
      color: {
        const sink = Pipewire.defaultAudioSink;
        if (sink && sink.audio && sink.audio.muted) return Zenon.red;
        return Zenon.green;
      }
    }
  }

  property string tooltipText: {
    const sink = Pipewire.defaultAudioSink;
    if (!sink || !sink.audio) return "Volume: --";
    if (sink.audio.muted) return "Volume: Muted";
    return "Volume: " + Math.round(sink.audio.volume * 100) + "%";
  }
  property bool hovered: mouse.containsMouse
  property var mousePos: mouse.containsMouse ? Qt.point(mouse.mouseX, mouse.mouseY) : null

  // one scroll notch = 1%
  function nudgeVolume(step) {
    const sink = Pipewire.defaultAudioSink;
    if (!sink || !sink.audio) return;
    let vol = sink.audio.volume;
    if (step > 0) vol = Math.min(1, vol + step);
    else if (step < 0) vol = Math.max(0, vol + step);
    else return;
    if (vol === sink.audio.volume) return;
    sink.audio.volume = vol;
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: Quickshell.execDetached(["kitty", "-1", "-T", "Wiremix", "wiremix"])
    onPressed: (mouse) => { if (mouse.button === Qt.RightButton) Quickshell.execDetached(["pamixer", "-t"]) }
    onWheel: (wheel) => {
      root.nudgeVolume(wheel.angleDelta.y > 0 ? 0.01 : -0.01);
      wheel.accepted = true;
    }
  }
}
