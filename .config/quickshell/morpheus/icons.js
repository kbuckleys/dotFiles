// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// THE FILE GLYPHS — what a file or a directory LOOKS like, by name.
//
// In morpheus rather than in terminus, because two layers ask the same
// question. Terminus draws a listing; artemis draws search results over the
// same tree, and a .rs file that is a Rust mark in one window and a blank page
// in the other is two answers to one question. Same argument that put Strings,
// Paths and Desktop here.
//
// It used to PARSE ~/.config/yazi/flavors/ZENON.yazi/flavor.toml at startup,
// on the argument that the flavor already carried the rules and a second copy
// would drift from the first. The argument was sound and the arrangement was
// still wrong: it made a file manager's icons a property of a DIFFERENT
// program's theme. This shell could not add a rule without editing yazi, could
// not be given a glyph yazi has no opinion about, and rendered every file as a
// blank page on a machine where yazi is not installed or the flavor is named
// something else. A window should not depend on another application's
// configuration to know what a .rs file looks like.
//
// So the table lives here now, seeded from the choices that flavor had already
// made — those were right, and nothing is served by picking different ones —
// and extended with everything it was missing.
//
// ── how a glyph is chosen ───────────────────────────────────────────────
// Yazi's own precedence, kept because it is the correct one: the most specific
// rule that matches wins. An exact filename beats an extension, and an
// extension beats the catch-all condition for "is a directory" or "is not".
// Directories are matched against DIRS and never against EXTS, because
// "src.old" is a folder, not an .old file.
//
// Names are compared LOWERCASED. "Makefile", "makefile" and "MAKEFILE" are one
// rule, and a file called ".BASHRC" is not a stranger.
//
// ── how the glyphs were chosen ──────────────────────────────────────────
// Every one of them is a real nerd-fonts glyph, resolved by NAME out of
// nerd-fonts' own glyphnames.json and checked against the codepoints
// JetBrainsMono Nerd Font actually ships — not typed from memory. A glyph the
// font does not carry renders as nothing at all, which is indistinguishable
// from a rule that was never written.


// What a thing IS, when nothing more specific has an opinion.
const CONDS = {
  "!dir": "", "block": "", "char": "",
  "dir": "", "dummy": "", "exec": "",
  "fifo": "", "link": "", "orphan": "",
  "sock": "", "sticky": ""
};

// An exact filename. The most specific rule there is, and the only one that
// can tell a Cargo.toml from any other .toml.
const FILES = {
  ".bash_history": "󱆃", ".bashrc": "󱆃", ".dockerignore": "",
  ".editorconfig": "", ".env": "", ".env.local": "",
  ".eslintrc": "", ".eslintrc.json": "", ".gitattributes": "",
  ".gitconfig": "󰊢", ".gitignore": "", ".gitkeep": "󰊢",
  ".gitlab-ci.yml": "", ".gitmodules": "󰊢", ".inputrc": "󰑷",
  ".npmrc": "", ".nvmrc": "", ".prettierrc": "",
  ".profile": "󰑷", ".srcinfo": "󰣇", ".tmux.conf": "",
  ".travis.yml": "", ".vimrc": "", ".xinitrc": "󰑷",
  ".xprofile": "󰑷", ".zprofile": "󰑷", ".zshenv": "󰑷",
  ".zshrc": "󰑷", "authors": "", "bun.lockb": "",
  "cargo.lock": "󱘗", "cargo.toml": "󱘗", "changelog": "",
  "changelog.md": "", "cmakelists.txt": "", "code_of_conduct.md": "",
  "compose.yaml": "", "compose.yml": "", "config": "",
  "containerfile": "", "contributing.md": "", "copying": "󰿃",
  "default.nix": "󱄅", "docker-compose.yaml": "", "docker-compose.yml": "",
  "dockerfile": "", "flake.lock": "󱄅", "flake.nix": "󱄅",
  "gemfile": "", "gemfile.lock": "", "gnumakefile": "",
  "go.mod": "󰟓", "go.sum": "󰟓", "go.work": "󰟓",
  "hypr.conf": "", "hypridle.conf": "", "hyprland.conf": "",
  "hyprland.lua": "", "hyprlauncher.conf": "", "hyprlock.conf": "",
  "hyprpaper.conf": "", "hyprqt6engine.conf": "", "hyprsunset.conf": "",
  "hyprtoolkit.conf": "", "install": "", "justfile": "",
  "licence": "󰿃", "license": "󰿃", "license.md": "󰿃",
  "makefile": "", "meson.build": "", "news": "",
  "package-lock.json": "", "package.json": "", "pipfile": "󰌠",
  "pipfile.lock": "󰌠", "pkgbuild": "󰣇", "pnpm-lock.yaml": "",
  "poetry.lock": "󰌠", "procfile": "", "pyproject.toml": "󰌠",
  "rakefile": "", "readme": "", "readme.md": "",
  "requirements.txt": "󰌠", "rust-toolchain.toml": "󱘗", "setup.cfg": "󰌠",
  "setup.py": "󰌠", "shell.nix": "󱄅", "todo": "",
  "todo.md": "", "tox.ini": "󰌠", "tsconfig.json": "",
  "unlicense": "󰿃", "vagrantfile": "", "yarn.lock": ""
};

