// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// The daemon half: one background layer surface per monitor. There is no
// separate wallpaper process to talk to — this shell IS the wallpaper daemon,
// so setting one is an assignment, not an IPC call to something else.

import QtQuick
import Quickshell
import Quickshell.Wayland
import "../morpheus"

Variants {
  // one surface per monitor, rebuilt by Quickshell when monitors come and go
  model: Quickshell.screens

  PanelWindow {
    id: surface
    required property var modelData

    screen: surface.modelData
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.namespace: "picasso"
    exclusionMode: ExclusionMode.Ignore
    anchors { left: true; right: true; top: true; bottom: true }
    // the floor under the image: with no wallpaper set this is what you see,
    // and it matches hyprland's own background_color
    color: "black"
    // A fullscreen surface that took input would swallow every click on the
    // desktop. It is scenery; it must never be a target.
    mask: Region {}

    readonly property string want:
      surface.modelData ? Picasso.wallpaperFor(surface.modelData.name) : ""

    // Two images and a crossfade rather than one image whose source changes:
    // swapping a source in place shows a black frame while the new file
    // decodes, which on a 4K wallpaper is very visible.
    property bool aFront: true
    readonly property Image front: surface.aFront ? imgA : imgB
    readonly property Image back: surface.aFront ? imgB : imgA

    onWantChanged: surface.load()

    function load() {
      if (surface.want === surface.front.source.toString().replace("file://", ""))
        return;
      if (surface.want === "") {
        // nothing assigned: fade the current one out to the black floor
        surface.front.source = "";
        return;
      }
      surface.back.source = "file://" + surface.want;
    }

    // flip only once the incoming image has actually decoded
    function ready(img) {
      if (img === surface.back && img.status === Image.Ready)
        surface.aFront = !surface.aFront;
    }

    component Wall: Image {
      fillMode: Picasso.fillMode
      // decode off the render thread; a big file must not stall the shell
      asynchronous: true
      cache: false
      smooth: true
      anchors.fill: parent
      Behavior on opacity {
        NumberAnimation { duration: Zenon.slow * 3; easing.type: Zenon.ease }
      }
    }

    Wall {
      id: imgA
      opacity: surface.aFront && status === Image.Ready ? 1 : 0
      onStatusChanged: surface.ready(imgA)
    }

    Wall {
      id: imgB
      opacity: !surface.aFront && status === Image.Ready ? 1 : 0
      onStatusChanged: surface.ready(imgB)
    }

    Component.onCompleted: surface.load()
  }
}
