// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import "."

Item {
  id: root
  implicitWidth: 48
  implicitHeight: 16

  property var values: []
  property color lineColor: Zenon.cyan
  property color fillColor: Zenon.sparkFill
  property real fillOpacity: 0.18
  property int maxPoints: 32
  property real lineWidth: 1.4

  // history is trimmed externally, but also handle here
  readonly property var trimmed: {
    if (!root.values || root.values.length <= root.maxPoints) return root.values;
    return root.values.slice(root.values.length - root.maxPoints);
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    // Painted synchronously rather than on the cooperative queue: the default
    // can put a frame on screen between the clearRect and the redraw, which
    // reads as a blink. These are 160x32, so painting them inline is free.
    renderStrategy: Canvas.Immediate
    onPaint: {
      const ctx = getContext("2d");
      ctx.clearRect(0, 0, width, height);
      const vals = root.trimmed;
      if (!vals || vals.length < 2) return;
      const n = vals.length;
      const w = width;
      const h = height;
      // Scaled to the samples actually held, not to maxPoints. Every module
      // caps its history at 30 while this reserved 32 slots, so the trace was
      // permanently inset by two steps on the left and never reached the right
      // edge — which read as the sparkline sitting off-centre in its tooltip.
      const step = n > 1 ? w / (n - 1) : 0;
      const offset = 0;

      // fill
      ctx.save();
      ctx.beginPath();
      for (let i = 0; i < n; ++i) {
        const x = offset + i * step;
        const y = h - (Math.max(0, Math.min(100, vals[i])) / 100) * h;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
      ctx.lineTo(offset + (n - 1) * step, h);
      ctx.lineTo(offset, h);
      ctx.closePath();
      ctx.fillStyle = root.fillColor;
      ctx.globalAlpha = root.fillOpacity;
      ctx.fill();
      ctx.restore();

      // line
      ctx.beginPath();
      ctx.strokeStyle = root.lineColor;
      ctx.lineWidth = root.lineWidth;
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      for (let i = 0; i < n; ++i) {
        const x = offset + i * step;
        const y = h - (Math.max(0, Math.min(100, vals[i])) / 100) * h;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
      ctx.stroke();
    }
  }

  Connections {
    target: root
    function onValuesChanged() { canvas.requestPaint(); }
    function onLineColorChanged() { canvas.requestPaint(); }
  }
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()
}