// A directory by name. Never consulted for a file, and never crossed with
// EXTS — a folder called "assets" is not a .assets.
const DIRS = {
  ".android": "󰓷", ".aws": "", ".bash": "󰑷",
  ".bun": "", ".cache": "", ".cargo": "󱣘",
  ".claude": "", ".config": "", ".deno": "",
  ".docker": "", ".emacs.d": "", ".fonts": "",
  ".git": "󰊢", ".github": "", ".gnupg": "",
  ".go": "󰟓", ".gradle": "", ".icons": "",
  ".idea": "", ".java": "", ".kube": "",
  ".local": "", ".m2": "", ".mozilla": "",
  ".npm": "", ".nvm": "", ".obsidian": "",
  ".pki": "", ".rustup": "", ".ssh": "",
  ".steam": "", ".terraform": "", ".themes": "󰏘",
  ".thunderbird": "󰇮", ".tmux": "", ".trash": "",
  ".venv": "󰌠", ".vim": "", ".vscode": "",
  ".wine": "", ".zen": "󰺕", ".zsh": "󰑷",
  "__pycache__": "󰌠", "__tests__": "󰙨", "addons": "",
  "api": "󱂛", "app": "󰅩", "arch": "󰣇",
  "archive": "", "archives": "", "assets": "",
  "audio": "󰎅", "audiobooks": "", "backup": "",
  "backups": "", "bin": "", "bittorrents": "",
  "books": "", "boot": "", "build": "",
  "cache": "", "captures": "󰹑", "certs": "",
  "claude": "", "cliphist": "", "components": "",
  "controllers": "", "courses": "", "database": "",
  "db": "", "desktop": "", "dev": "",
  "development": "", "discord": "", "dist": "",
  "django": "", "doc": "", "docs": "",
  "documents": "", "downloads": "󰃘", "dropbox": "",
  "electron": "󱀤", "elixir": "", "etc": "",
  "extensions": "", "fast": "", "fish": "",
  "flask": "", "fonts": "", "foot": "󰽒",
  "games": "", "gdrive": "", "git": "󰊢",
  "go": "󰟓", "gtk-3.0": "", "gtk-4.0": "",
  "gtk-5.0": "", "helpers": "", "home": "",
  "hooks": "", "hypr": "", "hyprland": "",
  "icons": "", "images": "", "img": "",
  "include": "󰅩", "internal": "󰅩", "keys": "",
  "laravel": "", "lib": "󰅩", "library": "",
  "log": "", "logs": "", "lost+found": "",
  "lua": "", "mail": "󰇮", "man": "",
  "memes": "", "migrations": "", "mnt": "",
  "models": "", "movies": "", "mozilla": "",
  "mpv": "", "music": "", "neovim": "",
  "nest": "", "nextcloud": "", "node_modules": "",
  "notes": "", "nvim": "", "obj": "",
  "obsidian": "", "onedrive": "", "opt": "",
  "out": "", "paru": "󰣇", "phoenix": "",
  "pictures": "", "pkg": "󰅩", "plugins": "",
  "podcasts": "󰎅", "proc": "", "projects": "󰲃",
  "public": "", "pulse": "", "repos": "󰊢",
  "root": "", "ruby": "", "run": "",
  "rust": "", "sbin": "", "schema": "",
  "screenshots": "󰹑", "scripts": "󰑷", "secrets": "",
  "services": "", "sounds": "󰎅", "spec": "󰙨",
  "spicetify": "", "spoot": "", "spotify": "",
  "spotify-player": "", "spotifyd": "", "spring boot": "",
  "sql": "", "src": "󰅩", "srv": "",
  "static": "", "sync": "", "sys": "",
  "target": "", "templates": "󰈙", "test": "󰙨",
  "tests": "󰙨", "themes": "󰏘", "third_party": "",
  "tmp": "", "tools": "", "torrents": "",
  "trash": "", "usr": "", "utils": "",
  "var": "", "vendor": "", "venv": "󰌠",
  "videos": "", "views": "", "vim": "",
  "wallpapers": "", "wine": "", "work": "",
  "workspace": "", "yay": "󰣇", "zen": "󰺕"
};

