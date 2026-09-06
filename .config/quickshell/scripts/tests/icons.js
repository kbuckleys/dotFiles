// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴ ┴└─┘
// https://github.com/kbuckleys/
//
// The glyph table, which is now terminus' own rather than a parse of somebody
// else's theme file — see the note at the top of icons.js. That change is
// exactly why this suite exists: the old arrangement could fail SILENTLY, by
// reading a file that was not there or not shaped the way the parser expected,
// and every file in the window came out as a blank page with nothing said. A
// table in the source cannot go missing, and a count that is asserted cannot
// quietly become zero.

"use strict";

module.exports = {
  module: "morpheus/icons.js",
  cases: (T, t) => {
    // ── precedence ────────────────────────────────────────────────────────
    // The most specific rule wins, which is the whole of the lookup order.
    t.eq("an exact filename beats its extension",
      T.glyphFor({ name: "Cargo.toml" }), T.glyphFor({ name: "main.rs" }));
    t.ok("and that is NOT what a plain .toml gets",
      T.glyphFor({ name: "other.toml" }) !== T.glyphFor({ name: "Cargo.toml" }));
    t.eq("an extension beats the catch-all",
      T.glyphFor({ name: "a.zst" }), T.glyphFor({ name: "b.tar" }));
    t.ok("and something nothing claims falls through to the plain page",
      T.glyphFor({ name: "x.qqzz" }) === T.glyphFor({ name: "y.wwvv" }));

    // A DIRECTORY is matched against the directory rules and never against the
    // extension ones: "src.old" is a folder, not an .old file.
    t.ok("a directory named like an extension is still a directory",
      T.glyphFor({ name: "src.old", isDir: true })
        !== T.glyphFor({ name: "src.old" }));
    t.eq("a directory nothing names gets the plain folder",
      T.glyphFor({ name: "zzqq", isDir: true }),
      T.glyphFor({ name: "wwvv", isDir: true }));

    // ── case ──────────────────────────────────────────────────────────────
    t.eq("MAKEFILE is makefile", T.glyphFor({ name: "MAKEFILE" }),
      T.glyphFor({ name: "makefile" }));
    t.eq("and so is Makefile", T.glyphFor({ name: "Makefile" }),
      T.glyphFor({ name: "makefile" }));
    t.eq("an extension is lowercased too", T.glyphFor({ name: "PHOTO.PNG" }),
      T.glyphFor({ name: "photo.png" }));

    // ── extensionOf ───────────────────────────────────────────────────────
    t.eq("the last dot wins", T.extensionOf("a.tar.gz"), "gz");
    t.eq("a leading dot is a hidden file, not an extension",
      T.extensionOf(".bashrc"), "");
    t.eq("nor is a trailing one", T.extensionOf("weird."), "");
    t.eq("no dot at all", T.extensionOf("Makefile"), "");
    t.eq("and it lowercases", T.extensionOf("IMAGE.PNG"), "png");

    // ── the states a file can be in ───────────────────────────────────────
    // Checked in order: a broken link is reported as broken before anything
    // else gets a say, because that is the fact that matters about it.
    t.ok("a broken link says so",
      T.glyphFor({ name: "a.rs", isLink: true, broken: true })
        !== T.glyphFor({ name: "a.rs" }));
    t.eq("a live link to a known type keeps the type's glyph",
      T.glyphFor({ name: "a.rs", isLink: true }), T.glyphFor({ name: "a.rs" }));
    t.ok("an executable nothing else claims is marked as one",
      T.glyphFor({ name: "runme", isExec: true })
        !== T.glyphFor({ name: "runme" }));
    // and the extension still outranks it: a .sh is a shell script whether or
    // not the bit happens to be set
    t.eq("an extension outranks the executable bit",
      T.glyphFor({ name: "go.sh", isExec: true }), T.glyphFor({ name: "go.sh" }));

    // ── names that are also Object's business ─────────────────────────────
    // A file called "constructor" is a file, not a lookup that comes back with
    // a function and renders as one.
    t.eq("a file called constructor is just a file",
      T.glyphFor({ name: "constructor" }), T.glyphFor({ name: "zzqqvv" }));
    t.eq("so is __proto__", T.glyphFor({ name: "__proto__" }),
      T.glyphFor({ name: "zzqqvv" }));
    t.eq("and a directory called toString",
      T.glyphFor({ name: "toString", isDir: true }),
      T.glyphFor({ name: "zzqqvv", isDir: true }));

    // ── nothing at all ────────────────────────────────────────────────────
    t.eq("no entry is not a crash", T.glyphFor(null), "");
    t.eq("nor is an entry with no name", T.glyphFor({}),
      T.glyphFor({ name: "zzqqvv" }));

    // ── the table is actually there ───────────────────────────────────────
    // The failure the old parse could produce was an EMPTY table and no error,
    // so this is the assertion that would have caught it.
    t.ok("the table is populated", T.ruleCount() > 800);
    t.ok("every glyph is a real one, and one character wide", (() => {
      for (const table of [T.CONDS, T.FILES, T.DIRS, T.EXTS]) {
        for (const k of Object.keys(table)) {
          const g = table[k];
          if (typeof g !== "string" || g === "") return false;
          // one codepoint, and above the BMP's ASCII — a rule that lost its
          // glyph to an encoding round-trip comes back as "" or as a literal
          // backslash-u, and both would draw as nothing
          if ([...g].length !== 1) return false;
          if (g.codePointAt(0) < 0x2000) return false;
        }
      }
      return true;
    })());
    t.ok("rule names are lowercase, or they can never match", (() => {
      for (const table of [T.FILES, T.DIRS, T.EXTS])
        for (const k of Object.keys(table))
          if (k !== k.toLowerCase()) return false;
      return true;
    })());
    // ── the two tables have to agree ──────────────────────────────────────
    // terminus.js decides what an extension IS — archive, image, video, audio,
    // font, text — and icons.js decides what it LOOKS like. An extension the
    // first knows and the second does not is a file the window will happily
    // extract or preview and draw as a blank page. That is exactly how `.bz2`,
    // `.xbm` and `.qml` were found, so the check stays.
    //
    // Loaded here rather than declared as this suite's module, because a suite
    // gets one: terminus.js is the OTHER half of the comparison.
    const path = require("path");
    const fs = require("fs");
    const vm = require("vm");
    const tsrc = fs.readFileSync(
      path.join(__dirname, "..", "..", "terminus", "terminus.js"), "utf8");
    const tctx = vm.createContext({
      Strings: { shellQuote: (s) => s, escapeHtml: (s) => s },
      Paths: { home: () => "/h", cacheDir: () => "/c", tmpDir: () => "/t",
               configDir: () => "/cf" },
      Desktop: { dirsExpr: () => "", fileName: (i) => i, launchCommand: () => "" },
      Quickshell: { env: () => "" }, Qt: {}
    });
    const decls = [...tsrc.matchAll(/^(?:const|let)\s+([A-Za-z_$][\w$]*)/gm)]
      .map((m) => m[1]);
    vm.runInContext(tsrc + "\n"
      + decls.map((n) => "try{globalThis." + n + "=" + n + "}catch(e){}").join(";"),
      tctx);

    const gap = (tableName) => {
      const tbl = tctx[tableName] || {};
      return Object.keys(tbl)
        .filter((e) => tbl[e] && T.EXTS[e] === undefined);
    };
    for (const name of ["ARCHIVE_EXTS", "IMAGE_EXTS", "VIDEO_EXTS",
                        "AUDIO_EXTS", "FONT_EXTS", "TEXT_EXTS"]) {
      const miss = gap(name);
      t.eq("every extension in " + name + " has a glyph", miss, []);
    }
    // and the same for the kinds the listing colours rows by
    const cats = tctx.CAT_EXTS || {};
    for (const k of Object.keys(cats)) {
      const miss = Object.keys(cats[k])
        .filter((e) => cats[k][e] && T.EXTS[e] === undefined);
      t.eq("every " + k + " extension has a glyph", miss, []);
    }
  }
};
