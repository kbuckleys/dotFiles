// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// GLOW — a soft radial bloom to sit behind something that is lit.
//
// It is a solid shape, blurred, inside a wrapper deliberately larger than it.
// Both halves are load-bearing, and both were learned the hard way:
//
//   - Blur the LIT THING and you get nothing. A glyph or a meter segment is
//     thin; spread its ink over a 48px blur and it dilutes to invisibility.
//     The light has to come from a solid shape with area to give.
//   - A layer's texture is exactly the item's bounds, so blurring a shape that
//     fills its own item just clips the bloom off at the edge. The wrapper is
//     the room the light is allowed to spread into — which is also why
//     MultiEffect's shadowScale never worked here: scaling a shadow past the
//     bounds it is drawn in only crops it.
//
// Size the wrapper to the spread you want, not to the thing you are lighting.
// A square wrapper blooms as a circle; a tall or wide one blooms as a capsule,
// which is what a meter wants.

import QtQuick
import QtQuick.Effects
import "."

Item {
  id: root

  property color ink: Zenon.white
  // The light source's own size. Give it the SHAPE of the thing being lit —
  // a square source blooms as a circle, a tall thin one as a vertical capsule.
  // Getting this wrong is why a 6x17 meter first bloomed as a disc: the
  // wrapper was near-square, so the source was too.
  property real sourceW: root.width * 0.30
  property real sourceH: root.height * 0.30
  // how far the blur carries
  property int soft: 32

  layer.enabled: true
  layer.effect: MultiEffect {
    blurEnabled: true
    blur: 1.0
    blurMax: root.soft
  }

  Rectangle {
    anchors.centerIn: parent
    width: root.sourceW
    height: root.sourceH
    radius: Math.min(width, height) / 2
    color: root.ink
  }
}
