// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// The toasts themselves — mako's on-screen half. Everything about how they
// look and how long they last comes from Howler, which is where the ported
// config lives; this file only lays it out.

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import "../morpheus"
import "../morpheus/helpers.js" as Helpers
import "howler.js" as Wolf

PanelWindow {
  id: toasts

  property var statusbar: null

  // mako: layer=overlay
  WlrLayershell.layer: WlrLayer.Overlay
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  // mako: anchor=bottom-center. Anchoring both sides and centring the column
  // inside, rather than leaving them unanchored: an unanchored axis is not
  // centred by the compositor, it is pinned to an edge — hyprland put the
  // whole stack flush against the right of the screen.
  anchors { left: true; right: true; bottom: true }
  // mako's outer-margin bottom was measured from the screen edge, but the
  // pill lives there now, so the same 20px is measured from the pill's top
  // instead — off the pill's monitor bottomLift is just the screen clearance
  // and the gap lands where mako put it.
  margins.bottom: Zenon.bottomLift(false, toasts.screen, toasts.statusbar)
    + Howler.outerMargin

  implicitHeight: Math.max(1, column.implicitHeight)

  visible: toasts.rows.length > 0

  // Only the toasts take clicks. Without this the whole invisible surface
  // would swallow the pointer across the bottom of the screen.
  mask: Region { item: column }

  // mako: max-visible=5, sort=-priority
  readonly property var rows: {
    const list = Howler.live.values.slice();
    list.sort(Wolf.byPriority);
    return list.slice(0, Howler.maxVisible);
  }

  // Declared here rather than inside the delegate: inline components are only
  // legal at the document root, and one nested in the delegate could not see
  // the delegate's scope anyway. Everything it needs is passed in.
  component TransportKey: Text {
    id: key
    property string glyph: ""
    property color ink: Zenon.black
    signal activated()

    text: key.glyph
    color: key.ink
    font.family: Howler.fontFamily
    font.weight: Font.Bold
    font.pixelSize: 20
    // dim until pointed at, so the row reads as three targets rather than
    // three decorations
    opacity: keyArea.containsMouse ? 1 : 0.55
    Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

    MouseArea {
      id: keyArea
      anchors.fill: parent
      // a glyph is a small target; grow the hit area past its ink
      anchors.margins: -6
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: key.activated()
    }
  }

  Column {
    id: column
    // mako: width=400
    width: Howler.toastWidth
    anchors.horizontalCenter: parent.horizontalCenter
    // mako: margin=2 between notifications
    spacing: Howler.margin

    Repeater {
      model: toasts.rows

      delegate: Rectangle {
        id: toast
        required property var modelData

        width: column.width
        // mako: height=400 is a per-toast maximum, not a fixed height
        implicitHeight: Math.min(Howler.toastMaxHeight,
          Math.max(inner.implicitHeight + Howler.padding * 2, 44))
        height: implicitHeight

        color: Howler.bgFor(toast.modelData.urgency)
        border.color: Howler.borderFor(toast.modelData.urgency)
        border.width: Howler.borderSize
        radius: Howler.radius

        // the player this notification belongs to, or null if it is not
        // music. Re-evaluated live: a track can end while its toast is up.
        readonly property var player:
          Howler.playerFor(toast.modelData.appName, toast.modelData.desktopEntry)
        readonly property bool isSong: toast.player !== null

        // entrance, and the fade Retainable gives us on the way out
        opacity: 0
        Component.onCompleted: toast.opacity = 1
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        // ── expiry ────────────────────────────────────────────────────
        // A timeout of 0 — mako's [urgency=critical] — means never, so the
        // timer simply does not run.
        readonly property int lifetime:
          Howler.timeoutFor(toast.modelData.urgency, toast.modelData.expireTimeout)

        Timer {
          id: life
          interval: Math.max(1, toast.lifetime)
          // Paused while the pointer is on the toast: you cannot reach a
          // song's transport buttons if the thing carrying them times out
          // from under your cursor.
          running: toast.lifetime > 0 && !hover.containsMouse
          onTriggered: toast.modelData.expire()
        }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton
          cursorShape: Qt.PointingHandCursor
          // mako's default left-click action
          onClicked: (e) => {
            if (e.button === Qt.MiddleButton) Howler.dismissAll();
            else toast.modelData.dismiss();
          }
        }

        Item {
          id: inner
          anchors.fill: parent
          anchors.margins: Howler.padding
          implicitHeight: Math.max(iconBox.height, textCol.implicitHeight)

          // ── mako: icons=1, icon-location=left ───────────────────────
          ClippingRectangle {
            id: iconBox
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            color: "transparent"
            // mako: icon-border-radius=5
            radius: Howler.iconRadius
            visible: Howler.iconsEnabled && icon.source !== ""
            // mako: max-icon-size=96, but never taller than the toast body
            width: visible ? Math.min(Howler.maxIconSize, 64) : 0
            height: width

            IconImage {
              id: icon
              anchors.fill: parent
              // the image hint an app sends beats its generic app icon
              source: {
                const img = toast.modelData.image ?? "";
                if (img !== "") return img;
                const ai = toast.modelData.appIcon ?? "";
                return ai === "" ? "" : Quickshell.iconPath(ai, true);
              }
            }
          }

          Column {
            id: textCol
            anchors.left: iconBox.visible ? iconBox.right : parent.left
            anchors.leftMargin: iconBox.visible ? Howler.padding * 2 : 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            // mako: format=<b>%s</b>\n%b — the summary line, bolded
            Text {
              width: parent.width
              visible: text !== ""
              text: Wolf.escapeHtml(toast.modelData.summary)
              textFormat: Text.StyledText
              color: Howler.fgFor(toast.modelData.urgency)
              font.family: Howler.fontFamily
              font.weight: Font.Bold
              font.pixelSize: Howler.fontSize
              horizontalAlignment: Howler.textAlign
              wrapMode: Text.WordWrap
              elide: Text.ElideRight
              maximumLineCount: 2
            }

            // The body and the transport row share this slot and crossfade,
            // so a song toast keeps exactly the size it had before you
            // hovered it — the stack underneath must not shift under the
            // pointer just because you moved onto one.
            Item {
              width: parent.width
              height: Math.max(bodyText.implicitHeight, transport.implicitHeight)
              visible: bodyText.text !== "" || toast.isSong

              Text {
                id: bodyText
                anchors.fill: parent
                // mako: markup=1 — pango markup, reduced to the subset Qt's
                // StyledText understands by the same helper the bar uses
                text: Helpers.pangoToStyled(Wolf.formatBody(toast.modelData.body, Howler.markup))
                textFormat: Howler.markup ? Text.StyledText : Text.PlainText
                color: Howler.fgFor(toast.modelData.urgency)
                font.family: Howler.fontFamily
                font.weight: Howler.fontWeight
                font.pixelSize: Howler.fontSize
                horizontalAlignment: Howler.textAlign
                verticalAlignment: Text.AlignVCenter
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                opacity: 1 - transport.opacity
                visible: opacity > 0.01
              }

              Row {
                id: transport
                anchors.centerIn: parent
                spacing: 18
                opacity: (toast.isSong && hover.containsMouse) ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

                TransportKey {
                  glyph: "\uF04A"
                  ink: Howler.fgFor(toast.modelData.urgency)
                  onActivated: if (toast.player) toast.player.previous();
                }
                TransportKey {
                  glyph: toast.player && toast.player.isPlaying ? "\uF04C" : "\uF04B"
                  ink: Howler.fgFor(toast.modelData.urgency)
                  onActivated: if (toast.player) toast.player.togglePlaying();
                }
                TransportKey {
                  glyph: "\uF04E"
                  ink: Howler.fgFor(toast.modelData.urgency)
                  onActivated: if (toast.player) toast.player.next();
                }
              }
            }
          }
        }
      }
    }
  }
}
