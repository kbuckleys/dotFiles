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
import "../morpheus"

Scope {
  id: root

  // the cerberus instance, handed in by shell.qml
  property var lockscreen: null

  // ── being at the machine without touching it ─────────────────────────
  // ext-idle-notify counts INPUT, and watching something is the one thing you
  // use a computer for that involves none of it. respectInhibitors below
  // already covers players that take a wayland idle inhibitor, but plenty do
  // not — a browser tab is the usual offender — so an actively playing MPRIS
  // player counts as presence too, and NowPlaying already tracks exactly that
  // for the bar.
  //
  // Browsers and file players often play video without ever marking it
  // fullscreen or taking an idle inhibitor. A fullscreen window is a
  // strong hint that video is front-and-centre, so that too holds the
  // timers off. Together the two cover the "watching a file / browser"
  // case that MPRIS alone missed.
  //
  // This deliberately does not try to tell video from music: nothing in MPRIS
  // metadata reliably says which is which, and being locked out mid-album is
  // the same annoyance. Set this false to let the timers run for audio-only.
  readonly property bool inhibitOnPlayback: true

  // Any MPRIS player currently reporting Playing — polled live rather than
  // via NowPlaying's 1s timer so the idle monitors react on the next frame
  // after play starts, not a second later.
  readonly property bool hasMprisPlaying: {
    try {
      const pls = Mpris.players.values;
      for (let i = 0; i < pls.length; ++i) {
        const p = pls[i];
        if (p && p.isPlaying) return true;
      }
    } catch (e) {}
    return false;
  }

  // A fullscreen toplevel is treated as "watching" even without MPRIS.
  // mpv / browsers often go fullscreen for video without ever
  // appearing as a Playing MPRIS player, which is why sloth kept
  // locking over the top of a film. Hyprland exposes this in two
  // places: the Wayland handle's `fullscreen` and the workspace's
  // `hasFullscreen`. Both are checked because the IPC object itself
  // (`HyprlandToplevel`) carries no fullscreen flag.
  readonly property bool hasFullscreen: {
    try {
      if (Hyprland && Hyprland.toplevels) {
        const tls = Hyprland.toplevels.values;
        for (let i = 0; i < tls.length; ++i) {
          const t = tls[i];
          if (!t) continue;
          if (t.wayland && t.wayland.fullscreen) return true;
        }
      }
    } catch (e) {}
    try {
      if (Hyprland && Hyprland.workspaces) {
        const wss = Hyprland.workspaces.values;
        for (let i = 0; i < wss.length; ++i) {
          const w = wss[i];
          if (w && w.hasFullscreen) return true;
        }
      }
    } catch (e2) {}
    return false;
  }

  readonly property bool watching: root.inhibitOnPlayback
    && (NowPlaying.playing || root.hasMprisPlaying || root.hasFullscreen)

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
        + " fullscreen=" + root.hasFullscreen
        + " np=" + NowPlaying.playing
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
  }
}
