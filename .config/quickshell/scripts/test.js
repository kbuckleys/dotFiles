#!/usr/bin/env node
// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// TEST — the pure halves of this shell, checked without starting it.
//
// Every layer's .js is a plain script: no exports, no imports, just functions
// in the QML document's scope. That is what makes it awkward to test and also
// what makes it easy — a script with no module system is a script node can run
// in a VM context, as long as the context holds the same globals quickshell
// puts there. So this file builds that context and runs the file inside it.
//
// The stubs are the REAL singletons' bodies, not approximations. shellQuote
// especially: a test that quotes differently from the shipping code is a test
// that agrees with itself and nothing else. Paths reads a fake environment so
// the answers are stable on any machine, which is the only difference.
//
// Usage:  node scripts/test.js            all suites
//         node scripts/test.js terminus   suites whose name contains "terminus"

"use strict";

const fs = require("fs");
const vm = require("vm");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");

// ── the quickshell-shaped globals ─────────────────────────────────────────
// A fake environment, so cacheDir() and friends answer the same on every
// machine. The values are the XDG defaults for a user called "test".
const ENV = {
  HOME: "/home/test",
  XDG_CACHE_HOME: "/home/test/.cache",
  XDG_CONFIG_HOME: "/home/test/.config",
  TMPDIR: "/tmp"
};

