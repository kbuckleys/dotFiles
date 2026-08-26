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

    // ── startup fade + zoom ──────────────────────────────────────────
    // WallContainer handles startup/unlock (whole surface zoom), per-Wall
    // handles wallpaper change (only the NEW wallpaper zooms, old stays
    // static) — so applying a wallpaper never looks like old+new both zoom.
    property real intro: 0
    property bool _introInstant: false
    property bool _initialLoadDone: false
    Behavior on intro {
      enabled: !surface._introInstant
      NumberAnimation { duration: 1100; easing.type: Zenon.ease }
    }
    Timer { id: introTimer; interval: 60; onTriggered: surface.intro = 1 }
    Connections {
      target: Picasso
      function onIntroTickChanged() {
        surface._introInstant = true;
        surface.intro = 0;
        surface._introInstant = false;
        introTimer.restart();
      }
      function onHoldTickChanged() {
        introTimer.stop();
        surface._introInstant = true;
        surface.intro = 0;
        surface._introInstant = false;
      }
    }

    onWantChanged: surface.load()

    function load() {
      if (surface.want === surface.front.source.toString().replace("file://", ""))
        return;
      if (surface.want === "") {
        surface.front.source = "";
        return;
      }
      // wallpaper change — don't touch wallContainer (which would zoom the
      // OLD wallpaper). Just set the new source in back; its own per-Wall
      // zoom will run when it flips to front in ready().
      if (surface._initialLoadDone) {
        // mark the back wall to zoom when it becomes front
        if (surface.back === imgA) imgA._pendingZoom = true;
        else imgB._pendingZoom = true;
      } else {
        // first load — normal whole-surface intro
        surface._introInstant = true;
        surface.intro = 0;
        surface._introInstant = false;
        introTimer.restart();
      }
      surface.back.source = "file://" + surface.want;
    }

    // flip only once the incoming image has actually decoded
    function ready(img) {
      if (img === surface.back && img.status === Image.Ready) {
        surface.aFront = !surface.aFront;
        // per-Wall zoom for wallpaper change
        if (img._pendingZoom) {
          img._pendingZoom = false;
          img._zoomInstant = true;
          img.scale = 1.08;
          img._zoomInstant = false;
          img.scale = 1.0;
        }
        if (!surface._initialLoadDone) {
          surface._initialLoadDone = true;
        }
      }
    }

    component Wall: Image {
      fillMode: Picasso.fillMode
      asynchronous: true
      cache: false
      smooth: true
      anchors.fill: parent
      // per-wallpaper zoom — only the NEW wallpaper scales, old stays static
      // matches wallContainer intro zoom (1100 OutQuint) so unlock and
      // wallpaper-change feel like the same camera move.
      property bool _pendingZoom: false
      property bool _zoomInstant: false
      Behavior on scale {
        enabled: !_zoomInstant
        NumberAnimation { duration: 1100; easing.type: Zenon.ease }
      }
      Behavior on opacity {
        NumberAnimation { duration: 1100; easing.type: Zenon.ease }
      }
    }

    Item {
      id: wallContainer
      anchors.fill: parent
      opacity: surface.intro
      // zoom from 1.08 down to 1.0 driven by the same scalar as opacity,
      // so the two stay locked without a second Behavior chasing the first
      transform: Scale {
        origin.x: wallContainer.width / 2
        origin.y: wallContainer.height / 2
        xScale: 1 + 0.08 * (1 - surface.intro)
        yScale: 1 + 0.08 * (1 - surface.intro)
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
    }

    Component.onCompleted: { surface.load(); introTimer.restart(); }
  }
}