// By extension, which is what most files are recognised by.
const EXTS = {
  "xbm": "",
  "qml": "",
  "bz2": "",
  "1": "", "2": "", "3": "", "3ds": "",
  "3g2": "", "3gp": "󰎅", "5": "", "7": "",
  "7z": "", "8": "", "8svx": "󰎅", "a": "",
  "aa": "󰎅", "aab": "󰓷", "aac": "󰎅", "aax": "󰎅",
  "abw": "", "ac": "", "ac3": "󰎅", "ace": "",
  "act": "󰎅", "adoc": "", "ai": "", "aif": "󰎅",
  "aifc": "󰎅", "aiff": "󰎅", "alac": "󰎅", "am": "",
  "amr": "󰎅", "amv": "", "ape": "󰎅", "apk": "󰓷",
  "apkm": "󰓷", "apng": "", "appimage": "", "appx": "",
  "arc": "", "archive": "", "arj": "", "arrow": "",
  "arw": "", "asc": "", "asciidoc": "", "asf": "",
  "asm": "", "asp": "", "aspx": "", "ass": "",
  "astro": "", "au": "󰎅", "avi": "", "avif": "",
  "avro": "", "awb": "󰎅", "awk": "󰑷", "azw": "",
  "azw3": "", "bak": "", "bash": "󰑷", "bat": "",
  "bazel": "", "bdf": "", "bib": "", "bin": "",
  "blend": "", "bmp": "", "br": "", "bzip": "",
  "bzl": "", "c": "", "c++": "", "cab": "󰪶",
  "cabal": "", "caf": "󰎅", "cbr": "", "cbz": "",
  "cc": "", "cda": "󰎅", "cer": "", "cfg": "",
  "cfm": "", "cgi": "", "chm": "", "cjs": "",
  "class": "", "clj": "", "cljc": "", "cljs": "",
  "cls": "", "cmake": "", "cmd": "", "cnf": "",
  "compress": "", "conf": "", "cpio": "", "cpp": "",
  "cr": "", "cr2": "", "cr3": "", "crdownload": "",
  "crt": "", "crx": "", "cs": "", "csh": "󰑷",
  "css": "", "csv": "", "cue": "", "cur": "",
  "cxx": "", "d": "", "dae": "", "dart": "",
  "db": "", "dds": "", "deb": "", "der": "",
  "desktop": "", "dff": "󰎅", "diff": "", "divx": "",
  "djvu": "", "dll": "", "dmg": "", "dng": "",
  "doc": "", "dockerfile": "", "dockerignore": "", "docx": "",
  "download": "", "dpkg": "󱧘", "drc": "", "dsf": "󰎅",
  "dss": "󰎅", "dts": "󰎅", "dump": "", "dvf": "󰎅",
  "dwg": "", "dxf": "", "dylib": "", "ear": "",
  "editorconfig": "", "edn": "", "eex": "", "efi": "󰍛",
  "ejs": "", "el": "", "elf": "", "elm": "",
  "email": "󰇮", "eml": "󰇮", "emlx": "󰇮", "env": "",
  "eot": "", "eps": "", "epub": "", "erl": "",
  "ex": "", "exe": "", "exr": "", "exs": "",
  "f": "", "f4a": "", "f4b": "", "f4m": "",
  "f4p": "", "f4v": "", "f90": "", "f95": "",
  "fb2": "", "fbx": "", "feather": "", "fig": "",
  "fish": "", "flac": "󰎅", "flatpak": "", "flatpakref": "",
  "flv": "", "fnt": "", "fon": "", "for": "",
  "fw": "󰍛", "gd": "", "gem": "", "gif": "",
  "gifv": "", "glb": "", "gltf": "", "go": "󰟓",
  "gpg": "", "gpx": "󰗀", "gql": "", "gradle": "",
  "graphql": "", "groovy": "", "gsm": "󰎅", "gz": "",
  "gzip": "", "h": "", "h++": "", "h264": "",
  "h5": "", "hbs": "", "hcl": "", "hdf5": "",
  "hdr": "", "heex": "", "heic": "", "heif": "",
  "hh": "", "hpp": "", "hrl": "", "hs": "",
  "htm": "", "html": "", "hx": "", "hxx": "",
  "icns": "", "ico": "", "ics": "", "idx": "",
  "iklax": "󰎅", "img": "", "inf": "", "ini": "",
  "inl": "", "ipynb": "", "iso": "", "it": "󰎅",
  "ivs": "󰎅", "j2": "", "j2c": "", "j2k": "",
  "jar": "", "java": "", "jfif": "", "jinja": "",
  "jks": "", "jl": "", "jp2": "", "jpc": "",
  "jpe": "", "jpeg": "", "jpf": "", "jpg": "",
  "jpm": "", "jpq2": "", "jpx": "", "js": "",
  "json": "", "json5": "", "jsonc": "", "jsp": "",
  "jsx": "", "jxl": "", "kdbx": "", "key": "󰐩",
  "keytab": "", "kml": "󰗀", "ko": "", "kra": "",
  "ksh": "󰑷", "kt": "", "kts": "", "latex": "",
  "less": "", "lha": "", "lhs": "", "lisp": "",
  "list": "", "lnk": "", "lock": "", "log": "",
  "lrc": "", "lsp": "", "lua": "", "luac": "",
  "lz": "", "lz4": "", "lzh": "", "lzma": "",
  "lzo": "", "m": "", "m2p": "", "m2ts": "",
  "m2v": "", "m3u": "", "m3u8": "", "m4": "",
  "m4a": "󰎅", "m4b": "󰎅", "m4p": "󰎅", "m4v": "",
  "mak": "", "manifest": "", "map": "", "markdown": "",
  "md": "", "md5": "", "mdf": "", "mdx": "",
  "me": "", "mid": "󰎅", "midi": "󰎅", "mj2": "",
  "mjs": "", "mk": "", "mka": "", "mkv": "",
  "ml": "", "mli": "", "mm": "", "mmf": "󰎅",
  "mng": "", "mo": "󰗊", "mobi": "", "mod": "󰎅",
  "mogg": "󰎅", "mount": "", "mov": "", "movpkg": "󰎅",
  "mp1": "󰎅", "mp2": "󰎅", "mp3": "󰎅", "mp4": "",
  "mpc": "󰎅", "mpe": "", "mpeg": "", "mpg": "",
  "mpv": "", "msg": "󰇮", "msi": "", "msix": "",
  "msv": "󰎅", "mts": "", "mustache": "", "mxf": "",
  "mysql": "", "nasm": "", "nef": "", "nfo": "",
  "nim": "", "nims": "", "ninja": "", "nix": "󱄅",
  "njk": "", "nmf": "󰎅", "nomad": "", "npy": "",
  "npz": "", "nrg": "", "nsv": "", "numbers": "",
  "nupkg": "", "o": "", "obj": "", "odf": "",
  "odg": "", "odp": "󰐩", "ods": "", "odt": "",
  "oft": "󰇮", "oga": "󰎅", "ogg": "󰎅", "ogm": "",
  "ogv": "", "old": "", "opus": "󰎅", "orc": "",
  "orf": "", "org": "", "orig": "", "ost": "󰇮",
  "otc": "", "otf": "", "otp": "󰐩", "ots": "",
  "ott": "", "ova": "", "ovf": "", "p12": "",
  "pages": "", "parquet": "", "part": "", "partial": "",
  "patch": "", "pbm": "", "pc": "", "pcf": "",
  "pdf": "", "pef": "", "pem": "", "pfb": "",
  "pfm": "", "pfx": "", "pgm": "", "php": "",
  "pickle": "", "pict": "", "pid": "", "pjp": "",
  "pjpeg": "", "pkg": "", "pkl": "", "pl": "",
  "plist": "󰗀", "pls": "", "ply": "", "pm": "",
  "png": "", "pnm": "", "po": "󰗊", "pot": "󰗊",
  "ppm": "", "pps": "󰐩", "ppt": "󰐩", "pptx": "󰐩",
  "prefs": "", "properties": "", "proto": "", "ps": "",
  "ps1": "", "psd": "", "psd1": "", "psf": "",
  "psm1": "", "psql": "", "pst": "󰇮", "pub": "",
  "pug": "", "py": "󰌠", "pyc": "󰌠", "pyi": "󰌠",
  "pyw": "󰌠", "pyx": "󰌠", "qcow2": "", "qoi": "",
  "qt": "", "r": "", "ra": "󰎅", "raf": "",
  "rake": "", "rar": "", "rasi": "", "raw": "",
  "rb": "", "rc": "", "reg": "", "rej": "",
  "rf64": "󰎅", "rkt": "", "rlib": "󱘗", "rm": "󰎅",
  "rmd": "", "rmeta": "󱘗", "rmvb": "", "rom": "󰍛",
  "ron": "󱘗", "roq": "", "rpm": "", "rs": "󱘗",
  "rss": "", "rst": "", "rtf": "", "rules": "",
  "rw2": "", "s": "", "s3m": "󰎅", "sass": "",
  "sav": "", "sbt": "", "sbv": "", "sc": "",
  "scad": "", "scala": "", "scm": "", "scss": "",
  "sed": "󰑷", "service": "", "sfd": "", "sh": "󰑷",
  "sha1": "", "sha256": "", "shn": "󰎅", "sid": "󰎅",
  "sig": "", "sit": "", "sitx": "", "sketch": "",
  "sln": "󰎅", "smi": "", "snap": "", "so": "",
  "socket": "", "sol": "", "sql": "", "sqlite": "",
  "squashfs": "", "srt": "", "srw": "", "ssa": "",
  "step": "", "stl": "", "stp": "", "sty": "",
  "styl": "", "sub": "", "sum": "", "svelte": "",
  "svg": "", "svi": "", "swf": "", "swift": "",
  "swn": "", "swo": "", "swp": "", "sys": "",
  "tak": "󰎅", "tar": "", "tbz": "", "tbz2": "",
  "tex": "", "tf": "", "tfstate": "", "tfvars": "",
  "tga": "", "tgz": "", "theme": "󰔎", "thrift": "",
  "tif": "", "tiff": "", "timer": "", "tlz": "",
  "tml": "", "tmp": "", "toast": "", "toml": "",
  "torrent": "", "tres": "", "ts": "", "tscn": "",
  "tsv": "", "tsx": "", "tta": "󰎅", "ttc": "",
  "ttf": "", "ttml": "", "txt": "", "txz": "",
  "tzst": "", "ui": "󰗀", "url": "", "usdz": "",
  "vala": "", "vapi": "", "vb": "", "vcd": "",
  "vcf": "󰇮", "vcs": "", "vdi": "", "vhd": "",
  "vhdx": "", "vim": "", "viv": "", "vmdk": "",
  "vob": "", "voc": "󰎅", "vox": "󰎅", "vtt": "",
  "vue": "", "w64": "󰎅", "war": "", "wasm": "",
  "wat": "", "wav": "󰎅", "wbmp": "", "webloc": "",
  "webm": "", "webp": "", "whl": "󰌠", "wma": "󰎅",
  "wmv": "", "woff": "", "woff2": "", "wpd": "",
  "wv": "󰎅", "xapk": "󰓷", "xar": "", "xcf": "",
  "xhtml": "", "xls": "", "xlsm": "", "xlsx": "",
  "xm": "󰎅", "xml": "󰗀", "xpi": "", "xpm": "",
  "xsd": "󰗀", "xsl": "󰗀", "xslt": "󰗀", "xspf": "",
  "xz": "", "yaml": "", "yml": "", "yuv": "",
  "z": "", "zig": "", "zip": "", "zipx": "",
  "zon": "", "zoo": "", "zsh": "󰑷", "zst": "",
  "zstd": ""
};

