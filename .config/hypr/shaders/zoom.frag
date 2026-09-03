// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// Magnification filter for the cursor zoom, mirroring how KWin's zoom effect
// splits its two shaders: a pixel grid at and above PixelGridZoom, an upscaler
// below it. Derivatives give us the live zoom factor, so this picks its own
// branch and needs nothing from the Lua side.
//
// Below the grid threshold this is sharp bilinear rather than KWin's xBRZ:
// nearest-neighbour blocks with a one-output-pixel ramp along texel seams, so
// text keeps hard edges without the staircase that plain nearest leaves.
//
// A no-op at 1x in both branches -- the output pixel grid lines up with the
// source texels, so an unzoomed monitor passes through untouched.

#extension GL_OES_standard_derivatives : enable

precision highp float;

varying vec2 v_texcoord;

uniform sampler2D tex;
uniform vec2 screen_size;

const float PIXEL_GRID_ZOOM = 15.0;  // KWin PixelGridZoom

void main() {
    // An unbound uniform reads as 0, which would put every fragment on a grid
    // line and paint the whole output black with no error. Pass through instead.
    if (screen_size.x <= 0.0 || screen_size.y <= 0.0) {
        gl_FragColor = texture2D(tex, v_texcoord);
        return;
    }

    vec2 p = v_texcoord * screen_size;   // position in source texels
    vec2 w = max(fwidth(p), vec2(1e-6)); // source texels per output pixel = 1/zoom

    if (1.0 / max(w.x, w.y) >= PIXEL_GRID_ZOOM) {
        // Port of KWin's shaders/pixelgrid.frag.
        vec2  center = floor(p) + 0.5;
        vec2  d      = abs(p - center);
        float t      = smoothstep(0.4, 0.5, max(d.x, d.y));

        gl_FragColor = mix(texture2D(tex, center / screen_size), vec4(0.0, 0.0, 0.0, 1.0), t);
        return;
    }

    // Sharp bilinear. Snap to the texel centre everywhere except within half an
    // output pixel of a seam, where we let the linear filter blend across it.
    vec2 fl    = floor(p);
    vec2 dist  = (p - fl) - 0.5;
    vec2 range = max(0.5 - 0.5 * w, vec2(0.0));
    vec2 f     = (dist - clamp(dist, -range, range)) / w + 0.5;

    gl_FragColor = texture2D(tex, (fl + f) / screen_size);
}
