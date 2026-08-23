// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// HEIMDALLR — the session lock, in place of hyprlock. Every value below came
// from ~/.config/hypr/hyprlock.conf, quoted beside the property it became.
//
// The lock lives inside the running shell rather than in a process of its
// own, so `locked` is just a property. That also means the escape hatch is
// `qs ipc call Heimdallr unlock` from a VT — which already costs an
// authenticated login, so it gives a physical attacker nothing they did not
// already have, and it is the difference between a bad night and a lost
// session if PAM ever breaks under you.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam

Scope {
  id: root

  // ── hyprlock.conf, ported ────────────────────────────────────────────
  //   $font = JetBrainsMono Nerd Font Mono Medium
  readonly property string fontFamily: "JetBrainsMono Nerd Font Mono"
  readonly property int fontWeight: Font.Medium
  //   $monitor = DP-1 — the input field and both labels named this monitor;
  //   every other output gets background only.
  readonly property string widgetMonitor: "DP-1"
  //   general { hide_cursor = true }
  readonly property bool hideCursor: true

  //   background { color = rgba(0,0,0,0.6), blur_size = 12, blur_passes = 5 }
  readonly property real shadeAlpha: 0.6
  //   blur_size 12 over 5 passes is an enormous blur — the result is colour
  //   smears with no legible text left. Qt's MultiEffect could not reach it:
  //   its radius caps at 64px, which across a 2560px output still left text
  //   readable, which on a lock screen is the entire point missed. So the
  //   blur happens once at capture instead of every frame on the GPU —
  //   downsample, blur, upsample, which is what those five passes are.
  readonly property string blurPipeline: "-resize 10% -blur 0x6 -resize 1000%"

  //   input-field { font_color / check_color / fail_color = rgba(223,223,221,1) }
  readonly property color fg: "#dfdfdd"
  //   the date label's own colour = rgba(160,160,155,1)
  readonly property color dateFg: "#a0a09b"
  //   input-field { size = 20%, 10%; outline_thickness = 0; inner_color = transparent }
  readonly property real fieldWidthFrac: 0.20
  readonly property real fieldHeightFrac: 0.10
  //   dots_size = 0.2, dots_spacing = 0.4 — both relative to the field height
  readonly property real dotsSize: 0.2
  readonly property real dotsSpacing: 0.4
  //   placeholder_text — the lock, shown while the field is empty. Read as a
  //   blank value the first time round because the terminal could not draw it;
  //   it is the same U+F456 erebus wears on its own lock button.
  readonly property string placeholderGlyph: "\uF456"
  //   fade_on_empty = false: an empty field keeps the placeholder rather than
  //   fading itself out, so there is always something on screen to aim at.
  readonly property bool fadeOnEmpty: false
  //   dots_text_format / check_text / fail_text. \u{...} form for the two
  //   above the BMP: the four-digit escape would read U+F09DE as U+F09D + "E".
  readonly property string dotGlyph: "\u{F09DE}"
  readonly property string checkGlyph: "\u{F051B}"
  readonly property string failGlyph: "\uF00D"

  //   label { text = $TIME, font_size = 16, position = 0,47, valign = bottom }
  readonly property int clockSize: 16
  readonly property int clockBottom: 47
  //   label { date, font_size = 12, position = 0,25, valign = bottom }
  readonly property int dateSize: 12
  readonly property int dateBottom: 25

  // ── state ────────────────────────────────────────────────────────────
  // One password buffer for the whole lock, not one per surface: every
  // output carries a key handler so typing works wherever the compositor
  // happens to have put focus, and they must all be filling the same field.
  property string pw: ""
  // "input" | "checking" | "fail"
  property string phase: "input"

  // sloth watches this to know when it can let a suspend proceed
  readonly property alias locked: sessionLock.locked

  readonly property string shotDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/heimdallr"

  // The monitor hyprlock named may not be plugged in. Falling back to the
  // first screen rather than rendering no input field anywhere, which would
  // be a locked session with nothing to type into.
  readonly property string effectiveWidgetMonitor: {
    const screens = Quickshell.screens;
    for (let i = 0; i < screens.length; ++i)
      if (screens[i].name === root.widgetMonitor) return root.widgetMonitor;
    return screens.length > 0 ? screens[0].name : root.widgetMonitor;
  }

  function submit() {
    if (root.phase === "checking") return;
    root.phase = "checking";
    if (!pam.start()) {
      // the stack would not even load; do not sit on a spinner forever
      root.phase = "fail";
      failReset.restart();
    }
  }

  function clearPassword() {
    root.pw = "";
  }

  PamContext {
    id: pam
    // hyprlock's own /etc/pam.d/hyprlock was a one-liner including this same
    // stack, and it went away with the package
    config: "system-auth"

    onPamMessage: {
      if (pam.responseRequired) pam.respond(root.pw);
    }

    onCompleted: (result) => {
      if (result === PamResult.Success) {
        root.clearPassword();
        root.phase = "input";
        sessionLock.locked = false;
        wipeProc.running = true;
        return;
      }
      root.clearPassword();
      root.phase = "fail";
      failReset.restart();
    }

    onError: (err) => {
      root.clearPassword();
      root.phase = "fail";
      failReset.restart();
    }
  }

  Timer {
    id: failReset
    // long enough to read the cross, short enough not to feel punitive
    interval: 1400
    onTriggered: if (root.phase === "fail") root.phase = "input";
  }

  // ── the shot behind the blur ─────────────────────────────────────────
  //   background { path = screenshot }
  // Captured BEFORE the lock surfaces map — a capture taken afterwards would
  // photograph the lock itself. Written to XDG_RUNTIME_DIR, which is tmpfs and
  // mode 700, and wiped on unlock.

  // Stage one: the raw grab. Must finish BEFORE the lock surfaces map, or it
  // photographs the lock instead of the desktop. ~250ms for two outputs.
  Process {
    id: shotProc
    onExited: {
      lockDelay.stop();
      sessionLock.locked = true;
      blurProc.running = true;
    }
  }

  // Stage two: the blur, which costs the better part of a second per output.
  // Deliberately AFTER the lock is up rather than before it — nothing slow
  // belongs between you and a locked screen. The surfaces are opaque black
  // until this lands, so nothing shows through in the meantime.
  Process {
    id: blurProc
    onExited: root.shotReady = true
  }

  Process {
    id: wipeProc
    command: ["sh", "-c", "rm -f " + root.shotDir + "/*.png " + root.shotDir + "/*.raw.png"]
  }

  // the blurred shot only exists once stage two has finished; until then the
  // Image must not be pointed at a file that is not there, or it latches on
  // an error and never retries
  property bool shotReady: false

  Timer {
    id: lockDelay
    // A screenshot must never be what stands between you and a locked
    // screen. If grim has not finished by now, lock without one.
    interval: 700
    onTriggered: sessionLock.locked = true
  }

  function lock() {
    if (sessionLock.locked) return;
    root.pw = "";
    root.phase = "input";
    root.shotReady = false;
    const screens = Quickshell.screens;
    let grab = "mkdir -p '" + root.shotDir + "'";
    let blur = "";
    for (let i = 0; i < screens.length; ++i) {
      const n = screens[i].name;
      const raw = root.shotDir + "/" + n + ".raw.png";
      const out = root.shotDir + "/" + n + ".png";
      grab += "; grim -o '" + n + "' '" + raw + "' 2>/dev/null";
      blur += (blur === "" ? "" : "; ") + "magick '" + raw + "' "
        + root.blurPipeline + " '" + out + "' 2>/dev/null";
      blur += "; rm -f '" + raw + "'";
    }
    shotProc.command = ["sh", "-c", grab];
    blurProc.command = ["sh", "-c", blur === "" ? "true" : blur];
    shotProc.running = true;
    lockDelay.restart();
  }

  IpcHandler {
    target: "Heimdallr"

    function lock(): string { root.lock(); return "locking"; }
    // the escape hatch described at the top of this file
    function unlock(): string {
      sessionLock.locked = false;
      root.clearPassword();
      wipeProc.running = true;
      return "unlocked";
    }
    function status(): string {
      return "locked=" + sessionLock.locked + " secure=" + sessionLock.secure
        + " phase=" + root.phase;
    }
  }

  // ── the lock itself ──────────────────────────────────────────────────

  WlSessionLock {
    id: sessionLock

    surface: WlSessionLockSurface {
      id: surf
      // an opaque floor, so a missing or slow screenshot can never leave the
      // desktop showing through
      color: "black"

      readonly property bool showsWidgets:
        surf.screen && surf.screen.name === root.effectiveWidgetMonitor

      Image {
        id: shot
        anchors.fill: parent
        source: (root.shotReady && surf.screen)
          ? "file://" + root.shotDir + "/" + surf.screen.name + ".png" : ""
        fillMode: Image.PreserveAspectCrop
        cache: false
        // it arrives a beat after the lock does; fading is kinder than a snap
        opacity: shot.status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
      }

      //   background { color = rgba(0,0,0,0.6) } — over the blur, not instead
      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, root.shadeAlpha)
      }

      //   general { hide_cursor = true }
      MouseArea {
        anchors.fill: parent
        cursorShape: root.hideCursor ? Qt.BlankCursor : Qt.ArrowCursor
        acceptedButtons: Qt.NoButton
      }

      // Every surface takes keys, not just the one with the widgets: the
      // compositor decides which output has focus, and typing into a blank
      // one must still reach the field.
      Item {
        anchors.fill: parent
        focus: true

        Keys.onPressed: (event) => {
          event.accepted = true;
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.submit();
          } else if (event.key === Qt.Key_Backspace) {
            if (root.pw.length > 0) {
              const chars = Array.from(root.pw);
              chars.pop();
              root.pw = chars.join("");
            }
          } else if (event.key === Qt.Key_Escape) {
            root.clearPassword();
          } else if (event.text && event.text.length > 0 &&
                     !(event.modifiers & Qt.ControlModifier) &&
                     !(event.modifiers & Qt.MetaModifier)) {
            if (root.phase !== "checking") root.pw += event.text;
          }
        }
      }

      // ── the widgets, on $monitor only ──────────────────────────────
      Item {
        id: field
        visible: surf.showsWidgets
        anchors.centerIn: parent
        //   input-field { size = 20%, 10% }
        width: surf.width * root.fieldWidthFrac
        height: surf.height * root.fieldHeightFrac

        //   outline_thickness = 0, inner_color = rgba(0,0,0,0): the field
        //   itself paints nothing at all — only what is in it.

        Text {
          id: state
          anchors.centerIn: parent
          visible: root.phase !== "input"
          //   check_text / fail_text
          text: root.phase === "checking" ? root.checkGlyph : root.failGlyph
          color: root.fg
          font.family: root.fontFamily
          font.weight: root.fontWeight
          font.pixelSize: field.height * 0.5
        }

        //   placeholder_text — only while there is nothing typed yet
        Text {
          anchors.centerIn: parent
          visible: root.phase === "input" && root.pw.length === 0
          text: root.placeholderGlyph
          color: root.fg
          opacity: root.fadeOnEmpty ? 0 : 1
          font.family: root.fontFamily
          font.weight: root.fontWeight
          // the same size the check and fail glyphs use; all three are the
          // one symbol standing in the middle of the field
          font.pixelSize: field.height * 0.5
        }

        Row {
          anchors.centerIn: parent
          visible: root.phase === "input" && root.pw.length > 0
          //   dots_spacing = 0.4, relative to the dot size
          spacing: field.height * root.dotsSize * root.dotsSpacing

          Repeater {
            model: root.pw.length
            delegate: Text {
              //   dots_text_format
              text: root.dotGlyph
              color: root.fg
              font.family: root.fontFamily
              font.weight: root.fontWeight
              //   dots_size = 0.2 of the field height
              font.pixelSize: field.height * root.dotsSize
            }
          }
        }
      }

      //   label { text = $TIME, position = 0,47, valign = bottom }
      Text {
        visible: surf.showsWidgets
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.clockBottom
        text: Qt.formatDateTime(clock.date, "HH:mm")
        color: root.fg
        font.family: root.fontFamily
        font.weight: root.fontWeight
        font.pointSize: root.clockSize
      }

      //   label { cmd[update:60000] date +"%A, %d %B %Y", position = 0,25 }
      //   A SystemClock rather than a subprocess on a timer — same string,
      //   same one-minute cadence, no shell.
      Text {
        visible: surf.showsWidgets
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.dateBottom
        text: Qt.formatDateTime(clock.date, "dddd, dd MMMM yyyy")
        color: root.dateFg
        font.family: root.fontFamily
        font.weight: root.fontWeight
        font.pointSize: root.dateSize
      }
    }
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    enabled: true
  }
}
