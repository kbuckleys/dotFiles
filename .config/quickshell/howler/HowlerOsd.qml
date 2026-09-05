// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// The volume OSD. It rides at the bottom of the toast column rather than in a
// surface of its own: both would anchor bottom-centre on the focused monitor
// and overlap, and sharing the column means the toasts simply stack above it
// with no coordination between the two.
//
// Styled as pill chrome, not as a toast — a dark panel against the toasts'
// light ones — because it is the shell talking about itself, not an app
// notifying you of something.
//
// Brightness is deliberately absent. This machine has no backlight device and
// no DDC/CI, so a brightness channel here could never fire; it belongs in this
// file the day there is something to turn down.

import QtQuick
import Quickshell
import "../morpheus"

Item {
  id: osd

  property bool active: false

  readonly property var sink: Volume.sink
  readonly property real level: Volume.level
  readonly property bool muted: Volume.muted
  readonly property int percent: Volume.percent

  // Bindings fire once when this is created and again whenever the default
  // sink is swapped. Neither is someone reaching for the volume key, so the
  // OSD stays down until a settle timer has seen the current sink's values.
  property bool primed: false
  onSinkChanged: { osd.primed = false; settle.restart(); }
  Component.onCompleted: settle.restart()

  Timer { id: settle; interval: 400; onTriggered: osd.primed = true }

  onLevelChanged: osd.flash()
  onMutedChanged: osd.flash()

  function flash() {
    if (!osd.primed) return;
    osd.active = true;
    hold.restart();
  }

  // Restarted on every step, so a held key-repeat keeps it up and the second
  // starts counting from the last change rather than the first.
  Timer { id: hold; interval: 1000; onTriggered: osd.active = false }

  // Its own width, NOT the column's. The column sizes itself to its widest
  // child now that toasts grow with their text, so asking it for a width from
  // in here was circular — with no toasts up the column had only the OSD to
  // measure, both settled on 0, and the OSD stopped appearing at all.
  //
  // Collapses to nothing vertically so the toast column closes up around it.
  width: body.width
  implicitHeight: osd.active ? body.height : 0
  Behavior on implicitHeight {
    NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease }
  }
  visible: implicitHeight > 0.5
  clip: true

  Rectangle {
    id: body
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    width: 240
    height: 40
    radius: 12
    color: Zenon.panelBgDeep
    border.color: Zenon.surface
    border.width: 1
    opacity: osd.active ? 1 : 0
    Behavior on opacity {
      NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
    }

    Row {
      anchors.centerIn: parent
      spacing: Zenon.gap + 2

      BarText {
        anchors.verticalCenter: parent.verticalCenter
        // the same struck-through speaker the pill uses when muted, so the
        // two never describe the same state with different glyphs
        text: osd.muted ? "" : ""
        color: osd.muted ? Zenon.red : Zenon.green
      }

      Meter {
        anchors.verticalCenter: parent.verticalCenter
        vertical: false
        // a wider bar than the pill's: this one is read at a glance from
        // across the screen, not inspected
        segCount: 16
        thickness: 8
        segLength: 5
        segGap: 2
        value: osd.muted ? 0 : osd.level
        accent: osd.muted ? Zenon.red : Zenon.green
      }

      BarText {
        anchors.verticalCenter: parent.verticalCenter
        // fixed width so the bar does not shuffle sideways as the number
        // crosses 10 and 100
        width: 34
        horizontalAlignment: Text.AlignRight
        // shown while muted too, dimmed: it is the level you come back to
        text: String(osd.percent)
        color: osd.muted ? Zenon.red : Zenon.white
      }
    }
  }
}
