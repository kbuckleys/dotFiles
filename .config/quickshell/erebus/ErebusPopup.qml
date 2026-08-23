// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell
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
  // Morphed, erebus fades in on the pill's clock rather than its own, and only
  // once the morpheus row has finished clearing.
  readonly property real contentFade: popup.morphMode ? popup.morphFade : (popup.shown ? 1 : 0)
  property string confirmId: ""
  property int sel: 0

  readonly property string xdgSession: Quickshell.env("XDG_SESSION_ID") || ""

  property var entries: [
    { id: "lockscreen", label: "", cmd: "hyprlock", confirm: false },
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
  readonly property color accent: "#e78284"
  readonly property color selBg: "#eebebe"
  readonly property color ink: "#000000"
  readonly property color idleGlyph: popup.ink
  // morphed, the panel has to cover the pill's own rounding and 1px border
  // exactly, or they peek out around erebus' corners
  readonly property real outerRadius: popup.morphMode ? 12 : 6
  readonly property real outerRadiusLow: popup.morphMode ? 12 : 10

  // shell.qml sizes the morphed pill from this. The confirm step doubles the
  // panel's height, so a fixed number here leaves the confirm row hanging
  // outside the pill background.
  function calcHeight() {
    return popup.confirmId === "" ? 36 : 72;
  }

  visible: bg.opacity > 0.01 || popup.contentFade > 0.01
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
    width: 250
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: popup.morphMode ? 6 : (popup.screen && popup.statusbar && popup.statusbar.screen && popup.screen.name === popup.statusbar.screen.name ? popup.statusbar.height : 0)
    height: popup.calcHeight()
    // Zenon.slow is the pill's own height easing in shell.qml
    Behavior on height { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }

    Rectangle {
      id: bg
      anchors.fill: parent
      color: popup.accent
      radius: 6
      topLeftRadius: popup.outerRadius
      topRightRadius: popup.outerRadius
      bottomLeftRadius: popup.outerRadiusLow
      bottomRightRadius: popup.outerRadiusLow
      border.width: 0
      clip: true

      opacity: popup.contentFade
      // the slide-up is the standalone entrance. Morphed, the pill has
      // already travelled that distance, so a second slide reads as the panel
      // detaching from the pill it is supposed to BE.
      Behavior on opacity {
        enabled: !popup.morphMode
        NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease }
      }
      transform: Translate {
        y: (popup.morphMode || popup.shown) ? 0 : bg.height
        Behavior on y { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }
      }

      Item {
        id: content
        anchors.fill: parent
        clip: true
        focus: true
        Keys.forwardTo: content

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
                  color: parent.selected ? popup.selBg : "transparent"
                  radius: 6
                  topLeftRadius: index === 0 ? popup.outerRadius : 0
                  topRightRadius: index === 4 ? popup.outerRadius : 0
                  bottomLeftRadius: index === 0 ? popup.outerRadiusLow : 10
                  bottomRightRadius: index === 4 ? popup.outerRadiusLow : 10
                  Behavior on color { ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
                }

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: parent.selected ? popup.ink : popup.idleGlyph
                  Behavior on color { ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
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
            radius: 6
            topLeftRadius: popup.outerRadius
            topRightRadius: popup.outerRadius
            bottomLeftRadius: 10
            bottomRightRadius: 10
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
                  color: index === popup.sel ? popup.selBg : "transparent"
                  radius: 0
                  bottomLeftRadius: index === 0 ? popup.outerRadiusLow : 0
                  bottomRightRadius: index === 1 ? popup.outerRadiusLow : 0
                  Behavior on color { ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
                }

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: index === popup.sel ? popup.ink : popup.idleGlyph
                  Behavior on color { ColorAnimation { duration: Zenon.fast; easing.type: Zenon.ease } }
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
