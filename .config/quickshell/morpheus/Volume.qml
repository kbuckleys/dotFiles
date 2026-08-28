// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// What the default sink is doing — level, mute, and the one sentence that
// describes them. Three things ask: the bar's meter, the OSD, and the mpris
// tooltip. Each used to carry its own tracker and its own rounding, which is
// three chances for the pill and the OSD to disagree about the same number.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

Singleton {
  id: root

  // Without this the sink's volume never updates — pipewire only streams
  // properties for objects something has asked to track.
  PwObjectTracker { objects: [Pipewire.defaultAudioSink] }

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var audio: root.sink ? root.sink.audio : null
  readonly property bool ready: root.audio !== null

  readonly property real level: root.audio ? root.audio.volume : 0
  readonly property bool muted: root.audio ? root.audio.muted : false
  readonly property int percent: Math.round(root.level * 100)

  // the exact figure, for tooltips — the meters are a six-notch reading
  readonly property string text: !root.ready ? "Volume: --"
    : (root.muted ? "Volume: Muted" : "Volume: " + root.percent + "%")

  // one scroll notch
  function nudge(step) {
    if (!root.audio) return;
    const next = Math.max(0, Math.min(1, root.level + step));
    if (next === root.level) return;
    root.audio.volume = next;
  }
}
