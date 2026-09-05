// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// The pure half of terminus. Everything here is a function of its arguments
// alone — the parsers, the sort, the path arithmetic, the command builders —
// which is exactly the half a running shell is the most awkward place to
// check. The half that needs a window is not tested here and should not be.
//
// The parsers get fed REAL output shapes: find's NUL-separated records, du's
// tab columns, git's porcelain. A parser test with invented input tests the
// invention.

"use strict";

// find prints these with the separators terminus asked it for. Rebuilt here
// from the same constants rather than pasted, so a change to the format has
// one place to fail rather than two.
function rec(kind, type, mode, size, mtime, path) {
  return [kind, type, mode, size, mtime, path].join("");
}
function listing(...recs) { return recs.join("") + ""; }

module.exports = {
  module: "terminus/terminus.js",
  cases: (T, t) => {
    // ── paths ─────────────────────────────────────────────────────────────
    t.eq("dirname of a file", T.dirname("/a/b/c.txt"), "/a/b");
    t.eq("dirname at the root", T.dirname("/"), "/");
    t.eq("dirname of a top-level entry", T.dirname("/etc"), "/");
    t.eq("basename strips a trailing slash", T.basename("/a/b/"), "b");
    t.eq("basename of a plain path", T.basename("/a/b"), "b");
    t.eq("joinPath at the root does not double the slash",
      T.joinPath("/", "etc"), "/etc");
    t.eq("joinPath elsewhere", T.joinPath("/a", "b"), "/a/b");
    t.eq("stem drops the extension", T.stem("a.tar.gz"), "a.tar");
    t.eq("stem keeps a leading dot whole", T.stem(".bashrc"), ".bashrc");

    // The trailing slash is what makes a symlinked directory list at all —
    // find without it treats the link as a file and prints one row.
    t.eq("listPath adds the slash", T.listPath("/a/b"), "/a/b/");
    t.eq("listPath leaves one alone", T.listPath("/a/b/"), "/a/b/");

    // ── parseListing ──────────────────────────────────────────────────────
    const rows = T.parseListing(listing(
      rec("f", "f", "100644", "1024", "1700000000", "/d/notes.md"),
      rec("l", "d", "40755", "4096", "1700000001", "/d/link"),
      rec("f", "f", "100755", "20", "1700000002", "/d/run.sh"),
      rec("f", "f", "100644", "3", "1700000003", "/d/.hidden")
    ), "/d");
    t.eq("every record parsed", rows.length, 4);
    t.eq("name is the tail of the path", rows[0].name, "notes.md");
    t.eq("path is kept whole", rows[0].path, "/d/notes.md");
    t.ok("a symlink to a directory is both", rows[1].isLink && rows[1].isDir);
    t.ok("the exec bit is read from the mode", rows[2].isExec);
    t.ok("a plain file is not executable", !rows[0].isExec);
    t.ok("a leading dot is hidden", rows[3].isHidden);
    t.eq("size parses", rows[0].size, 1024);
    t.eq("mode is kept whole for the permissions editor", rows[2].mode, 0o100755);
    t.eq("a short record is skipped", T.parseListing("ab", "/d").length, 0);
    t.eq("empty input is an empty listing", T.parseListing("", "/d").length, 0);

    // ── sorting ───────────────────────────────────────────────────────────
    const mixed = [
      { name: "b.png", isDir: false, size: 10, mtime: 3 },
      { name: "a.txt", isDir: false, size: 30, mtime: 1 },
      { name: "zdir", isDir: true, size: 0, mtime: 2 },
      { name: "c.mp3", isDir: false, size: 20, mtime: 4 }
    ];
    const names = (rs) => rs.map((r) => r.name).join(",");

    t.eq("name sort puts directories first",
      names(T.sortEntries(mixed.slice(), "name", false)), "zdir,a.txt,b.png,c.mp3");
    t.eq("reversing keeps directories first",
      names(T.sortEntries(mixed.slice(), "name", true)), "zdir,c.mp3,b.png,a.txt");
    t.eq("size sort ascends until it is reversed",
      names(T.sortEntries(mixed.slice(), "size", false)), "zdir,b.png,c.mp3,a.txt");
    t.eq("mtime sort ascends too",
      names(T.sortEntries(mixed.slice(), "mtime", false)), "zdir,a.txt,b.png,c.mp3");
    t.eq("kind sort follows KIND_ORDER",
      names(T.sortEntries(mixed.slice(), "kind", false)), "zdir,b.png,c.mp3,a.txt");

    // Sorting must not disturb the caller's array — the views hold their own.
    const orig = mixed.slice();
    T.sortEntries(mixed.slice(), "size", true);
    t.eq("the input array is untouched", names(mixed), names(orig));

    // ── the disk-usage order ──────────────────────────────────────────────
    // Biggest first, and directories do NOT float to the top: the question is
    // what is taking up room, not what kind of thing it is.
    const used = [
      { name: "small.txt", isDir: false, size: 100 },
      { name: "bigdir",    isDir: true,  size: 4096, du: 900000 },
      { name: "huge.iso",  isDir: false, size: 500000 },
      { name: "emptydir",  isDir: true,  size: 4096, du: 0 }
    ];
    t.eq("biggest first, directories not privileged",
      T.sortEntries(used.slice(), "usage", true).map((r) => r.name).join(","),
      "bigdir,huge.iso,small.txt,emptydir");
    t.eq("and it reverses",
      T.sortEntries(used.slice(), "usage", false).map((r) => r.name).join(","),
      "emptydir,small.txt,huge.iso,bigdir");
    // A directory nobody has measured yet falls back to its own inode size
    // rather than vanishing to the bottom as a zero.
    const unmeasured = [
      { name: "d", isDir: true, size: 4096 },
      { name: "f", isDir: false, size: 10 }
    ];
    t.eq("an unmeasured directory still sorts by something",
      T.sortEntries(unmeasured.slice(), "usage", true).map((r) => r.name).join(","),
      "d,f");
    // the ordinary sorts must be untouched by all of this
    t.eq("name sort still puts directories first",
      T.sortEntries(used.slice(), "name", false).map((r) => r.isDir).join(","),
      "true,true,false,false");

    // ── kinds ─────────────────────────────────────────────────────────────
    t.eq("extension test is case-insensitive", T.kindOf("PHOTO.PNG"), "image");
    t.eq("source files are text", T.kindOf("main.rs"), "text");
    t.eq("an unknown extension is other", T.kindOf("blob.zzz"), "other");
    t.eq("no extension at all is file", T.kindOf("Makefile"), "file");
    t.ok("isImage agrees with kindOf", T.isImage("a.jpeg"));
    t.ok("isVideo agrees with kindOf", T.isVideo("a.mkv"));
    t.ok("isArchive knows a two-part extension", T.isArchive("a.tar.zst"));
    t.eq("stripArchiveExt takes both halves", T.stripArchiveExt("a.tar.gz"), "a");
    t.eq("stripArchiveExt on a single extension", T.stripArchiveExt("a.zip"), "a");

    // ── formatting ────────────────────────────────────────────────────────
    t.eq("bytes stay bytes", T.formatSize(512), "512 B");
    t.match("kilobytes round", T.formatSize(1024), /^1(\.0)? ?K/);
    t.eq("a duration under an hour has no hour field", T.formatDuration(65), "1:05");
    t.match("an hour appears when there is one", T.formatDuration(3725), /1:02:05/);
    // A zero duration means ffprobe did not know, and a preview that says
    // "0:00" is asserting something it was never told.
    t.eq("an unknown duration shows nothing", T.formatDuration(0), "");

    // ── names ─────────────────────────────────────────────────────────────
    const taken = [{ name: "new file" }, { name: "new file 2" }];
    t.eq("freeName skips what exists", T.freeName(taken, "new file"), "new file 3");
    t.eq("freeName in an empty directory", T.freeName([], "new dir"), "new dir");
    t.ok("a slash is not a legal name", !!T.nameError("a/b", []));
    t.ok("an empty name is an error", !!T.nameError("", []));
    t.eq("an ordinary name is fine", T.nameError("notes.md", []), "");

    // ── commands ──────────────────────────────────────────────────────────
    // Quoting is the one thing that must never drift: these are the names
    // that break naive quoting, and they are legal filenames.
    const nasty = "it's a $file `x`; rm -rf /";
    t.has("a quote in a name is escaped, not dropped",
      T.listCommand("/d/" + nasty), "'\\''");
    // The real proof is a real shell: quote the name, hand it to sh, and see
    // whether what comes back is the name that went in. A regex over the
    // command can only guess at what sh would have done with it.
    t.quotes("the shell gives the name back unchanged", nasty);
    t.quotes("a newline in a name survives", "two\nlines");
    t.quotes("a backslash is not an escape here", "back\\slash");
    t.quotes("dollars are not expanded", "$HOME $(id)");

    t.has("listing is one level deep", T.listCommand("/d"), "-maxdepth 1");
    t.has("the peek is capped", T.peekCommand("/d"), "head -c");

    // The finder asks twice on purpose: directories ranked first, then files.
    const find = T.findCommand("/d", "conf");
    t.before("directories are searched before files", find, "--nth -2", "--nth -1");
    t.has("the query reaches fzf", find, "conf");

    t.has("delete is recursive and forced", T.deleteCommand(["/d/x"]), "rm -rf");
    t.has("copy preserves attributes", T.copyCommand(["/d/x"], "/e"), "cp -a");
    t.has("move refuses to descend into a directory", T.renameCommand("/d/x", "/d/y"), "mv -T");
    t.has("chmod takes the octal", T.chmodCommand(["/d/x"], 0o755, false), "755");

    // ── modeString ────────────────────────────────────────────────────────
    t.eq("a 755 file reads rwxr-xr-x", T.modeString(0o755), "rwxr-xr-x");
    t.eq("a 644 file reads rw-r--r--", T.modeString(0o644), "rw-r--r--");
    t.eq("no bits at all", T.modeString(0), "---------");

    // ── du ────────────────────────────────────────────────────────────────
    const sizes = T.parseDirSizes("4096\t/d/a\n8192\t/d/b\n");
    t.eq("du's two columns are read", sizes["/d/a"], 4096);
    t.eq("both rows are read", sizes["/d/b"], 8192);
    t.eq("junk is ignored", Object.keys(T.parseDirSizes("nonsense\n")).length, 0);

    // ── completion ────────────────────────────────────────────────────────
    const HOME = "/home/test";
    t.eq("a tilde expands", T.expandPath("~/x", HOME, "/cwd"), HOME + "/x");
    t.eq("a bare tilde is home", T.expandPath("~", HOME, "/cwd"), HOME);
    t.eq("an absolute path is left alone", T.expandPath("/a/b", HOME, "/cwd"), "/a/b");
    t.eq("a relative path hangs off the cwd",
      T.expandPath("b", HOME, "/a"), "/a/b");
    t.eq("doubled slashes collapse", T.expandPath("/a//b", HOME, "/"), "/a/b");
    t.eq("a trailing slash is dropped", T.expandPath("/a/b/", HOME, "/"), "/a/b");
    t.eq("the root keeps its one slash", T.expandPath("/", HOME, "/"), "/");
    t.eq("the common prefix of one is itself", T.commonPrefix(["abc"]), "abc");
    t.eq("the common prefix of several", T.commonPrefix(["abcd", "abce"]), "abc");
    t.eq("no common prefix", T.commonPrefix(["ab", "cd"]), "");
    t.eq("nothing to complete", T.commonPrefix([]), "");

    // ── archives, and the count that drives the progress bar ──────────────
    const cz = T.compressJobCommand(["/d/src"], "/d/out.tar.zst");
    t.has("bsdtar picks the format out of the name", cz, "bsdtar -a -cvf");
    t.has("verbose, because the entries ARE the progress", cz, "-cvf");
    t.has("the total is counted before the work starts", cz, "wc -l");
    t.has("the exit status survives the pipeline", cz, "$? > ");
    t.has("and is re-raised at the end", cz, 'exit "${s:-1}"');
    // bsdtar announces entries on stderr, so the pipe has to carry stderr
    t.has("stderr is what gets counted for bsdtar", cz, "2>&1 >/dev/null");

    const c7 = T.compressJobCommand(["/d/src"], "/d/out.7z");
    t.has("7z is driven by 7z", c7, "7z a -bb1");
    t.has("7z counts files, having no entry for a directory", c7, "-type f");
    // its entry lines come on stdout, and its stderr must stay untouched so a
    // real 7z error still reaches the job's collector
    t.ok("7z does not redirect stderr into the counter",
      c7.indexOf("2>&1 >/dev/null") === -1);

    const xj = T.extractJobCommand("/d/a.tar.gz", "/dest");
    t.has("the table of contents gives the total", xj, "bsdtar -tf");
    t.has("extraction is verbose too", xj, "bsdtar -xvf");
    t.has("into a directory of its own", xj, "terminus_free_dir");
    t.has("named after the archive without both extensions", xj, "'a'");

    t.eq("a total record parses", T.parseArchiveProgress("T8").total, 8);
    t.eq("a position record parses", T.parseArchiveProgress("P3").at, 3);
    t.eq("an empty archive is still a total",
      T.parseArchiveProgress("T0").total, 0);
    t.eq("anything else is not a record", T.parseArchiveProgress("a src/x"), null);
    t.eq("nor is a blank line", T.parseArchiveProgress(""), null);
    t.eq("nor is a number on its own", T.parseArchiveProgress("42"), null);

    // ── open with ─────────────────────────────────────────────────────────
    // Launched by ID through the whole search path, not by the one file the
    // scan happened to find first — a stale user override would otherwise be
    // the end of it. See openWithCommand.
    const ow = T.openWithCommand("nvim.desktop", "/d/notes.md");
    t.has("gio, which honours Terminal=true", ow, "gio launch");
    t.ok("never gtk-launch", ow.indexOf("gtk-launch") === -1);
    t.has("the file argument comes along", ow, "'/d/notes.md'");
    t.has("it falls through to the next entry", ow, "&& exit 0");
    t.has("the scan itself walks the XDG path too",
      T.appsCommand("/d/x"), "XDG_DATA_DIRS");

    // ── git ───────────────────────────────────────────────────────────────
    // The command has to be read-only and scoped, or a file manager polling a
    // large repository becomes a file manager fighting the user's terminal
    // for the index lock.
    const gc = T.gitCommand("/repo/sub");
    t.has("git is not allowed to take the index lock", gc, "--no-optional-locks");
    t.has("only this subtree is scanned", gc, "-- .");
    t.has("the machine-readable format is asked for", gc, "--porcelain=v1 -z");
    t.has("the root is asked for too", gc, "--show-toplevel");

    // The two status columns, read the way git writes them.
    t.eq("a worktree edit", T.gitState(" M"), "modified");
    t.eq("a staged addition", T.gitState("A "), "staged");
    t.eq("staged and then edited again", T.gitState("MM"), "modified");
    t.eq("untracked", T.gitState("??"), "untracked");
    t.eq("ignored", T.gitState("!!"), "ignored");
    t.eq("both sides added it", T.gitState("AA"), "conflict");
    t.eq("unmerged", T.gitState("UU"), "conflict");
    t.eq("one side deleted it", T.gitState("DU"), "conflict");
    t.eq("gone from the worktree", T.gitState(" D"), "deleted");
    t.eq("clean is nothing at all", T.gitState("  "), "");

    t.eq("a conflict outranks an edit", T.gitWorse("modified", "conflict"), "conflict");
    t.eq("an edit outranks an untracked file", T.gitWorse("untracked", "modified"), "modified");
    t.eq("either side may be empty", T.gitWorse("", "staged"), "staged");
    t.eq("both sides empty is empty", T.gitWorse("", ""), "");

    // Real output, captured from a real repository: header, NUL, then
    // NUL-terminated records whose paths are relative to the repository root
    // even though git was invoked from a subdirectory.
    const raw = "/repo\nmaster\n" + "\0"
      + "A  staged.txt\0"
      + " M sub/deep/nested.txt\0"
      + " M tracked.txt\0"
      + "?? fresh/\0"
      + "?? untracked.txt\0";
    const g = T.parseGit(raw);
    t.eq("the root is read", g.root, "/repo");
    t.eq("the branch is read", g.branch, "master");
    t.eq("every record is read", g.entries.length, 5);
    t.eq("paths are made absolute against the ROOT, not the cwd",
      g.entries[1].path, "/repo/sub/deep/nested.txt");

    // A detached head is a state, not a branch called HEAD.
    t.eq("a detached head says so", T.parseGit("/repo\nHEAD\n\0").branch, "detached");
    // Outside a repository there is no NUL because the command printed nothing.
    t.eq("outside a repository there is no root", T.parseGit("").root, "");
    t.eq("and no entries", T.parseGit("").entries.length, 0);
    t.eq("a repository with no commits still has a root",
      T.parseGit("/repo\n\0").root, "/repo");

    // The rollup is what the rows actually read.
    const marks = T.gitRollup(g.entries, "/repo");
    t.eq("a file in this directory keeps its own state",
      marks["/repo/tracked.txt"], "modified");
    t.eq("a directory takes the state of what is under it",
      marks["/repo/sub"], "modified");
    t.eq("an untracked directory arrives already collapsed",
      marks["/repo/fresh"], "untracked");
    t.eq("nothing is invented for a clean row",
      marks["/repo/clean.txt"], undefined);

    // Seen from the subdirectory, the same answer folds onto different rows.
    const sub = T.gitRollup(g.entries, "/repo/sub");
    t.eq("only what is below this directory counts", Object.keys(sub).length, 1);
    t.eq("and it folds onto the next segment down", sub["/repo/sub/deep"], "modified");

    // A directory holding both a conflict and an edit shows the conflict.
    const worst = T.gitRollup([
      { path: "/repo/d/a", state: "modified" },
      { path: "/repo/d/b", state: "conflict" },
      { path: "/repo/d/c", state: "untracked" }
    ], "/repo");
    t.eq("the worst state wins the directory", worst["/repo/d"], "conflict");

    // Filenames are allowed to be awful. A newline is legal, which is the
    // entire reason the records are NUL-terminated.
    const odd = T.parseGit("/repo\nmain\n\0?? two\nlines.txt\0 M with space.txt\0");
    t.eq("a newline inside a filename does not split the record",
      odd.entries[0].path, "/repo/two\nlines.txt");
    t.eq("and a space is just a space", odd.entries[1].path, "/repo/with space.txt");

    // ── where a result was found ──────────────────────────────────────────
    // The column that only exists while a search does. Relative to the
    // directory the search started in, because the absolute path is mostly a
    // prefix repeated down every row.
    t.eq("a result beside the search root is here",
      T.whereOf("/home/b/p/notes.md", "/home/b/p"), ".");
    t.eq("a result below it is named from the root down",
      T.whereOf("/home/b/p/spoot/src/main.c", "/home/b/p"), "spoot/src");
    t.eq("a trailing slash on the root changes nothing",
      T.whereOf("/home/b/p/spoot/x", "/home/b/p/"), "spoot");
    t.eq("searching / keeps the leading slash off the answer",
      T.whereOf("/etc/fstab", "/"), "etc");
    t.eq("the root itself is here even when it is /",
      T.whereOf("/passwd", "/"), ".");
    // A near-miss must not be mistaken for a match: /home/b/project is not
    // under /home/b/p, and a prefix test without the separator says it is.
    t.eq("a sibling whose name merely starts the same keeps its full path",
      T.whereOf("/home/b/project/x", "/home/b/p"), "/home/b/project");
    t.eq("something outside the root keeps its full path",
      T.whereOf("/var/log/x", "/home/b/p"), "/var/log");

    // ── bulk rename ───────────────────────────────────────────────────────
    // The rules, in the one function both the card and the commit gate read.
    const was = ["a.txt", "b.txt", "c.txt"];
    t.eq("names that are all fine have no issues",
      T.bulkIssues(was, ["x.txt", "y.txt", "z.txt"]).join("|"), "||");
    t.eq("an empty name is an issue",
      T.bulkIssues(was, ["", "y.txt", "z.txt"])[0], "empty");
    t.eq("whitespace is an empty name",
      T.bulkIssues(was, ["   ", "y.txt", "z.txt"])[0], "empty");
    t.has("a slash would be a move, not a rename",
      T.bulkIssues(was, ["a/b", "y.txt", "z.txt"])[0], "/");
    t.eq("a dot is not a filename",
      T.bulkIssues(was, [".", "y.txt", "z.txt"])[0], "reserved");
    t.has("a collision names the row it collides with",
      T.bulkIssues(was, ["same", "same", "z.txt"])[1], "row 1");
    // A plain object inherits toString, so the old duplicate check fired
    // against a name nothing in the batch had used.
    t.eq("a file called toString is not a duplicate of anything",
      T.bulkIssues(was, ["toString", "y.txt", "z.txt"]).join("|"), "||");

    // The gate itself.
    t.eq("only the names that changed are renames",
      T.bulkPairs(was, ["a.txt", "B.txt", "c.txt"]).length, 1);
    t.eq("and the pair is old then new",
      T.bulkPairs(was, ["a.txt", "B.txt", "c.txt"])[0].join(">"), "b.txt>B.txt");
    t.eq("an unchanged list is no renames",
      T.bulkPairs(was, was.slice()).length, 0);
    t.eq("a list of the wrong length is refused",
      T.bulkPairs(was, ["a.txt"]), null);
    t.eq("one illegal name refuses the whole batch",
      T.bulkPairs(was, ["", "y.txt", "z.txt"]), null);
    t.eq("so does one collision",
      T.bulkPairs(was, ["same", "same", "z.txt"]), null);
    t.eq("surrounding space is trimmed rather than refused",
      T.bulkPairs(was, [" a.txt ", "b.txt", "c.txt"]).length, 0);

    // The swap, which is the case a direct mv would destroy.
    const swap = T.bulkRenameApply("/d", T.bulkPairs(["a", "b"], ["b", "a"]));
    t.eq("a swap moves through a temporary name",
      (swap.match(/terminus\.tmp\./g) || []).length, 4);
    t.before("and nothing is put down before both are picked up",
      swap, "'b' 'terminus", "' 'b' ||");

    // Find and replace, which is what the editor was really being borrowed
    // for. PLAIN TEXT: a filename is full of characters a regex would eat.
    t.eq("every occurrence goes",
      T.bulkReplace(["a-b-c"], "-", "_")[0], "a_b_c");
    t.eq("a dot is a dot and not any character",
      T.bulkReplace(["axb.jpeg"], ".jpeg", ".jpg")[0], "axb.jpg");
    t.eq("brackets are not a character class",
      T.bulkReplace(["shot (1).png"], " (1)", "")[0], "shot.png");
    t.eq("an empty needle changes nothing",
      T.bulkReplace(["a.txt"], "", "x")[0], "a.txt");
    t.eq("and replacing with nothing deletes it",
      T.bulkReplace(["IMG_0001.jpg"], "IMG_", "")[0], "0001.jpg");
  }
};
