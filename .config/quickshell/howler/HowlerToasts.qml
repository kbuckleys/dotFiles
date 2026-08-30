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
import Quickshell.Hyprland
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

  // osd.active, not the OSD's animated height: a hidden window does not
  // render, so an animation that has to run before the window may become
  // visible never ticks. The plain bool breaks that deadlock.
  visible: toasts.rows.length > 0 || osd.active

  // Only the toasts take clicks. Without this the whole invisible surface
  // would swallow the pointer across the bottom of the screen.
  mask: Region { item: column }

  readonly property var rows: {
    const list = Howler.live.values.slice();
    list.sort(Wolf.byPriority);
    return list.slice(0, Howler.maxVisible);
  }

  Column {
    id: column
    // No fixed width any more. Each toast sizes to its own text, and the
    // column takes the width of the widest — so a stack of mixed widths stays
    // centred on the screen rather than left-aligned against the widest one.
    anchors.horizontalCenter: parent.horizontalCenter
    // mako: margin=2 between notifications
    spacing: Howler.margin

    Repeater {
      model: toasts.rows

      delegate: Rectangle {
        id: toast
        required property var modelData

        // The icon is resolved up here so the width can account for it: the
        // image hint an app sends beats its generic app icon, and iconPath's
        // check flag gives "" for one that does not resolve, so a toast with
        // nothing to show reserves no room and its text stays centred.
        readonly property string iconSource: {
          const img = toast.modelData.image ?? "";
          if (img !== "") return img;
          const ai = toast.modelData.appIcon ?? "";
          return ai === "" ? "" : Quickshell.iconPath(ai, true);
        }
        readonly property bool hasIcon: Howler.iconsEnabled && toast.iconSource !== "" && toast.modelData.appName !== "waybar-updates"

        // Grows with its content: floored at mako's 400 so short ones keep a
        // familiar shape, capped at 800 so one long line cannot run the width
        // of the screen.
        readonly property real naturalWidth:
          (toast.hasIcon ? Howler.iconSize + Howler.padding * 2 : 0)
          + Math.max(summaryText.implicitWidth, bodyText.implicitWidth)
          + Howler.padding * 2 + Howler.borderSize * 2
        width: Math.round(Math.max(Howler.toastWidth,
          Math.min(Howler.toastMaxWidth, toast.naturalWidth)))
        anchors.horizontalCenter: parent.horizontalCenter

        // mako: height=400 is a per-toast maximum, not a fixed height
        implicitHeight: Math.min(Howler.toastMaxHeight,
          Math.max(inner.implicitHeight + Howler.padding * 2, Howler.minHeight))

        color: Howler.bgFor(toast.modelData.urgency)
        border.color: Howler.borderFor(toast.modelData.urgency)
        border.width: Howler.borderSize
        radius: Howler.radius

        // the player this notification belongs to, or null if it is not
        // music. Re-evaluated live: a track can end while its toast is up.
        readonly property var player:
          Howler.playerFor(toast.modelData.appName, toast.modelData.desktopEntry,
                           Howler.mprisHintOf(toast.modelData))
        readonly property bool isSong: toast.player !== null

        // The OSD's entrance, so the two things that appear above the pill
        // arrive the same way: the surface grows into place on the slower
        // curve while its contents fade on the faster one. A fade alone made
        // the stack below jump by a whole toast height in one frame.
        property bool up: false
        Component.onCompleted: toast.up = true
        clip: true
        height: toast.up ? toast.implicitHeight : 0
        Behavior on height {
          NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease }
        }
        opacity: toast.up ? 1 : 0
        Behavior on opacity {
          NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease }
        }

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
          running: toast.lifetime > 0 && !onToast.hovered
          onTriggered: toast.modelData.expire()
        }

        // Left goes to whatever sent it, right sends it away, middle clears
        // the lot. mako put dismiss on left; a notification you can only
        // dismiss is a notification you have to go and act on by hand.
        function activate() {
          const acts = toast.modelData.actions ?? [];
          for (let i = 0; i < acts.length; ++i) {
            // "default" is the freedesktop way of saying "open me", and an
            // app that offers it knows better than we do where to land
            if (acts[i].identifier === "default") {
              acts[i].invoke();
              return;
            }
          }
          // Nothing offered, so ask hyprland for a window belonging to the
          // app. desktopEntry is the reliable one; appName is a display name
          // and only sometimes matches the window class.
          const cls = String(toast.modelData.desktopEntry
            || toast.modelData.appName || "");
          if (cls !== "")
            Hyprland.dispatch('hl.dsp.focus({ window = "class:' + cls + '" })');
          toast.modelData.dismiss();
        }

        // HOVER IS A HANDLER, NOT THE MOUSE AREA'S.
        //
        // The summary and the body are StyledText, and Qt makes styled text
        // accept hover events so links can highlight -- so both of them sat ON
        // TOP of the MouseArea below and swallowed every hover that landed on
        // them. `containsMouse` was true only over the padding and the gap beside
        // the icon: the transport row appeared when the pointer was nowhere near
        // it and vanished the moment you moved onto the words.
        //
        // Worse for the buttons themselves, which is what made them unreachable:
        // a TransportKey has a MouseArea of its own, so reaching for one took the
        // hover off this one and faded the row out from under the pointer. A
        // HoverHandler reports on the whole subtree -- children that accept hover
        // are part of being hovered rather than an interruption of it.
        // ...and the cursor with it, for the same reason: set on the MouseArea it
        // only reached the blank parts of the toast.
        HoverHandler { id: onToast; cursorShape: Qt.PointingHandCursor }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
          cursorShape: Qt.PointingHandCursor
          onClicked: (e) => {
            if (e.button === Qt.RightButton) toast.modelData.dismiss();
            else if (e.button === Qt.MiddleButton) Howler.dismissAll();
            else toast.activate();
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
            visible: toast.hasIcon
            width: visible ? Howler.iconSize : 0
            height: width

            IconImage {
              id: icon
              anchors.fill: parent
              source: toast.iconSource
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
              id: summaryText
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
                opacity: (toast.isSong && onToast.hovered) ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }

                TransportKey {
                  glyph: "\uF04A"
                  size: 20
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
    // The volume OSD sits below the toasts, so a stack that is already up
    // rides above it instead of being covered by it.
    HowlerOsd { id: osd }

  }
}
