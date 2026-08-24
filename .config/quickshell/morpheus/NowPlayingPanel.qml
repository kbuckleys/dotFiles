// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// The hover panel behind the audio cluster — cover art, what is playing, the
// transports, and the volume. It replaced the plain text tooltips on both the
// transport glyph and the volume meter, so there is one thing to hover for
// anything to do with sound.
//
// Unlike a Tooltip it is interactive: the buttons in it are real. That is why
// it latches its position instead of riding the cursor, and why it stays up
// while the pointer is on it as well as on the module that opened it.

import QtQuick
import Quickshell.Widgets
import "."

CursorAnchor {
  id: panel

  interactive: true
  hitArea: bg
  // enough clearance to read as a separate surface, little enough that the
  // pointer crosses it before the unlatch timer notices
  gap: 6

  // No cursorArea is passed in by the modules that host this, which is what
  // puts it centred over the module instead of wherever the pointer happened
  // to enter. It also means there is a fixed place to aim for on the way to
  // the buttons, rather than a panel that sat somewhere new every time.

  // the module that owns this panel says whether its own pointer is on it
  property bool sourceHovered: false

  // Hysteresis, because there is a few pixels of nothing between the module
  // and the panel and the pointer has to cross it. Without the latch the
  // panel closes the instant you reach for a button on it.
  readonly property bool wanted: panel.sourceHovered || hover.hovered
  property bool held: false
  onWantedChanged: {
    if (panel.wanted) { panel.held = true; unlatch.stop(); }
    else unlatch.restart();
  }
  Timer { id: unlatch; interval: 220; onTriggered: panel.held = panel.wanted }
  show: panel.held

  implicitWidth: bg.implicitWidth
  implicitHeight: bg.implicitHeight

  Rectangle {
    id: bg
    implicitWidth: layout.implicitWidth + 28
    implicitHeight: layout.implicitHeight + 22
    opacity: panel.showFactor
    color: Zenon.panelBg
    border.color: Zenon.surface
    border.width: 1
    radius: 6

    // Handlers, not a filling MouseArea. A MouseArea reports containsMouse
    // false the moment the pointer crosses onto a CHILD MouseArea, so putting
    // the pointer on a transport button read as leaving the panel and closed
    // it out from under the click. A HoverHandler stays true across its whole
    // subtree, buttons included.
    HoverHandler { id: hover }

    // the same notch the volume meter in the bar takes, so the wheel means the
    // same thing whether the pointer is on the module or on the panel
    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: (event) => Volume.nudge(event.angleDelta.y > 0 ? 0.01 : -0.01)
    }

    Column {
      id: layout
      anchors.centerIn: parent
      spacing: 12

      // ── what is playing ──────────────────────────────────────────
      Row {
        spacing: 14
        visible: NowPlaying.active

        ClippingRectangle {
          width: 76
          height: 76
          radius: 5
          color: Zenon.surface

          Image {
            id: art
            anchors.fill: parent
            source: NowPlaying.artUrl
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            // the url changes with every track; caching it would pin a
            // failed decode to a station that has simply not sent art yet
            cache: false
          }

          // plenty of players send no art at all; a note beats an empty box
          Text {
            anchors.centerIn: parent
            visible: art.status !== Image.Ready
            text: ""
            color: Zenon.muted
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 26
          }
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: 3

          Text {
            // wide enough for a long title, capped so one cannot stretch the
            // panel across the screen
            width: Math.min(implicitWidth, 320)
            text: NowPlaying.title
            visible: text !== ""
            color: Zenon.white
            elide: Text.ElideRight
            font.family: "JetBrainsMono Nerd Font Propo"
            font.weight: Font.Bold
            font.pixelSize: 16
          }

          Text {
            width: Math.min(implicitWidth, 320)
            text: NowPlaying.artist
            visible: text !== ""
            color: Zenon.pink
            elide: Text.ElideRight
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 15
          }

          Text {
            width: Math.min(implicitWidth, 320)
            text: NowPlaying.album
            visible: text !== ""
            color: Zenon.muted
            elide: Text.ElideRight
            font.family: "JetBrainsMono Nerd Font Propo"
            font.pixelSize: 15
          }
        }
      }

      // ── the transports ───────────────────────────────────────────
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 26
        visible: NowPlaying.active

        TransportKey {
          glyph: ""
          ink: Zenon.white
          onActivated: NowPlaying.previous()
        }
        TransportKey {
          glyph: NowPlaying.playing ? "" : ""
          ink: Zenon.green
          onActivated: NowPlaying.toggle()
        }
        TransportKey {
          glyph: ""
          ink: Zenon.white
          onActivated: NowPlaying.next()
        }
      }

      Rectangle {
        width: layout.width
        height: 1
        color: Zenon.surface
        visible: NowPlaying.active
      }

      // ── volume ───────────────────────────────────────────────────
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 10

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: Volume.muted ? "" : ""
          color: Volume.muted ? Zenon.red : Zenon.green
          font.family: "JetBrainsMono Nerd Font Propo"
          font.weight: Font.Bold
          font.pixelSize: 16
        }

        Meter {
          anchors.verticalCenter: parent.verticalCenter
          vertical: false
          segCount: 14
          thickness: 7
          segLength: 4
          segGap: 2
          value: Volume.muted ? 0 : Volume.level
          accent: Volume.muted ? Zenon.red : Zenon.green
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: 46
          horizontalAlignment: Text.AlignRight
          text: Volume.muted ? "muted" : Volume.percent + "%"
          color: Volume.muted ? Zenon.red : Zenon.white
          font.family: "JetBrainsMono Nerd Font Propo"
          font.weight: Font.Bold
          font.pixelSize: 15
        }
      }
    }
  }
}
