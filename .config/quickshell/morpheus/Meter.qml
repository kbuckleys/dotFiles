// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// A segmented level meter — the shape network's throughput bars already had,
// lifted out so cpu, gpu, volume and the volume OSD read as the same
// instrument rather than four lookalikes that drift apart.
//
// Unlit segments are the accent dimmed rather than a neutral grey, so a meter
// keeps its identity at rest: a red bar at 0% is still recognisably the cpu.

import QtQuick
import QtQuick.Effects
import "."

Item {
  id: root

  // 0..1. Anything outside is clamped, so a source that overshoots (pipewire
  // allows volume above 1.0) pins the meter full instead of overflowing it.
  property real value: 0
  property color accent: Zenon.white
  property int segCount: 6
  // across the bar, and along it
  property int thickness: 6
  property int segLength: 2
  property int segGap: 1
  property bool vertical: true

  // A level that is present but tiny still lights one segment: "very quiet"
  // and "silent" must not look identical.
  property real deadZone: 0.02

  readonly property int lit: {
    const v = Math.max(0, Math.min(1, root.value));
    if (v <= root.deadZone) return 0;
    return Math.max(1, Math.min(root.segCount, Math.round(v * root.segCount)));
  }

  readonly property int span: root.segCount * (root.segLength + root.segGap) - root.segGap

  // A meter that has pinned should say so from the corner of the eye, without
  // adding a colour the bar does not already use. Same trick the track name
  // wears: MultiEffect's shadow with no offset, tinted to the meter's OWN
  // accent, so it reads as the bar glowing rather than as a second copy of it.
  readonly property bool maxed: root.segCount > 0 && root.lit === root.segCount

  implicitWidth: root.vertical ? root.thickness : root.span
  implicitHeight: root.vertical ? root.span : root.thickness

  Grid {
    id: bars
    anchors.fill: parent

    layer.enabled: true
    layer.effect: MultiEffect {
      shadowEnabled: true
      shadowColor: bars.ink
      shadowBlur: 1.0
      shadowScale: 1.10
      shadowHorizontalOffset: 0
      shadowVerticalOffset: 0
      blurMax: 26
      shadowOpacity: bars.glow
      Behavior on shadowOpacity {
        NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease }
      }
    }
    // Copied onto the Grid because a layer.effect is its own component and
    // cannot see the ids around it — these two it can reach through `bars`.
    property color ink: root.accent
    property real glow: root.maxed ? 1 : 0
    rows: root.vertical ? root.segCount : 1
    columns: root.vertical ? 1 : root.segCount
    rowSpacing: root.segGap
    columnSpacing: root.segGap

    Repeater {
      model: root.segCount

      Rectangle {
        required property int index
        width: root.vertical ? root.thickness : root.segLength
        height: root.vertical ? root.segLength : root.thickness
        radius: 1
        // A vertical meter fills from the bottom, so its first grid cell is
        // the LAST segment to light; a horizontal one fills left to right.
        readonly property int rank: root.vertical
          ? root.segCount - 1 - index : index
        color: rank < root.lit ? root.accent : Zenon.trough(root.accent)
        Behavior on color { ColorAnimation { duration: Zenon.fast } }
      }
    }
  }
}
