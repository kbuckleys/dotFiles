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
import QtQuick.Window
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
    readonly property AnimatedImage front: surface.aFront ? imgA : imgB
    readonly property AnimatedImage back: surface.aFront ? imgB : imgA

    // ── startup fade + zoom ──────────────────────────────────────────
    // WallContainer handles startup/unlock (whole surface zoom), per-Wall
    // handles wallpaper change (only the NEW wallpaper zooms, old stays
    // static) — so applying a wallpaper never looks like old+new both zoom.
    property real intro: 0
    property bool _introInstant: false
    property bool _initialLoadDone: false
    Behavior on intro {
      enabled: !surface._introInstant
      NumberAnimation { duration: Arrival.duration; easing.type: Zenon.ease }
    }
    // interval is set at play time: a cold login waits for the session to be
    // on screen, a wallpaper change or an unlock does not (Arrival.delay())
    Timer { id: introTimer; interval: 60; onTriggered: surface.intro = 1 }

    // ARMED BY THE SURFACE AND THE IMAGE TOGETHER, not by Component.onCompleted.
    //
    // Same trap the pill's intro was in: on a cold login this runs before there
    // is a mapped surface, so the 60ms wait and the 750ms zoom finished against
    // a window that had not been shown — and unlike the pill there is a second
    // gate here, because a fade against an undecoded 4K image is black on black
    // even once the surface IS up. So the arrival waits for both: a window on
    // screen, and a wallpaper actually decoded into the front buffer.
    //
    // Latched. A wallpaper change must NOT come through here — that has its own
    // per-Wall zoom, so that the outgoing wallpaper stays put while only the
    // incoming one moves — and unlock replays through Picasso.introTick.
    property bool _introArmed: false
    // This surface's first presented frame, for the same reason the pill waits
    // on one: the window reports itself visible ~150ms before it has handed the
    // compositor anything.
    property bool framed: false
    Connections {
      target: wallContainer.Window.window
      enabled: !surface.framed
      function onFrameSwapped() { surface.framed = true; }
    }

    readonly property bool introReady: surface.framed
      // no wallpaper set is a legitimate resting state, not something to wait on
      && (surface.want === "" || surface.front.status === Image.Ready)

    onIntroReadyChanged: if (surface.introReady) surface.playIntro()

    // The same guarded safety net the pill has. Counted from the window being
    // up rather than from load, so it can never beat a slow first frame — but
    // if a frame genuinely never arrives, the wallpaper must not be left at
    // opacity 0, which would show as no wallpaper at all.
    Timer {
      interval: 2500
      running: !surface._introArmed && surface.backingWindowVisible
      onTriggered: surface.playIntro()
    }

    function playIntro() {
      if (surface._introArmed) return;
      surface._introArmed = true;
      surface._introInstant = true;
      surface.intro = 0;
      surface._introInstant = false;
      introTimer.interval = Arrival.delay();
      introTimer.restart();
    }

    Connections {
      target: Picasso
      function onIntroTickChanged() {
        surface._introArmed = true;
        surface._introInstant = true;
        surface.intro = 0;
        surface._introInstant = false;
        introTimer.interval = 60;
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
      const frontSrc = surface.front.source.toString().replace("file://", "");
      const backSrc = surface.back.source.toString().replace("file://", "");
      if (surface.want === frontSrc)
        return;
      if (surface.want === "") {
        surface.front.source = "";
        return;
      }
      // recently applied wallpaper is still in the back buffer (front is the
      // other one, back is the previous pick). Setting back.source to the same
      // url wouldn't reload and ready() would never fire, so the flip stalls
      // and the old wallpaper stays — looks like picasso refused the pick.
      if (surface.want === backSrc) {
        if (surface.back.status === Image.Ready) {
          // back already decoded, just flip to it (with zoom)
          if (surface._initialLoadDone) {
            if (surface.back === imgA) imgA._pendingZoom = true;
            else imgB._pendingZoom = true;
          }
          surface.ready(surface.back);
        } else if (surface.back.status === Image.Null || surface.back.status === Image.Error) {
          // back was cleared or failed — force a reload
          surface.back.source = "";
          surface.back.source = "file://" + surface.want;
          if (surface._initialLoadDone) {
            if (surface.back === imgA) imgA._pendingZoom = true;
            else imgB._pendingZoom = true;
          }
        }
        // if back is Loading, its onStatusChanged will flip when ready
        return;
      }
      // wallpaper change — don't touch wallContainer (which would zoom the
      // OLD wallpaper). Just set the new source in back; its own per-Wall
      // zoom will run when it flips to front in ready().
      if (surface._initialLoadDone) {
        // mark the back wall to zoom when it becomes front
        if (surface.back === imgA) imgA._pendingZoom = true;
        else imgB._pendingZoom = true;
      }
      // no first-load branch: the whole-surface intro is armed by introReady,
      // once this image has decoded and there is a window to show it in
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

    component Wall: AnimatedImage {
      fillMode: Picasso.fillMode
      asynchronous: true
      cache: false
      smooth: true
      anchors.fill: parent
      playing: true
      paused: false
      // per-wallpaper zoom — only the NEW wallpaper scales, old stays static
      // matches wallContainer intro zoom (1100 OutQuint) so unlock and
      // wallpaper-change feel like the same camera move.
      property bool _pendingZoom: false
      property bool _zoomInstant: false
      Behavior on scale {
        enabled: !_zoomInstant
        NumberAnimation { duration: Arrival.duration; easing.type: Zenon.ease }
      }
      Behavior on opacity {
        NumberAnimation { duration: Arrival.duration; easing.type: Zenon.ease }
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

    Component.onCompleted: surface.load()
  }
}
