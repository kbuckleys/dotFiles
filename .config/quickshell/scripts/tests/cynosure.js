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
      { name: "htop", exec: "htop", id: "htop", icon: "" },
      { name: "firefox", exec: "firefox %u", id: "firefox", icon: "" }
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

    // gio launch, NOT gtk-launch: gtk-launch runs the Exec line and nothing
    // else, so a Terminal=true entry died the moment it started. This is the
    // regression that check exists to catch.
    // BY THE BARE ID, because that is what DesktopEntries hands back: `htop`,
    // `discord`, `org.kde.okular` — quickshell never puts the `.desktop` on
    // the end. Every path built below is gated on `[ -f ]`, so an id used raw
    // matches no file, every directory is skipped, the loop falls through to
    // `exit 1`, and the caller's >/dev/null swallows it. That is a launcher
    // that launches nothing at all, in total silence. Asserted with the bare
    // id precisely because the fixture used to carry a suffix of its own and
    // so agreed with a bug the real DesktopEntries would never have allowed.
    const launch = C.launchAppCommand("htop");
    t.has("the id is resolved to a real file name", launch, "htop.desktop");
    t.ok("and not left bare, which would match nothing",
      launch.indexOf("\"htop\"") === -1 && launch.indexOf("'htop'") === -1);
    t.has("an app is launched with gio, which honours Terminal=true",
      launch, "gio launch");
    t.ok("gtk-launch is gone", launch.indexOf("gtk-launch") === -1);
    t.has("through the XDG search path", launch, "XDG_DATA_DIRS");
    t.has("starting with the user's own", launch, "XDG_DATA_HOME");
    // A stale user override must not be the end of the search: it stops at the
    // first entry that LAUNCHES, not the first that exists.
    t.has("it keeps trying until one launches", launch, "&& exit 0");
    t.has("and reports failure when none does", launch, "exit 1");
    t.ok("every candidate is tried, not just the first",
      launch.indexOf("for d in") === 0);
    // terminus already holds a file name, having read one off a directory.
    // Appending unconditionally would send it looking for htop.desktop.desktop.
    t.ok("an id that is already a file name is left alone",
      C.launchAppCommand("htop.desktop").indexOf("htop.desktop.desktop") === -1);

    // ── markup ────────────────────────────────────────────────────────────
    // The rows are StyledText, so a name with an ampersand in it must not
    // become half a markup entity.
    t.eq("an ampersand is escaped", C.escMarkup("a & b"), "a &amp; b");
    t.eq("the match is underlined where it matched",
      C.highlight("firefox", "fire"), "<u>fire</u>fox");
    t.eq("no query means no markup", C.highlight("firefox", ""), "firefox");
  }
};