// Own properties only. An archive holding a file called "constructor" or
// "__proto__" is a file called that, not a lookup that comes back with
// something off Object's prototype and renders as "[object Object]".
function ruleFor(table, key) {
  return Object.prototype.hasOwnProperty.call(table, key) ? table[key] : undefined;
}

function extensionOf(name) {
  const n = String(name);
  const cut = n.lastIndexOf(".");
  // a leading dot is a hidden file, not an extension: ".bashrc" has none
  if (cut <= 0 || cut === n.length - 1) return "";
  return n.slice(cut + 1).toLowerCase();
}

// The glyph for one entry, or "" when nothing claims it — which the caller
// draws as the plain page CONDS["!dir"] carries.
function glyphFor(entry) {
  if (!entry) return "";
  const name = String(entry.name || "").toLowerCase();

  if (entry.isDir) {
    const d = ruleFor(DIRS, name);
    if (d !== undefined) return d;
    return CONDS["dir"] || "";
  }

  if (entry.isLink && entry.broken && CONDS["orphan"] !== undefined)
    return CONDS["orphan"];

  const f = ruleFor(FILES, name);
  if (f !== undefined) return f;

  const ext = extensionOf(name);
  if (ext) {
    const e = ruleFor(EXTS, ext);
    if (e !== undefined) return e;
  }

  if (entry.isExec && CONDS["exec"] !== undefined) return CONDS["exec"];
  if (entry.isLink && CONDS["link"] !== undefined) return CONDS["link"];
  return CONDS["!dir"] || "";
}

// How many rules there are, which is the one thing about this table worth
// asserting from outside it: a parse that silently produced nothing is exactly
// what the old arrangement failed at, and a count that can be checked is how
// that failure stops being silent.
function ruleCount() {
  return Object.keys(CONDS).length + Object.keys(FILES).length
       + Object.keys(DIRS).length + Object.keys(EXTS).length;
}
