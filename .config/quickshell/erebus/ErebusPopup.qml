// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "../morpheus"

PanelWindow {
  id: popup

  WlrLayershell.layer: WlrLayer.Overlay

  property bool shown: false
  property bool morphMode: false
  // 0..1, driven by shell.qml, which owns the crossfade schedule: 0 until the
  // pill's own row has finished clearing, then rising to 1 as the pill
  // finishes taking this layer's shape
  property real morphFade: 1
  // the pill's live corner radius; erebus paints over the pill, so it has to
  // wear the pill's corners frame for frame or they peek out around its own
  // single token in Zenon — 8:8 uniform
  property real morphRadius: Zenon.pillRadius
  // Runner's showFactor, adopted: 0..1 eased on Zenon.slow, so
  // standalone open/close is a slide-up fade like runner's, and morphed
  // handover still uses the pill's morphFade via contentFade.
  property real showFactor: popup.shown ? 1 : 0
  Behavior on showFactor { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }
  readonly property real contentFade: popup.morphMode
    ? Math.min(popup.morphFade, popup.showFactor) : popup.showFactor
  property string confirmId: ""
  property int sel: 0

  readonly property string xdgSession: Quickshell.env("XDG_SESSION_ID") || ""

  property var entries: [
    // the sleep lets erebus finish fading before cerberus grabs the shot it
    // blurs, so the lock screen is the desktop and not erebus on its way out
    { id: "lockscreen", label: "", cmd: "sleep 0.35 && qs ipc call Cerberus lock", confirm: false },
    { id: "logout", label: "󰍃", cmd: "hyprshutdown -p 'loginctl terminate-session " + xdgSession + "'", confirm: true },
    { id: "suspend", label: "󰤄", cmd: "systemctl suspend", confirm: true },
    { id: "reboot", label: "", cmd: "hyprshutdown -p 'systemctl reboot'", confirm: true },
    { id: "shutdown", label: "⏻", cmd: "hyprshutdown -p 'systemctl poweroff'", confirm: true }
  ]

  property var confirmActions: [
    { id: "confirm", label: "" },
    { id: "cancel", label: "" }
  ]

  property var statusbar: null

  // Erebus keeps painting its own red panel when morphed, exactly as it looks
  // standalone — the pill takes on erebus' colour rather than showing through
  // it. Letting the panel go transparent here left black glyphs on a dark pill
  // and made the morphed layer look nothing like the standalone one.
  readonly property color accent: Zenon.red
  readonly property color selBg: Zenon.pink
  readonly property color ink: "#000000"
  readonly property color idleGlyph: popup.ink
  // morphed, the panel has to cover the pill's own rounding and 1px border
  // exactly, or they peek out around erebus' corners
  // ONE radius for all four corners. Single token in Zenon (8:8 uniform).
  readonly property real outerRadius: Zenon.pillRadius

  // Runner's rule for selections, adopted here. Two parts to it:
  //
  //   only a cell that actually sits in a panel corner rounds off, so the
  //   strip stays square-edged in the middle. Every middle cell used to round
  //   its bottom by 10, which carved a row of notches along the strip.
  //
  //   and the highlight is held off the panel's stroke, with its corners
  //   struck at the INNER radius so the two arcs nest. Standalone erebus
  //   paints no border, so there is nothing to hold off; morphed, the pill
  //   underneath has one.
  readonly property real edgeInset: popup.morphMode ? 1 : 0
  readonly property real innerCorner: Math.max(0, popup.outerRadius - popup.edgeInset)
  readonly property int lastEntry: popup.entries.length - 1

  // shell.qml sizes the morphed pill from this. The confirm step doubles the
  // panel's height, so a fixed number here leaves the confirm row hanging
  // outside the pill background.
  function calcHeight() {
    return popup.confirmId === "" ? 36 : 72;
  }

  visible: popup.shown || popup.contentFade > 0.01 || popup.showFactor > 0.01
  color: "transparent"
  anchors { left: true; right: true; top: true; bottom: true }
  exclusionMode: ExclusionMode.Ignore
  focusable: true

  HyprlandFocusGrab {
    id: grab
    windows: [ popup ]
    active: popup.shown
    onCleared: popup.closeSession()
  }

  IpcHandler {
    target: "Erebus"
    function toggle() {
      popup.toggle();
    }
  }

  function currentList() {
    return popup.confirmId === "" ? popup.entries : popup.confirmActions;
  }

  function currentEntry() {
    for (let i = 0; i < popup.entries.length; ++i) {
      if (popup.entries[i].id === popup.confirmId) return popup.entries[i];
    }
    return null;
  }

  function openSession() {
    // Reset BEFORE announcing the session. `shown` notifies synchronously, and
    // shell.qml answers that by setting activeLayer and reading calcHeight() —
    // so a stale confirmId here sizes the pill to the confirm height and paints
    // last session's confirm dialog for a frame before the clear lands.
    popup.confirmId = "";
    popup.sel = 0;
    popup.shown = true;
    focusRetry.counter = 0;
    focusRetry.restart();
  }

  function closeSession() {
    popup.shown = false;
    // clear once the fade has finished, so the panel doesn't visibly snap
    // back to its base height on the way out
    resetOnClose.restart();
  }

  function toggle() {
    if (popup.shown) popup.closeSession();
    else popup.openSession();
  }

  function execute(cmd) {
    Quickshell.execDetached(["sh", "-c", cmd + " >/dev/null 2>&1 &"]);
  }

  function confirm() {
    const list = popup.currentList();
    const item = list[popup.sel];
    if (!item) return;
    if (popup.confirmId === "") {
      const entry = item;
      if (!entry.confirm) {
        popup.execute(entry.cmd);
        popup.closeSession();
      } else {
        popup.confirmId = entry.id;
        popup.sel = 0;
      }
    } else {
      if (item.id === "confirm") {
        const e = popup.currentEntry();
        if (e) {
          popup.execute(e.cmd);
          popup.closeSession();
        }
      } else {
        popup.confirmId = "";
        popup.sel = 0;
      }
    }
  }

  function moveSel(delta) {
    const len = popup.currentList().length;
    if (len === 0) return;
    popup.sel = (popup.sel + delta + len) % len;
  }

  Timer {
    id: resetOnClose
    interval: Zenon.slow + 60   // just past the fade-out
    onTriggered: {
      if (popup.shown) return;
      popup.confirmId = "";
      popup.sel = 0;
    }
  }

  Timer {
    id: focusRetry
    interval: 60
    repeat: true
    onTriggered: {
      if (!popup.shown) {
        stop();
        return;
      }
      content.forceActiveFocus();
      if (content.activeFocus) stop();
      if (focusRetry.counter++ > 12) stop();
    }
    property int counter: 0
  }

  MouseArea {
    id: closeArea
    anchors.fill: parent
    onClicked: popup.closeSession()
  }

  Item {
    id: panel
    // Morphed, erebus IS the pill, so it takes the pill's live animated width
    // rather than its own fixed one. At a constant 250 the opaque red panel
    // appeared at its final size over a pill still easing down from morpheus'
    // full width — the single most visible seam in the whole morph.
    width: (popup.morphMode && popup.statusbar && popup.statusbar.width > 0)
      ? popup.statusbar.width : 250
    // Morphed, width already IS the pill's easing width — a Behavior on top
    // would be a second easing chasing an easing source. Standalone there is
    // no pill to follow and the width never changes, so none is needed.
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Zenon.bottomLift(popup.morphMode, popup.screen, popup.statusbar)
    // and the pill's live height for the same reason: shell.qml eases the pill
    // from the collapsed bar height up to calcHeight(), and a panel that was
    // already at its final height sat proud of the pill for that whole ease.
    height: (popup.morphMode && popup.statusbar && popup.statusbar.height > 0)
      ? popup.statusbar.height : popup.calcHeight()
    // standalone only — morphed, height already IS the pill's easing height
    Behavior on height {
      enabled: !popup.morphMode
      NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease }
    }

    // ClippingRectangle, not Rectangle + clip: true. Qt's own clip is
    // RECTANGULAR — it clips to the bounding box and knows nothing about the
    // radius — so every square child painted to the panel's edge (the bottom
    // strip most visibly) filled in the rounded corners behind it. This one
    // clips to the rounded shape itself.
    ClippingRectangle {
      id: bg
      anchors.fill: parent
      // Grown by its own border: a ClippingRectangle insets its children by
      // border.width on every side, so the content box came out 2px smaller
      // than the panel and any layout measured against the panel's size fell
      // one row or one column short. This hands the content its full box back.
      anchors.margins: -bg.border.width
      color: popup.accent
      radius: popup.outerRadius
      border.width: 0

      opacity: popup.morphMode ? 1 : popup.showFactor
      // Runner's slide-up, adopted: standalone entrance is a fade plus a
      // slide from bg.height, morphed the pill has already travelled so
      // no second slide — the panel IS the pill.
      transform: Translate {
        y: popup.morphMode ? 0 : bg.height * (1 - popup.showFactor)
      }

      Item {
        id: content
        anchors.fill: parent
        clip: true
        focus: true
        Keys.forwardTo: content
        opacity: popup.morphMode ? popup.contentFade : 1

        Item {
          id: mainView
          anchors.fill: parent
          visible: opacity > 0.01
          opacity: popup.confirmId === "" ? 1 : 0
          x: popup.confirmId === "" ? 0 : -12
          Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
          Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

          Grid {
            anchors.centerIn: parent
            columns: 5
            columnSpacing: 0
            rowSpacing: 0
            Repeater {
              model: popup.entries
              delegate: Item {
                required property var modelData
                required property int index
                width: 50
                height: 36

                readonly property bool selected: popup.confirmId === "" && index === popup.sel

                Rectangle {
                  anchors.fill: parent
                  anchors.topMargin: popup.edgeInset
                  anchors.bottomMargin: popup.edgeInset
                  anchors.leftMargin: index === 0 ? popup.edgeInset : 0
                  anchors.rightMargin: index === popup.lastEntry ? popup.edgeInset : 0
                  // Snapped, not eased. A colour Behavior here crossfaded the
                  // outgoing cell against the incoming one, so for the length
                  // of the animation TWO cells were partly lit and the
                  // highlight smeared sideways instead of moving. Runner has
                  // never eased this, which is why it reads as crisp.
                  color: parent.selected ? popup.selBg : "transparent"
                  radius: 0
                  topLeftRadius: index === 0 ? popup.innerCorner : 0
                  topRightRadius: index === popup.lastEntry ? popup.innerCorner : 0
                  bottomLeftRadius: index === 0 ? popup.innerCorner : 0
                  bottomRightRadius: index === popup.lastEntry ? popup.innerCorner : 0
                }

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: parent.selected ? popup.ink : popup.idleGlyph
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.weight: Font.Bold
                  font.pixelSize: 18
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    popup.sel = index;
                    popup.confirm();
                  }
                }
              }
            }
          }
        }

        Column {
          id: confirmView
          anchors.fill: parent
          visible: opacity > 0.01
          opacity: popup.confirmId !== "" ? 1 : 0
          x: popup.confirmId !== "" ? 0 : 12
          Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
          Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

          Rectangle {
            width: parent.width + 2
            height: 37
            x: -1
            y: -1
            color: popup.ink
            // Square along the bottom: the action row butts straight up
            // against this, so rounding here cut two notches into the seam
            // between them rather than following any edge of the panel.
            radius: 0
            topLeftRadius: popup.outerRadius
            topRightRadius: popup.outerRadius
            clip: true
            Text {
              anchors.centerIn: parent
              text: {
                const e = popup.currentEntry();
                return e ? e.label : "";
              }
              color: popup.accent
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: Font.Bold
              font.pixelSize: 18
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }
          }

          Row {
            width: parent.width
            height: 36
            Repeater {
              model: popup.confirmActions
              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width / 2
                height: parent.height

                Rectangle {
                  anchors.fill: parent
                  anchors.bottomMargin: popup.edgeInset
                  anchors.leftMargin: index === 0 ? popup.edgeInset : 0
                  anchors.rightMargin: index === 1 ? popup.edgeInset : 0
                  color: index === popup.sel ? popup.selBg : "transparent"
                  radius: 0
                  bottomLeftRadius: index === 0 ? popup.innerCorner : 0
                  bottomRightRadius: index === 1 ? popup.innerCorner : 0
                }

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: index === popup.sel ? popup.ink : popup.idleGlyph
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.weight: Font.Bold
                  font.pixelSize: 18
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    popup.sel = index;
                    popup.confirm();
                  }
                }
              }
            }
          }
        }

        Keys.onEscapePressed: (event) => {
          event.accepted = true;
          if (popup.confirmId !== "") {
            popup.confirmId = "";
            popup.sel = 0;
          } else {
            popup.closeSession();
          }
        }
        Keys.onReturnPressed: (event) => {
          event.accepted = true;
          popup.confirm();
        }
        Keys.onLeftPressed: popup.moveSel(-1)
        Keys.onRightPressed: popup.moveSel(1)
        Keys.onTabPressed: popup.moveSel(1)
        Keys.onBacktabPressed: popup.moveSel(-1)
        Keys.onUpPressed: popup.moveSel(-1)
        Keys.onDownPressed: popup.moveSel(1)
      }
    }
  }
}
