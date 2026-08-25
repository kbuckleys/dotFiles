// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
// ZENON palette — single source of truth, mirrors ~/.config/nvim/lua/zenon.lua

pragma Singleton

import QtQuick

QtObject {
  // base
  readonly property color black:   "#000000"
  readonly property color surface: "#20242a"   // lblack
  readonly property color white:   "#dfdfdd"
  readonly property color muted:   "#6a707f"   // bright_black

  // accents
  readonly property color red:     "#e78284"
  readonly property color green:   "#b6e0a4"
  readonly property color yellow:  "#fab387"
  readonly property color blue:    "#9fcbfc"
  readonly property color magenta: "#c8a4e0"
  readonly property color cyan:    "#9bbfbf"
  readonly property color pink:    "#eebebe"   // bright_red
  readonly property color sand:    "#e0d8a4"   // bright_yellow

  // derived surfaces — alpha over black so the compositor blur reads through
  readonly property color panelBg:    "#80000000"
  readonly property color panelBgDeep: "#b3000000"
  readonly property color dim:        "#506060"   // muted cyan, inactive workspace

  // Module titles — CPU, GPU, RAM. Deliberately not an accent: the labels are
  // furniture, and the readings are what you look at.
  readonly property color title:      muted

  readonly property color sparkFill: "#339bbfbf"
  // Hover tint for menu rows. A light scrim rather than a fill: on a dark
  // translucent panel a *darker* overlay reads as a shadow, and an opaque one
  // punches a sharp unblurred block into an otherwise blurred surface. At this
  // alpha the row composites to ~0.56 over panelBg — above hyprland's
  // ignore_alpha 0.5, so the blur still carries, and the backdrop shows through.
  readonly property color hoverTint: Qt.rgba(1, 1, 1, 0.12)

  // ── spacing ──────────────────────────────────────────────────────────
  // Four values, and only four. padModule is a module's own breathing room,
  // gap is the space between two neighbours, padBar is the pill's end caps,
  // padScreen is the pill's clearance from the screen edge.
  // A Divider carries a gap on each side itself, so it never needs spacers.
  readonly property int padModule: 4
  readonly property int gap:       8
  readonly property int padBar:    12
  // the clearance the pill keeps from the screen edge. Every layer reuses it,
  // so a layer spawned on a monitor that has no pill still sits exactly where
  // it would have sat morphed into one.
  readonly property int padScreen:  6
  // Every module occupies a slot of this height, and BarText fills it, so a
  // short label beside a taller sibling still sits on the bar's centre line.
  readonly property int slot:      32
  // the bar's type size; every module reads it through BarText
  readonly property int textSize:  18
  // the pill and every layer's corner radius — 8:8, no morph. A single token
  // so the bar, runner, and all other layers stay even without duped literals.
  readonly property int pillRadius: 8

  // ── the clock's face ─────────────────────────────────────────────────
  // A seven-segment LCD, the way an old bedside clock renders. DSEG covers
  // digits, the colon and a rough alphabet, but none of the nerd glyphs the
  // rest of the bar uses — so it is named here rather than set on BarText,
  // and only the clock ever asks for it.
  readonly property string clockFamily: "DSEG7 Classic"
  // Its 14-segment sibling. Same display, but a full ASCII range: DSEG7 has
  // no + * / ( ) = % at all, so anything showing an EXPRESSION rather than a
  // bare number has to wear this one or lose every operator to a fallback.
  readonly property string segmentFamily: "DSEG14 Classic"
  // DSEG's digits stand taller than JetBrains' at the same nominal size, so
  // the clock is set two pixels smaller and still reads level with the rest
  // of the bar. Expressed against textSize rather than written out, so the
  // two cannot drift if the bar's type changes again.
  readonly property int clockSize: textSize - 2

  // ── elevation ────────────────────────────────────────────────────────
  // What a layer's drop shadow is made of. Tuned in one place so the whole
  // set stays consistent — morpheus itself casts none: the pill is the ground
  // floor, and a shadow under it would make the layers it morphs into look
  // like they were peeling off it.
  readonly property color shadowInk:  Qt.rgba(0, 0, 0, 0.55)
  readonly property real  shadowBlur: 28
  // a shadow directly under the panel reads as depth; one offset sideways
  // reads as a light source, which this desktop does not otherwise have
  readonly property real  shadowLift: 6

  // ── motion ──
  // Shared timings and curve, so every module and every layer eases
  // identically. OutQuint rather than OutCubic: it puts more
  // of the travel in the first third and lands softer, so the same move reads
  // as both quicker off the mark and gentler on arrival.
  readonly property int fast:   110
  readonly property int normal: 140
  readonly property int slow:   170
  readonly property int ease:   Easing.OutQuint

  // An item inside a layer-shell surface has window-local coordinates. This
  // is that window's own top-left in screen space, so the two can be added.
  // Written once: every popout that anchors to a bar module needs it, and the
  // one that skipped it landed a side-margin off.
  function winOrigin(w, screen) {
    if (!w || !screen) return Qt.point(0, 0);
    return Qt.point(
      w.anchors.left ? w.margins.left : screen.width - w.margins.right - w.width,
      w.anchors.top ? w.margins.top : screen.height - w.margins.bottom - w.height);
  }

  // How far a layer's bottom edge sits above the screen edge. One definition
  // for every layer, so a layer opened on a monitor that has no pill lands at
  // exactly the height it would have had morphed into one. On the pill's own
  // screen, and not morphed into it, it additionally clears the pill.
  function bottomLift(morphed, screen, statusbar) {
    if (morphed) return padScreen;
    const onPill = screen && statusbar && statusbar.screen
      && screen.name === statusbar.screen.name;
    return padScreen + (onPill ? statusbar.height : 0);
  }

  // Unlit meter notch: the accent dimmed, so a meter reads as one colour
  // whether its segments are lit or not. Kept well clear of the lit segment
  // in both brightness and alpha — but not so faint that the meter's own
  // shape disappears, which is what the first pass at these numbers did.
  function trough(c) {
    return Qt.rgba(c.r * 0.62, c.g * 0.62, c.b * 0.62, 0.42);
  }

  // 6-digit hex for markup that needs a string (StyledText <font color=...>);
  // QML's color->string gives #AARRGGBB, which Qt's rich text won't parse
  function hex(c) {
    const b = (v) => Math.round(v * 255).toString(16).padStart(2, "0");
    return "#" + b(c.r) + b(c.g) + b(c.b);
  }
}
