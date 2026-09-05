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
import Quickshell.Io
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
      id: wall
      fillMode: Picasso.fillMode
      asynchronous: true
      cache: false
      smooth: true
      anchors.fill: parent
      playing: true
      paused: false

      // ── decode at screen size, not at file size ──────────────────────
      //
      // Without a sourceSize every wallpaper is decoded at its FULL
      // resolution and kept that way for as long as it is assigned. The
      // originals in this library run to 7276x4895, which is 135MB of RGBA
      // for a monitor that can show 8MB of it — and there are two Walls per
      // surface and one surface per monitor, so four full-size decodes sit
      // resident at once. That, not the module count, is where this shell's
      // memory went: a measured 92MB for one 5785x3857 wallpaper against
      // 36MB for the same file decoded to fit.
      //
      // ONE AXIS AT A TIME, WHICH IS THE WHOLE SUBTLETY. AnimatedImage is not
      // Image here: give Image both axes and it scales to COVER the box with
      // the aspect ratio intact, but give AnimatedImage both and it scales to
      // exactly that box and stretches the picture — visibly, a 3:2 wallpaper
      // squashed onto 16:9. Constrain a single axis and it preserves the
      // aspect ratio the way Image does. So pin whichever axis makes the
      // decode COVER the screen, and leave the other at 0, which is how Qt
      // spells "unconstrained":
      //
      //   image no wider than the screen -> pin the width, height overflows
      //   image wider than the screen    -> pin the height, width overflows
      //
      // The image measures its own aspect ratio for free: with one axis
      // pinned, implicitWidth/implicitHeight IS the source's ratio, so no
      // probe decode is needed to choose between the two.
      //
      // LATCHED IN A HANDLER RATHER THAN BOUND, because what it is measured
      // from is what it controls — sourceSize decides the decode, the decode
      // sets the implicit size, and the implicit size is what says whether
      // the image is wide. As a binding that is a cycle, and Qt says so
      // ("Binding loop detected for property _wide") before breaking it
      // wherever it happens to notice. Assigned from the status handler there
      // is no cycle, and it settles in one step: the aspect ratio belongs to
      // the file, so measuring a re-decoded image returns what it returned
      // before and the second pass changes nothing. Until the first decode
      // lands implicitHeight is 0 and the width-pinned branch runs, which is
      // the right guess for everything that is not a panorama — so the
      // re-decode is the rare case rather than the normal one.
      property bool _wide: false
      Connections {
        // Connections, not an `onStatusChanged` on the component root: the
        // two Walls below declare their own handler for that signal where
        // they are created, and a handler here would be replaced by theirs
        // rather than run alongside it.
        target: wall
        function onStatusChanged() {
          if (wall.status !== Image.Ready) return;
          if (wall.implicitHeight <= 0 || wall.height <= 0) return;
          wall._wide = (wall.implicitWidth / wall.implicitHeight)
            > (wall.width / wall.height);
        }
        // a new wallpaper is measured from scratch
        function onSourceChanged() { wall._measure(); }
      }


      // ── never decode BIGGER than the file ────────────────────────────
      //
      // sourceSize is not a cap, it is an instruction: ask for more pixels
      // than the file holds and Qt scales the image UP while decoding it,
      // which costs real memory for no picture at all. Measured on a
      // 1858x1394 wallpaper against a 2560x1440 screen: 15MB decoded at its
      // own size, 43MB decoded at the size that would cover the screen. A
      // wallpaper smaller than the monitor is not unusual — it is what the
      // default in picasso.json is — so covering it blindly turns the saving
      // above into a loss.
      //
      // Qt cannot answer "how big is this file" without decoding it, and the
      // decode is the thing being sized, so the question goes to the same
      // tool that already makes every thumbnail in this shell. It reads the
      // header only, and `[0]` takes the first frame so an animation answers
      // once rather than once per frame.
      //
      // Deliberately not gating the load on the answer. The first decode
      // runs at the cover size, which is already bounded and correct to look
      // at; the probe only ever makes it smaller, and only for images that
      // were going to be upscaled. A large wallpaper — the case this whole
      // block exists for — is never re-decoded, because its natural size is
      // larger than the cover size and the clamp changes nothing. And if
      // magick is missing the sizes stay 0, the clamp is skipped, and the
      // behaviour is simply the uncapped cover.
      property int _natW: 0
      property int _natH: 0
      Process {
        id: sizeProbe
        stdout: StdioCollector {
          id: sizeOut
          waitForEnd: true
          onStreamFinished: {
            const m = String(sizeOut.text).trim().match(/^(\d+)\s+(\d+)/);
            if (!m) return;
            wall._natW = parseInt(m[1], 10);
            wall._natH = parseInt(m[2], 10);
          }
        }
      }

      // Measured from Component.onCompleted as well as on every change: a
      // source assigned while the object is still being built has already
      // been set by the time Connections is listening, so the first wallpaper
      // of the session would otherwise be the one that never gets measured.
      // It resets the aspect latch too — both questions are asked again of
      // every new file.
      function _measure() {
        wall._wide = false;
        wall._natW = 0;
        wall._natH = 0;
        const s = String(wall.source);
        if (s.indexOf("file://") !== 0) return;
        if (sizeProbe.running) sizeProbe.running = false;
        sizeProbe.command = ["magick", "identify", "-format", "%w %h",
          decodeURIComponent(s.slice(7)) + "[0]"];
        sizeProbe.running = true;
      }
      Component.onCompleted: wall._measure()

      // Headroom for the zoom: the surface scales to 1.08 on arrival and each
      // Wall replays the same 1.08 on a change, so the image is briefly drawn
      // larger than the screen, and a decode pinned to exactly the screen
      // would soften for the length of that animation.
      readonly property real _zoom: 1.08
      readonly property real _dpr: wall.Screen.devicePixelRatio
      readonly property int _coverW: Math.ceil(wall.width * wall._zoom * wall._dpr)
      readonly property int _coverH: Math.ceil(wall.height * wall._zoom * wall._dpr)
      sourceSize.width: wall._wide ? 0
        : (wall._natW > 0 ? Math.min(wall._coverW, wall._natW) : wall._coverW)
      sourceSize.height: wall._wide
        ? (wall._natH > 0 ? Math.min(wall._coverH, wall._natH) : wall._coverH) : 0
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
