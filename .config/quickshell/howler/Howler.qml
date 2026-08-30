// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// The notification daemon, and the single owner of everything about it: the
// ported mako config, the DBus server, the live toast list and the history.
// A singleton because two very different things read it — the toast overlay
// and the bar's bell — and they must never disagree about what has arrived.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import Quickshell.Services.Mpris
import "../morpheus"
import "howler.js" as Wolf

Singleton {
  id: root

  // ── ~/.config/mako/config, ported key by key ─────────────────────────
  // The colours are not restated as hex here. Mako's palette WAS the Zenon
  // palette written out longhand — background-color=#dfdfdd is Zenon.white,
  // border-color=#20242a is Zenon.surface, and so on — so each one names its
  // token instead, and the two can no longer drift apart.
  //
  //   font=JetBrainsMono Nerd Font Propo SemiBold 12
  readonly property string fontFamily: "JetBrainsMono Nerd Font Propo"
  readonly property int fontWeight: Font.DemiBold
  // mako's 12 is points; 16px is what that comes out as here, and it is the
  // size every other panel in this shell already uses
  readonly property int fontSize: 16
  //   border-size=1  border-radius=5  padding=5  margin=2  outer-margin=0,0,20
  readonly property int borderSize: 1
  readonly property int radius: 5
  readonly property int padding: 5
  readonly property int margin: 2
  readonly property int outerMargin: 20
  //   width=400  height=400   (mako's height is a per-toast maximum)
  //   400 is now a FLOOR rather than the width: a toast grows with its text
  //   up to toastMaxWidth, which mako had no equivalent for.
  readonly property int toastWidth: 400
  readonly property int toastMaxWidth: 800
  readonly property int toastMaxHeight: 400
  //   nothing shorter than this, so a one-word notification still reads as a
  //   panel rather than as a strip
  readonly property int minHeight: 64
  //   max-visible=5
  readonly property int maxVisible: 5
  //   icons=1  max-icon-size=96  icon-border-radius=5  icon-location=left
  readonly property bool iconsEnabled: true
  readonly property int maxIconSize: 96
  //   what an icon is actually drawn at — mako's 96 is the ceiling, not the
  //   size, and 64 was leaving album art smaller than it deserved
  readonly property int iconSize: 76
  readonly property int iconRadius: 5
  //   markup=1  text-alignment=center
  readonly property bool markup: true
  readonly property int textAlign: Text.AlignHCenter
  //   default-timeout=5000, and the per-urgency overrides under it
  readonly property int defaultTimeout: 5000
  readonly property int timeoutLow: 4000
  readonly property int timeoutNormal: 4000
  // [urgency=critical] default-timeout=0 — never expires on its own
  readonly property int timeoutCritical: 0

  // mako had history=0. That is the one line of its config deliberately NOT
  // ported: the whole point of the bar's bell is that a toast you missed is
  // still there afterwards.
  readonly property int historyCap: 200

  function bgFor(urgency) {
    if (urgency === NotificationUrgency.Low) return Zenon.green;
    if (urgency === NotificationUrgency.Critical) return Zenon.yellow;
    return Zenon.white;
  }
  // every urgency in mako's config used text-color=#000000
  function fgFor(urgency) { return Zenon.black; }
  function borderFor(urgency) { return Zenon.surface; }

  // What the app asked for wins; -1 or 0 means "you decide", and that is where
  // the per-urgency defaults come in. Critical resolves to 0 = never expires.
  function timeoutFor(urgency, requested) {
    if (requested > 0) return requested;
    if (urgency === NotificationUrgency.Low) return root.timeoutLow;
    if (urgency === NotificationUrgency.Critical) return root.timeoutCritical;
    return root.timeoutNormal;
  }

  // ── the server ───────────────────────────────────────────────────────

  readonly property alias server: server
  readonly property var live: server.trackedNotifications

  NotificationServer {
    id: server
    // survive a config reload: editing a QML file should not silently swallow
    // whatever is on screen at the time
    keepOnReload: true
    actionsSupported: true
    actionIconsSupported: true
    bodySupported: true
    bodyMarkupSupported: true
    imageSupported: true
    persistenceSupported: true

    onNotification: (notif) => {
      notif.tracked = true;
      // the updates count re-sends a toast on every pump: it only exists to
      // be that toast, so it never earns a row in the bell's history
      if (!root.isUpdate(notif) &&
          (root.trackMusic || !root.playerFor(notif.appName, notif.desktopEntry)))
        root.record(notif);
    }
  }

  // ── history ──────────────────────────────────────────────────────────
  // Plain snapshots, not the Notification objects themselves. The objects are
  // Retainable and go away once dismissed, and they cannot be written to disk;
  // a snapshot survives both the dismissal and the next shell restart.
  property var history: []
  // whether to also record notifications from MPRIS music players
  property bool trackMusic: false
  // how many have arrived since the history panel was last opened
  property int unread: 0

  // the updates module's one-shot: a toast, but never a row in the list —
  // it is there and gone on its own timer, not something to scroll back to
  function isUpdate(notif) {
    return String(notif.appName ?? "").toLowerCase() === "waybar-updates";
  }

  function record(notif) {
    const row = {
      id: notif.id,
      time: Date.now(),
      appName: notif.appName ?? "",
      appIcon: notif.appIcon ?? "",
      image: notif.image ?? "",
      summary: notif.summary ?? "",
      body: notif.body ?? "",
      urgency: notif.urgency,
      desktopEntry: notif.desktopEntry ?? ""
    };
    const next = [row].concat(root.history);
    root.history = next.slice(0, root.historyCap);
    root.unread = root.unread + 1;
    saveTimer.restart();
  }

  function markRead() {
    root.unread = 0;
  }

  function forget(index) {
    if (index < 0 || index >= root.history.length) return;
    const next = root.history.slice();
    next.splice(index, 1);
    root.history = next;
    saveTimer.restart();
  }

  function clearHistory() {
    root.history = [];
    root.unread = 0;
    saveTimer.restart();
  }

  // dismiss everything currently on screen, leaving history untouched
  function dismissAll() {
    const list = server.trackedNotifications.values.slice();
    for (const n of list) n.dismiss();
  }

  // ── which notifications are music ────────────────────────────────────
  // Asked of the live MPRIS player list rather than a hardcoded set of app
  // names, so a notification only grows transport controls when there is a
  // real player behind it for them to drive.
  function playerFor(appName, desktopEntry) {
    return Wolf.matchPlayer(Mpris.players.values, appName, desktopEntry);
  }

  function toggleMusicTracking(): string {
    root.trackMusic = !root.trackMusic;
    // turning it off retroactively clears what it let in, so the list matches
    // the setting rather than keeping a tail of songs nobody asked for
    if (!root.trackMusic) root.cleanHistory();
    return root.trackMusic ? "music tracking enabled" : "music tracking disabled";
  }

  // ── persistence ──────────────────────────────────────────────────────

  // Sweep out rows that came from something which turned out to be an MPRIS
  // player. Only ever while tracking is OFF: with it on, those rows are the
  // whole point, and this would delete them behind the setting's back.
  function cleanHistory() {
    if (root.trackMusic) return;
    const players = Mpris.players.values;
    if (players.length === 0) return;
    const next = root.history.filter((row) => !root.playerFor(row.appName, row.desktopEntry));
    if (next.length === root.history.length) return;
    root.history = next;
    histFile.setText(Wolf.serialize(root.history));
  }

  FileView {
    id: histFile
    path: Quickshell.statePath("howler-history.json")
    blockLoading: true
    printErrors: false
  }

  Timer {
    id: saveTimer
    interval: 400
    onTriggered: histFile.setText(Wolf.serialize(root.history))
  }

  Component.onCompleted: {
    root.history = Wolf.parse(histFile.text());
    root.cleanHistory();
  }
}
