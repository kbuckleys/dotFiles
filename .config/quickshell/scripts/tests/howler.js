// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// The pure half of howler: what a notification is worth keeping, and what has
// to be thrown away before it is written down.
//
// The image rules get most of the attention here because they are the ones
// that fail INVISIBLY and LATE. A row with a dead image reference costs
// nothing when it is saved and everything on the next start, in a warning that
// names a number rather than the notification it came from — so the rule is
// pinned in both directions rather than trusted.

"use strict";

module.exports = {
  module: "howler/howler.js",
  cases: (H, t) => {
    // ── what is safe to write down ────────────────────────────────────────
    // A quickshell provider handle is the case this rule was missing. It is a
    // token for one running instance: the process that could answer it is the
    // process that has just exited, so it is the LEAST durable thing a
    // notification can carry, not an edge case.
    t.ok("a qsimage handle is volatile",
      H.localImage("image://qsimage/13/1"));
    t.ok("so is any other provider url",
      H.localImage("image://icon//discord"));
    t.ok("an absolute path is volatile", H.localImage("/tmp/shot.png"));
    t.ok("so is a file url", H.localImage("file:///tmp/shot.png"));
    // A bare themed name is not a path and not a handle — it is a lookup that
    // works in any session, and it is what a cleaned row falls back to.
    t.ok("a themed icon name is kept", !H.localImage("discord"));
    t.ok("nothing at all is not an image", !H.localImage(""));
    t.ok("and neither is a missing field", !H.localImage(undefined));

    // ── on the way out ────────────────────────────────────────────────────
    const rows = [
      { id: 1, appName: "discord", appIcon: "discord",
        image: "image://qsimage/13/1", summary: "hi" },
      { id: 2, appName: "kitty", appIcon: "/usr/lib/kitty/logo/kitty.png",
        image: "", summary: "done" }
    ];
    const out = JSON.parse(H.serialize(rows));
    t.eq("the handle is not written to disk", out[0].image, "");
    t.eq("but the row itself survives", out[0].summary, "hi");
    t.eq("and its stable fallback is untouched", out[0].appIcon, "discord");
    // appIcon is never inspected — only `image` is. A path there is the row's
    // own icon and is as stable as the application that sent it.
    t.eq("a path in appIcon is left alone",
      out[1].appIcon, "/usr/lib/kitty/logo/kitty.png");

    // ── on the way back in ────────────────────────────────────────────────
    // The same rule, applied again on read, because a history file written
    // before the rule existed still holds the dead handle — and a fix that
    // only runs on write would need the file deleted by hand to take effect.
    const stale = JSON.stringify([
      { id: 1, appName: "discord", appIcon: "discord",
        image: "image://qsimage/13/1", summary: "hi" }
    ]);
    const back = H.parse(stale);
    t.eq("a file that already holds one heals on read", back[0].image, "");
    t.eq("without losing the row", back[0].summary, "hi");
    t.eq("or the icon it can still draw", back[0].appIcon, "discord");

    // ── the parse contract ────────────────────────────────────────────────
    t.eq("empty text is an empty history", H.parse("").length, 0);
    t.eq("so is nonsense", H.parse("{{{").length, 0);
    t.eq("and so is a non-array", H.parse('{"a":1}').length, 0);
  }
};
