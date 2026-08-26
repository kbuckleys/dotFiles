// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// CHRONOS — the pomodoro timers. A singleton because they have to keep
// counting whether or not the layer that shows them is open, and because the
// bar wants to know if anything is running without opening anything.
//
// One Timer drives all of them. N QML Timers would each fire on their own
// phase and drift apart from each other; one tick means every countdown is
// always reading from the same second.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "chronos.js" as Chr

Singleton {
  id: root

  // [{ label, minutes, remaining, running }]
  property var timers: []

  readonly property int defaultMinutes: 25
  readonly property int maxTimers: 8

  readonly property bool anyRunning: {
    for (let i = 0; i < root.timers.length; ++i)
      if (root.timers[i].running) return true;
    return false;
  }

  // ── editing ──────────────────────────────────────────────────────────
  // Every mutation replaces the array rather than editing in place: QML does
  // not see a property change when the contents of a var array are poked, so
  // the grid would keep showing the old numbers.
  function mutate(fn) {
    const next = root.timers.map((t) => ({
      label: t.label, minutes: t.minutes,
      remaining: t.remaining, running: t.running
    }));
    fn(next);
    root.timers = next;
    saveTimer.restart();
  }

  function add(label, minutes) {
    if (root.timers.length >= root.maxTimers) return;
    root.mutate((ts) => ts.push({
      label: label || ("Pomodoro " + (ts.length + 1)),
      minutes: minutes || root.defaultMinutes,
      remaining: 0,
      running: false
    }));
  }

  function remove(i) {
    root.mutate((ts) => { if (i >= 0 && i < ts.length) ts.splice(i, 1); });
  }

  function bump(i, delta) {
    root.mutate((ts) => {
      const t = ts[i];
      if (!t) return;
      t.minutes = Math.max(1, Math.min(600, t.minutes + delta));
      // an idle timer follows its own length; a running one keeps counting
      // from where it is, so nudging the dial mid-session cannot rewind it
      if (!t.running) t.remaining = 0;
    });
  }

  function toggle(i) {
    root.mutate((ts) => {
      const t = ts[i];
      if (!t) return;
      if (t.running) { t.running = false; return; }
      if (t.remaining <= 0) t.remaining = t.minutes * 60;
      t.running = true;
    });
  }

  function reset(i) {
    root.mutate((ts) => {
      const t = ts[i];
      if (!t) return;
      t.running = false;
      t.remaining = 0;
    });
  }

  function relabel(i, label) {
    root.mutate((ts) => { if (ts[i]) ts[i].label = label; });
  }

  // ── the tick ─────────────────────────────────────────────────────────
  Timer {
    interval: 1000
    repeat: true
    // only while something is actually counting; an idle shell should not be
    // rebuilding this array once a second forever
    running: root.anyRunning
    onTriggered: {
      const done = [];
      root.mutate((ts) => {
        for (let i = 0; i < ts.length; ++i) {
          const t = ts[i];
          if (!t.running) continue;
          t.remaining -= 1;
          if (t.remaining <= 0) {
            t.remaining = 0;
            t.running = false;
            done.push({ label: t.label, minutes: t.minutes });
          }
        }
      });
      for (const t of done) root.fire(t);
    }
  }

  // Announced through notify-send rather than by reaching into howler
  // directly. It goes out over DBus and comes back in through the same server
  // every other application uses, so a finished timer is a notification in
  // the ordinary sense — it lands in the history and the bell counts it.
  //
  // Critical urgency, which howler's ported mako config gives a timeout of 0:
  // it stays on screen until dismissed, which is the whole point of a timer.
  function fire(t) {
    Quickshell.execDetached([
      "notify-send", "-u", "critical", "-a", "chronos",
      t.label, t.minutes + " minute timer finished"
    ]);
  }

  // ── persistence ──────────────────────────────────────────────────────
  FileView {
    id: stateFile
    path: Quickshell.statePath("chronos.json")
    blockLoading: true
    printErrors: false
  }

  Timer {
    id: saveTimer
    interval: 400
    onTriggered: stateFile.setText(Chr.serialize(root.timers))
  }

  // No default timer. An empty list stays empty — the panel says "no timers,
  // n to add one", which is a better first impression than a pomodoro someone
  // else decided you wanted.
  Component.onCompleted: root.timers = Chr.parse(stateFile.text())
}