function makeContext() {
  const Paths = {
    home: () => ENV.HOME,
    cacheDir: () => ENV.XDG_CACHE_HOME || Paths.home() + "/.cache",
    tmpDir: () => ENV.TMPDIR || "/tmp",
    configDir: () => ENV.XDG_CONFIG_HOME || Paths.home() + "/.config"
  };

  const Strings = {
    // byte-for-byte morpheus/Strings.qml
    shellQuote: (s) => "'" + String(s ?? "").replace(/'/g, "'\\''") + "'",
    escapeHtml: (s) => String(s ?? "")
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"),
    zenonHex: () => ({
      black: "#000000", white: "#dfdfdd", muted: "#6a707f", red: "#e78284",
      green: "#b6e0a4", yellow: "#fab387", blue: "#9fcbfc",
      magenta: "#c8a4e0", cyan: "#9bbfbf", pink: "#eebebe", sand: "#e0d8a4"
    })
  };

  // morpheus/Desktop.qml, same bodies. It builds shell text, so a stub that
  // built different shell text would be a test agreeing with itself.
  const Desktop = {
    dirsExpr: () =>
      "\"${XDG_DATA_HOME:-$HOME/.local/share}/applications\" "
      + "$(printf %s \"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}\" "
      + "| tr : '\\n' | sed 's|$|/applications|' | tr '\\n' ' ')",
    launchCommand: (id, arg) => {
      const a = (arg === undefined || arg === null || arg === "")
        ? "" : " " + Strings.shellQuote(arg);
      return "for d in " + Desktop.dirsExpr() + "; do\n"
        + "  f=\"$d/\"" + Strings.shellQuote(id) + "\n"
        + "  [ -f \"$f\" ] || continue\n"
        + "  gio launch \"$f\"" + a + " >/dev/null 2>&1 && exit 0\n"
        + "done\n"
        + "exit 1\n";
    }
  };

  const ctx = {
    Paths, Strings, Desktop, console,
    Quickshell: { env: (k) => ENV[k] ?? "" },
    Qt: {
      // enough of Qt for the odd formatting helper that reaches for it
      rgba: (r, g, b, a) => ({ r, g, b, a }),
      formatDateTime: (d, f) => String(d)
    }
  };
  return vm.createContext(ctx);
}

// Loads one of the shell's .js files and hands back its context, which holds
// every function the file declared.
//
// The epilogue is not a trick, it is a correction. `function` and `var` at the
// top level of a script become properties of the global object; `const` and
// `let` do not — they go in a lexical scope the context object cannot see. QML
// draws no such line: a .js file's top-level const is as visible to the
// document as its functions are, which is why terminus reaches for KIND_ORDER
// and cynosure for ICON_T. Copying them out afterwards is what makes this
// context match the one the shell actually runs these files in.
function load(rel) {
  const file = path.join(ROOT, rel);
  const ctx = makeContext();
  const src = fs.readFileSync(file, "utf8");

  const names = new Set();
  for (const m of src.matchAll(/^(?:const|let)\s+([A-Za-z_$][\w$]*)/gm))
    names.add(m[1]);
  const epilogue = [...names]
    .map((n) => "try { globalThis." + n + " = " + n + "; } catch (e) {}")
    .join("\n");

  vm.runInContext(src + "\n" + epilogue, ctx, { filename: file });
  return ctx;
}

// ── assertions ────────────────────────────────────────────────────────────
// Deliberately small. A failure prints what it wanted and what it got, which
// is the only thing a failing test has to do well.
function show(v) {
  if (typeof v === "string") return JSON.stringify(v);
  try { return JSON.stringify(v); } catch (e) { return String(v); }
}

class T {
  constructor(suite) { this.suite = suite; this.fails = []; this.count = 0; }

  ok(name, cond) {
    this.count++;
    if (!cond) this.fails.push(name + "\n      expected truthy");
  }

  eq(name, got, want) {
    this.count++;
    const a = show(got), b = show(want);
    if (a !== b) this.fails.push(name + "\n      want " + b + "\n      got  " + a);
  }

  // For commands: asserts a fragment is present, which is how a shell command
  // is best pinned — the whole string is noise, the flag is the contract.
  has(name, hay, needle) {
    this.count++;
    if (String(hay).indexOf(needle) === -1)
      this.fails.push(name + "\n      " + show(needle) + " missing from\n      " + show(hay));
  }

  match(name, hay, re) {
    this.count++;
    if (!re.test(String(hay)))
      this.fails.push(name + "\n      " + String(re) + " did not match\n      " + show(hay));
  }

  // Order matters in a command built from two halves — dirs before files in
  // the finder, for one — and a "both present" check would pass either way.
  before(name, hay, first, second) {
    this.count++;
    const s = String(hay), a = s.indexOf(first), b = s.indexOf(second);
    if (a === -1 || b === -1 || a > b)
      this.fails.push(name + "\n      " + show(first) + " should come before " + show(second));
  }

  // The strongest check this file can make about a command: hand the quoted
  // string to a real /bin/sh and see whether the byte sequence that comes
  // back is the one that went in. Every regex alternative is an opinion about
  // what sh does; this asks it.
  quotes(name, raw) {
    this.count++;
    const q = "'" + String(raw).replace(/'/g, "'\\''") + "'";
    let got;
    try {
      got = require("child_process")
        .execFileSync("/bin/sh", ["-c", "printf %s " + q], { encoding: "utf8" });
    } catch (e) {
      this.fails.push(name + "\n      sh refused it: " + e.message);
      return;
    }
    if (got !== String(raw))
      this.fails.push(name + "\n      want " + show(String(raw)) + "\n      got  " + show(got));
  }

  throws(name, fn) {
    this.count++;
    let threw = false;
    try { fn(); } catch (e) { threw = true; }
    if (!threw) this.fails.push(name + "\n      expected a throw");
  }
}

// ── runner ────────────────────────────────────────────────────────────────
const only = process.argv[2] || "";
const dir = path.join(__dirname, "tests");
const suites = fs.existsSync(dir)
  ? fs.readdirSync(dir).filter((f) => f.endsWith(".js")).sort()
  : [];

let total = 0, failed = 0;
const bad = [];

for (const file of suites) {
  const name = file.replace(/\.js$/, "");
  if (only && name.indexOf(only) === -1) continue;

  const suite = require(path.join(dir, file));
  const t = new T(name);
  let mod;
  try {
    mod = load(suite.module);
  } catch (e) {
    bad.push("  " + name + ": could not load " + suite.module + "\n      " + e.message);
    failed++;
    continue;
  }

  try {
    suite.cases(mod, t);
  } catch (e) {
    t.fails.push("threw while running\n      " + (e && e.stack || e));
  }

  total += t.count;
  failed += t.fails.length;
  const mark = t.fails.length === 0 ? "  ok  " : "  FAIL";
  console.log(mark + "  " + name + "  (" + t.count + " checks)");
  for (const f of t.fails) bad.push("        " + f);
}

if (bad.length) {
  console.log("");
  for (const b of bad) console.log(b);
}
console.log("");
console.log(failed === 0
  ? "  " + total + " checks pass"
  : "  " + failed + " of " + total + " checks FAILED");
process.exit(failed === 0 ? 0 : 1);
