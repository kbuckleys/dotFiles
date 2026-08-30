// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// SLOTH — the idle daemon, in place of hypridle. Every listener below came
// from ~/.config/hypr/hypridle.conf, quoted beside what it became.
//
// The one structural change from that file: its actions were shell strings,
// and here they are QML. Locking used to mean spawning `qs ipc call Cerberus
// lock` — a subprocess, to talk to the process that spawned it. cerberus is
// a sibling object in this same shell now, so sloth just calls it.

import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import "../morpheus"

Scope {
  id: root

  // the cerberus instance, handed in by shell.qml
  property var lockscreen: null

  // ── being at the machine without touching it ─────────────────────────
  // ext-idle-notify counts INPUT, and watching something is the one thing you
  // use a computer for that involves none of it. Three signals are watched,
  // because no single one of them sees everything. Each was measured on this
  // machine rather than assumed:
  //
  //   respectInhibitors (below)  mpv publishes NO mpris at all here — there is
  //                              no mpv-mpris script installed — but it does
  //                              take a wayland idle inhibitor, and hyprland
  //                              honours it. Verified: a monitor respecting
  //                              inhibitors stayed awake through mpv playback
  //                              while one ignoring them went idle.
  //   mpris Playing              browsers and players that publish a media
  //                              session, which is most of them once there is
  //                              audio.
  //   audio actually flowing     the catch-all. Anything making sound has a
  //                              pipewire link to an output, and that link is
  //                              Active while it plays and Paused the moment
  //                              you pause it. Verified by pausing mpv over its
  //                              IPC socket and watching the state go 4 -> 3
  //                              -> 4. This is what covers a player that has
  //                              neither an inhibitor nor a media session.
  //
  // Deliberately does not try to tell video from music: nothing in mpris
  // metadata reliably says which is which, and being locked out mid-album is
  // the same annoyance. Set this false to let the timers run for audio-only.
  readonly property bool inhibitOnPlayback: true

  // Any MPRIS player currently reporting Playing — read live rather than via
  // NowPlaying's 1s timer so the idle monitors react on the next frame after
  // play starts, not a second later. Both isPlaying and playbackState, for
  // players that only set one.
  readonly property bool hasMprisPlaying: {
    try {
      const pls = Mpris.players.values;
      for (let i = 0; i < pls.length; ++i) {
        const p = pls[i];
        if (!p) continue;
        if (p.isPlaying) return true;
        try { if (p.playbackState === MprisPlaybackState.Playing) return true; } catch (e2) {}
      }
    } catch (e) {}
    return false;
  }

  // Pipewire hands out a link group per stream reaching an output. Active
  // means samples are moving; pausing drops it to Paused without tearing the
  // group down, which is exactly the distinction asked for — playing holds the
  // lock off, paused lets it through.
  //
  // `source.isStream` keeps this to things PLAYING audio: a capture link runs
  // the other way, with the microphone as the source, and having a meeting
  // recorder open is not the same as watching something.
  readonly property bool hasAudioPlaying: {
    try {
      const gs = Pipewire.linkGroups.values;
      for (let i = 0; i < gs.length; ++i) {
        const g = gs[i];
        if (!g || g.state !== PwLinkState.Active) continue;
        if (g.source && g.source.isStream) return true;
      }
    } catch (e) {}
    return false;
  }

  // Quickshell only keeps a pipewire object's properties live while something
  // is holding it bound, and `state` is exactly such a property — without this
  // the link groups would be listed but never seen to change.
  PwObjectTracker { objects: Pipewire.linkGroups.values }

  // The one case NOTHING can see: a muted video in a browser. Firefox withholds
  // every signal for it on purpose — no media session, no idle inhibitor
  // (muted media deliberately takes no wakelock), and with software decoding
  // there is no GPU decoder activity either. All three measured on this
  // machine, playing a silent clip in a Firefox window. So there is a switch.
  property bool forceAwake: false

  readonly property bool watching: root.forceAwake
    || (root.inhibitOnPlayback
        && (NowPlaying.playing || root.hasMprisPlaying || root.hasAudioPlaying))

  // ── hypridle.conf: general ───────────────────────────────────────────

  //   lock_cmd — what a lock request resolves to. logind raises this when
  //   anything calls `loginctl lock-session`; hypridle turned that into a
  //   command, sloth turns it into a method call.
  function lock() {
    if (root.lockscreen) root.lockscreen.lock();
  }

  //   before_sleep_cmd — lock, and hold suspend off until the lock is up.
  //   See the inhibitor below: without it this is a race the screen loses.
  function beforeSleep() {
    root.lock();
    sleepRelease.restart();
  }

  //   after_sleep_cmd — bring the outputs back.
  function afterSleep() {
    root.dpms(true);
    inhibitor.running = true;   // re-arm for the next suspend
  }

  // ── hypridle.conf: listeners ─────────────────────────────────────────
  // Ported one-for-one. `on-resume` of null means the listener had none.
  readonly property var listeners: [
    //   listener { timeout = 300; on-timeout = <lock> }
    {
      timeout: 300,
      onTimeout: () => root.lock(),
      onResume: null
    },
    //   listener { timeout = 300
    //              on-timeout = solaar config "G515 TKL" brightness_control 0
    //              on-resume  = solaar config "G515 TKL" brightness_control 100 }
    {
      timeout: 300,
      onTimeout: () => root.run(["solaar", "config", "G515 TKL", "brightness_control", "0"]),
      onResume: () => root.run(["solaar", "config", "G515 TKL", "brightness_control", "100"])
    },
    //   listener { timeout = 600
    //              on-timeout = dpms disable / on-resume = dpms enable }
    {
      timeout: 600,
      onTimeout: () => root.dpms(false),
      onResume: () => root.dpms(true)
    }
  ]

  // argv, not a shell string: nothing here needs a shell, and "G515 TKL" has
  // a space in it that quoting kept getting wrong on the way through one.
  function run(argv) {
    Quickshell.execDetached(argv);
  }

  // This hyprland evaluates lua in `hyprctl dispatch` — `dispatch dpms on`
  // is a syntax error here, and the lua form is the one that answers "ok".
  // hypridle.conf had it both ways; only this one ever worked.
  function dpms(on) {
    root.run(["hyprctl", "dispatch",
      "hl.dsp.dpms({ action = \"" + (on ? "enable" : "disable") + "\" })"]);
  }

  // One IdleMonitor per ported listener. ext-idle-notify does the counting,
  // so there are no timers here and no polling — the compositor says when.
  Instantiator {
    id: idle
    model: root.listeners

    delegate: IdleMonitor {
      required property var modelData
      // Disabling drops isIdle, which fires onResume — so a screen that had
      // already blanked comes back the moment playback starts, rather than
      // waiting for a keypress.
      enabled: !root.watching
      timeout: modelData.timeout
      // an idle inhibitor (a video player, say) should hold these off, which
      // is what hypridle's own respect for them did
      respectInhibitors: true
      onIsIdleChanged: {
        if (isIdle) modelData.onTimeout();
        else if (modelData.onResume) modelData.onResume();
      }
    }
  }

  // ── logind ───────────────────────────────────────────────────────────
  // hypridle listened to logind for two things: the session Lock signal and
  // PrepareForSleep. gdbus is the smallest way to see both; the alternative
  // was polling, which is exactly what an idle daemon should never do.

  Process {
    id: logind
    running: true
    command: ["gdbus", "monitor", "--system", "--dest", "org.freedesktop.login1"]
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: (line) => root.onLogind(line)
    }
    // Nothing here ever stops it on purpose, so an exit means it fell over.
    // Losing this silently would mean losing lock-session and suspend
    // handling for the rest of the session, with no sign anything was wrong.
    onExited: logindRespawn.restart()
  }

  Timer {
    id: logindRespawn
    interval: 2000
    onTriggered: logind.running = true
  }

  function onLogind(line) {
    if (line.indexOf("PrepareForSleep") >= 0) {
      // "(true,)" going down, "(false,)" coming back
      if (line.indexOf("true") >= 0) root.beforeSleep();
      else root.afterSleep();
      return;
    }
    // `loginctl lock-session`, and whatever else asks the session to lock
    if (line.indexOf("Session.Lock") >= 0) root.lock();
  }

  // A *delay* inhibitor, not a block one: logind holds the suspend while we
  // get the lock up, and gives up on its own after InhibitDelayMaxSec even if
  // sloth dies mid-flight. Sleeping through `sleep infinity` rather than
  // doing work — the process existing IS the lock.
  Process {
    id: inhibitor
    running: true
    command: ["systemd-inhibit", "--what=sleep", "--mode=delay", "--who=sloth",
              "--why=lock session before sleep", "sleep", "infinity"]
  }

  Timer {
    id: sleepRelease
    // Poll until cerberus reports the lock is actually up, then let go.
    // Releasing on a fixed delay instead would either cut the lock off or
    // add dead time to every suspend.
    interval: 60
    repeat: true
    running: false
    property int elapsed: 0
    onRunningChanged: if (running) elapsed = 0
    onTriggered: {
      elapsed += interval;
      const up = root.lockscreen && root.lockscreen.locked;
      // never hold suspend longer than logind would wait anyway
      if (up || elapsed >= 2000) {
        inhibitor.running = false;
        sleepRelease.stop();
      }
    }
  }

  IpcHandler {
    target: "Sloth"

    function status(): string {
      let s = "listeners=" + root.listeners.length
        + " watching=" + root.watching
        + " mpris=" + root.hasMprisPlaying
        + " audio=" + root.hasAudioPlaying
        + " np=" + NowPlaying.playing
        + " forceAwake=" + root.forceAwake
        + " inhibitor=" + inhibitor.running
        + " logind=" + logind.running;
      for (let i = 0; i < idle.count; ++i) {
        const m = idle.objectAt(i);
        if (m) s += " [" + m.timeout + "s idle=" + m.isIdle + "]";
      }
      return s;
    }
    // release the delay lock by hand, for when a suspend needs to just go
    function release(): string { inhibitor.running = false; return "released"; }

    // The escape hatch for the muted-video case above, and for anything else
    // that keeps its playback to itself. Worth a keybind.
    function awake(): string {
      root.forceAwake = !root.forceAwake;
      return root.forceAwake ? "staying awake" : "idle timers armed";
    }
  }
}
