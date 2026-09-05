// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// The pure half of cynosure: the frecency ranking, the history file, and the
// desktop-entry field codes. The launcher is one text field over these, so
// when the ranking is right the launcher is very nearly right.
//
// The paths are checked too, because they are the one thing a rename breaks
// silently — a launcher that writes its history somewhere new simply looks
// like a launcher that forgot.

"use strict";

module.exports = {
  module: "cynosure/cynosure.js",
  cases: (C, t) => {
    // ── state paths ───────────────────────────────────────────────────────
    t.eq("history lives under the cache dir",
      C.histPath(), "/home/test/.cache/cynosure-history");
    t.eq("frecency lives beside it",
      C.freqPath(), "/home/test/.cache/cynosure-freq");

    // ── history ───────────────────────────────────────────────────────────
    t.eq("blank lines are dropped", C.parseHistory("a\n\n b \n").length, 2);
    t.eq("empty history is empty", C.parseHistory("").length, 0);
    t.eq("null history is empty", C.parseHistory(null).length, 0);

    const H = C.addHistory([], "htop", "Process", C.ICON_P);
    t.eq("a run is remembered", H.length, 1);
    t.has("the mode's glyph is on the line", H[0], C.ICON_P);
    const H2 = C.addHistory(H, "htop", "Process", C.ICON_P);
    t.eq("running it again does not duplicate it", H2.length, 1);
    t.eq("deleting a line removes it",
      C.deleteHistoryLine(H2, H2[0]).length, 0);

    // ── frecency ──────────────────────────────────────────────────────────
    let f = {};
    f = C.bumpFreq(f, "firefox");
    f = C.bumpFreq(f, "firefox");
    f = C.bumpFreq(f, "htop");
    t.eq("counts accumulate", f["firefox"], 2);
    t.eq("a first run counts once", f["htop"], 1);
    t.eq("an empty key is ignored",
      Object.keys(C.bumpFreq({}, "")).length, 0);

    // The whole point of the frecency file: what you run most is on top.
    const apps = [
      { name: "htop", exec: "htop", id: "htop.desktop", icon: "" },
      { name: "firefox", exec: "firefox %u", id: "firefox.desktop", icon: "" }
    ];
    const rows = C.buildRows(apps, [], f);
    t.eq("the most-run app is first", rows[0].key, "firefox");

    // A history line that names an app already in the list would show the
    // same thing twice, one row apart.
    const dupe = C.buildRows(apps, [C.ICON_T + " firefox"], f);
    t.eq("history does not duplicate an app",
      dupe.filter((r) => r.key.toLowerCase() === "firefox").length, 1);

    // ── desktop entries ───────────────────────────────────────────────────
    // Field codes are the launcher's job to strip: %u is for a caller with a
    // URL to pass, and there isn't one here.
    t.eq("a url placeholder is dropped",
      C.stripFieldCodes("firefox %u"), "firefox");
    t.eq("a file placeholder is dropped",
      C.stripFieldCodes("gimp %F"), "gimp");
    t.eq("several are dropped",
      C.stripFieldCodes("app %f %i %c"), "app");
    t.eq("a plain command is untouched",
      C.stripFieldCodes("htop"), "htop");
    // %% is a literal percent and not a field code, and neither is a bare %.
    t.eq("an ordinary argument survives",
      C.stripFieldCodes("sh -c 'x 100%'"), "sh -c 'x 100%'");

    // ── filtering ─────────────────────────────────────────────────────────
    const all = C.buildRows(apps, [], {});
    t.eq("a query narrows the list",
      C.filterRows(all, "fire").length, 1);
    t.eq("an empty query keeps everything",
      C.filterRows(all, "").length, all.length);
    t.eq("a query matching nothing gives nothing",
      C.filterRows(all, "zzzzz").length, 0);

    // ── commands ──────────────────────────────────────────────────────────
    // The terminal has to be footclient by name: xdg-terminal-exec drops
    // --hold unless the desktop entry declares TerminalArgHold, and foot's
    // does not — which is what made every terminal launch close instantly.
    const term = C.terminalCommand("duf");
    t.has("footclient is called directly", term, "footclient");
    t.has("the window is held open", term, "--hold");
    t.has("the title matches the hyprland rule", term, "--title=cynosure");
    t.has("there is a fallback for other machines", term, "xdg-terminal-exec");

    // gtk-launch takes a desktop-entry id and runs it the way the entry says
    // to, Terminal=true included — which is the whole reason an .desktop id is
    // carried this far instead of just its Exec line.
    t.has("an app is launched through its desktop entry",
      C.launchAppCommand("htop.desktop"), "gtk-launch");

    // ── markup ────────────────────────────────────────────────────────────
    // The rows are StyledText, so a name with an ampersand in it must not
    // become half a markup entity.
    t.eq("an ampersand is escaped", C.escMarkup("a & b"), "a &amp; b");
    t.eq("the match is underlined where it matched",
      C.highlight("firefox", "fire"), "<u>fire</u>fox");
    t.eq("no query means no markup", C.highlight("firefox", ""), "firefox");
  }
};
