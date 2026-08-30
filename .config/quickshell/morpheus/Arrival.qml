// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// ARRIVAL — when the session's first animation is allowed to play, and how
// long it takes. The pill's slide and the wallpaper's zoom are meant to read
// as one movement, so the shape and the schedule live in one place rather
// than being agreed on by two files that each guess.
//
// Split out of Zenon because this is not a design token. Zenon says what
// things look like; this says when the session has arrived.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
  id: root

  // ── the shape ────────────────────────────────────────────────────────
  // One duration, since the pill and the wallpaper are one movement.
  readonly property int duration: 750

  // ── the schedule ─────────────────────────────────────────────────────
  // A DEADLINE, NOT A DELAY. This is the single thing the previous version
  // got wrong and it is worth stating plainly.
  //
  // The old introDelay() returned a flat 1500ms whenever the process was
  // young, and both callers used it as a timer interval — so the wait was
  // added ON TOP of however long arming took. Arming happens on the first
  // presented frame, measured at +944ms on a real login, so the arrival
  // actually began at +2.44s and finished at +3.19s. The constant was meant
  // to say "be on screen by 1.5s"; it was being read as "wait 1.5s more".
  // That gap is the black screen.
  //
  // Read as a deadline, the wait absorbs the arm time instead of stacking on
  // it, so the arrival lands at the same moment whether arming took 600ms or
  // 1000ms. The old code drifted between +2135ms and +2518ms for that reason.
  //
  // THE NUMBER IS MEASURED, and the first attempt at it was too small. From a
  // real login (arrival-trace):
  //
  //     armed=+1018ms  cadence=+1147ms  played=+1515ms  frames=31
  //
  // Played at +1515ms the slide ran 1515->2265ms and was NOT seen: this panel
  // is not lit until around +2s, so only the last third arrived, and under
  // OutQuint the last third is nearly stationary — "already there" again. The
  // stacked version that did work played at +2135ms.
  //
  // So the visible threshold is somewhere above 1515 and at or below 2135, and
  // this sits just past it. Deterministic, unlike the 2135-2518 it replaces.
  readonly property int onScreenBy: 2200

  // Past this, the process has plainly been on screen a while — a config
  // reload or an unlock — and the arrival plays immediately.
  readonly property int coldWindow: 15000
  readonly property int warmDelay: 60

  function age() {
    return Date.now() - Quickshell.launchTime.getTime();
  }

  function isCold() {
    return root.age() < root.coldWindow;
  }

  // What to set a timer's interval to, right now. Deterministic in the age,
  // so the pill and the wallpaper arming at different instants still aim at
  // the same moment rather than drifting apart.
  function delay() {
    const a = root.age();
    if (a >= root.coldWindow) return root.warmDelay;
    return Math.max(root.warmDelay, root.onScreenBy - a);
  }

  // ── the instrument ───────────────────────────────────────────────────
  // onScreenBy is still a measured guess, and the honest way to tighten it
  // is to look at what this machine does rather than to keep picking
  // numbers. Off unless QS_ARRIVAL_TRACE is set, because the frame clock
  // below forces continuous rendering for the whole arming window and that
  // is not something to pay for on every boot.
  //
  // What it cannot see, and what no Wayland client can: a monitor's own sync
  // after a KMS modeset. The cadence below goes steady when the COMPOSITOR
  // starts scanning out, which is earlier than when the glass is lit. This
  // narrows the guess; it cannot remove it.
  // ON by default, and deliberately. This has now been got wrong twice from
  // reasoning about it, and once from measurement; the measurement is what
  // settled it. The cost is a frame clock for the ~2s of the arming window and
  // one short line on disk. QS_ARRIVAL_TRACE=0 turns it off.
  readonly property bool tracing: Quickshell.env("QS_ARRIVAL_TRACE") !== "0"

  property string marks: ""
  property int frames: 0
  property real steadyAt: 0

  function note(what) {
    if (!root.tracing || !root.isCold()) return;
    root.marks += (root.marks === "" ? "" : " ") + what + "=+" + Math.round(root.age()) + "ms";
    traceSave.restart();
  }

  // A frame clock, only while the arrival is still pending. Once the
  // compositor is genuinely scanning out, frameTime settles to the refresh
  // period; before that it is long and ragged. steadyAt is the first moment
  // we saw a run of frames at cadence.
  FrameAnimation {
    id: clock
    running: root.tracing && root.isCold() && root.marks.indexOf("played") < 0
    property int settled: 0
    onTriggered: {
      root.frames++;
      // 20ms covers anything from 50Hz up; a real scanout on either of this
      // machine's outputs is 10ms (100Hz) or 5.5ms (180Hz)
      if (clock.frameTime > 0 && clock.frameTime < 0.020) {
        clock.settled++;
        // Two marks, because the first one proved to be the wrong question.
        // `cadence` (5 frames) is where the compositor STARTS scanning out —
        // it fired at +1147ms while nothing was visible until ~+2s. `steady`
        // demands ~300ms of unbroken cadence, which is a much better proxy for
        // an output that has actually settled. If steady turns out to track
        // the lit panel across a few logins, it can replace this constant.
        if (clock.settled === 5) root.note("cadence");
        if (clock.settled === 30 && root.steadyAt === 0) {
          root.steadyAt = root.age();
          root.note("steady");
        }
      } else {
        clock.settled = 0;
      }
    }
  }

  FileView {
    id: traceFile
    path: Quickshell.statePath("arrival-trace")
    blockLoading: true
    printErrors: false
  }

  // Appended, capped, so a run of logins can be compared instead of each one
  // erasing the last.
  Timer {
    id: traceSave
    interval: 400
    onTriggered: {
      const line = Qt.formatDateTime(new Date(), "MM-dd hh:mm:ss") + "  "
        + root.marks + " frames=" + root.frames;
      const kept = String(traceFile.text() || "").split("\n").filter((l) => l !== "");
      kept.push(line);
      traceFile.setText(kept.slice(-20).join("\n") + "\n");
    }
  }
}
