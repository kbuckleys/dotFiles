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

  readonly property color sparkFill: "#339bbfbf"
  // Hover tint for menu rows. A light scrim rather than a fill: on a dark
  // translucent panel a *darker* overlay reads as a shadow, and an opaque one
  // punches a sharp unblurred block into an otherwise blurred surface. At this
  // alpha the row composites to ~0.56 over panelBg — above hyprland's
  // ignore_alpha 0.5, so the blur still carries, and the backdrop shows through.
  readonly property color hoverTint: Qt.rgba(1, 1, 1, 0.12)

  // ── spacing ──────────────────────────────────────────────────────────
  // Three values, and only three. padModule is a module's own breathing room,
  // gap is the space between two neighbours, padBar is the pill's end caps.
  // A Divider carries a gap on each side itself, so it never needs spacers.
  readonly property int padModule: 4
  readonly property int gap:       8
  readonly property int padBar:    12

  // ── motion ──
  // Shared timings and curve, so every module and every layer eases
  // identically. OutQuint rather than OutCubic: it puts more
  // of the travel in the first third and lands softer, so the same move reads
  // as both quicker off the mark and gentler on arrival.
  readonly property int fast:   110
  readonly property int normal: 140
  readonly property int slow:   170
  readonly property int ease:   Easing.OutQuint

  // unlit meter notch: the accent dimmed and mostly transparent, so a meter
  // reads as one colour whether its segments are lit or not
  function trough(c) {
    return Qt.rgba(c.r * 0.32, c.g * 0.32, c.b * 0.32, 0.125);
  }

  // 6-digit hex for markup that needs a string (StyledText <font color=...>);
  // QML's color->string gives #AARRGGBB, which Qt's rich text won't parse
  function hex(c) {
    const b = (v) => Math.round(v * 255).toString(16).padStart(2, "0");
    return "#" + b(c.r) + b(c.g) + b(c.b);
  }
}
