#!/usr/bin/env lua

-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- ZENU Package Manager ~ Part of the ZENWORKS Suite
-- https://github.com/kbuckleys/

local HOME       = os.getenv("HOME")
local LOGO_PATH  = HOME .. "/.config/logo"
local AUR_CACHE  = HOME .. "/.cache/paru/packages.aur"
local CLONE_DIR  = HOME .. "/.cache/paru/clone"
local CACHE_DIR  = (os.getenv("XDG_CACHE_HOME") or (HOME .. "/.cache")) .. "/zenu"
local APP_DIR    = (os.getenv("XDG_DATA_HOME") or (HOME .. "/.local/share")) .. "/applications"
local PACMAN_LOG = "/var/log/pacman.log"
local PKG_CACHE  = "/var/cache/pacman/pkg"
local DEBUG      = os.getenv("ZENU_DEBUG") ~= nil

-- Passed into the row formatter with -v, so these stay the only definition.
-- Written as byte escapes rather than literal glyphs: these are Nerd Font
-- private-use codepoints that editors and copy-paste routinely mangle or
-- drop, and a silently empty icon shifts every field in the row.
-- \243\177\158\161 = U+F17A1 (available), \239\128\141 = U+F00D (installed)
local ICON_AVAIL = "\243\177\158\161"
local ICON_INST  = "\239\128\141"

local FZF_COLOR = "--color=fg+:#dfdfdd,bg+:#20242a,pointer:#e0d8a4,marker:#fab387,hl+:#b6e0a4,hl::#b6e0a4,spinner:#9bbfbf,border:#20242a"

-- Column geometry. The repo tag is right-aligned against the terminal edge
-- and everything else is derived from the width so the tag stays flush.
local REPO_W = 8 -- "MULTILIB"; testing repos fold to short tags that also fit
local SIZE_W = 9
local MARGIN = 4 -- fzf's pointer + multi-select marker gutter

-- low level helpers

-- os.execute returns true|nil plus an exit code on Lua 5.4+. Go through the
-- exit code explicitly so the truthiness does not silently invert on 5.1.
local function sh(cmd)
  local ok, _, code = os.execute(cmd)
  if type(ok) == "number" then return ok == 0 end
  return ok == true and (code == nil or code == 0)
end

-- Single-quote for /bin/sh. Package names come from the pacman database, but
-- they still reach the shell as data, so quote them like data.
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function capture(cmd)
  local f = io.popen(cmd, "r")
  if not f then return "" end
  local out = f:read("*a") or ""
  f:close()
  return out
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function lines_of(str)
  local t = {}
  for line in str:gmatch("([^\n]*)\n?") do
    if line ~= "" then t[#t + 1] = line end
  end
  return t
end

-- Wall clock, not os.clock(): almost all the time here is spent waiting on
-- pacman, paru and fzf, and os.clock() only counts this process's own CPU,
-- so it reports ~0 ms for exactly the operations worth measuring.
-- /proc/uptime avoids spawning `date` just to take a reading.
local function now_ms()
  local f = io.open("/proc/uptime", "r")
  if not f then return nil end
  local line = f:read("*l") or ""
  f:close()
  local up = tonumber(line:match("^(%S+)"))
  return up and up * 1000 or nil
end

local function timed(label, fn)
  if not DEBUG then return fn() end
  local t0 = now_ms()
  local a, b = fn()
  local t1 = now_ms()
  if t0 and t1 then
    io.stderr:write(string.format("[zenu] %-28s %6.0f ms\n", label, t1 - t0))
  end
  return a, b
end

-- run directory

-- One private directory per run instead of a scatter of os.tmpname() files.
-- os.tmpname() is tmpnam(3): a predictable path in a world-writable /tmp, and
-- the old code leaked one file per view toggle because the views never
-- returned. mktemp -d is unpredictable, and this all goes away in one rm -rf.
local RUNDIR = trim(capture("mktemp -d /tmp/zenu.XXXXXXXX 2>/dev/null"))
if RUNDIR == "" then
  io.stderr:write("ZENU: could not create a temporary directory\n")
  os.exit(1)
end

local function runpath(name)
  return RUNDIR .. "/" .. name
end

local function write_file(path, text)
  local f, err = io.open(path, "w")
  if not f then
    io.stderr:write("ZENU: cannot write " .. path .. ": " .. tostring(err) .. "\n")
    os.exit(1)
  end
  f:write(text)
  f:close()
  return path
end

local function write_script(name, text)
  local path = write_file(runpath(name), text)
  sh("chmod +x " .. shq(path))
  return path
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local out = f:read("*a") or ""
  f:close()
  return out
end

local function cleanup()
  if RUNDIR ~= "" and RUNDIR:match("^/tmp/zenu%.") then
    sh("rm -rf " .. shq(RUNDIR))
  end
end

-- cleanup() only runs on a normal exit; a SIGTERM, a closed terminal or a
-- SIGKILL leaves the directory behind, and plain Lua cannot trap signals.
-- Each run records its pid, so any earlier directory whose owner is gone
-- can be collected on the next start. mktemp -d makes these mode 700, so
-- this only ever touches our own.
local function sweep_stale()
  write_file(runpath("pid"), trim(capture("echo $PPID")))
  sh([[
    for d in /tmp/zenu.*/; do
      [ -d "$d" ] || continue
      p=$(cat "$d/pid" 2>/dev/null)
      if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then rm -rf "$d"; fi
    done 2>/dev/null
  ]])
end

-- terminal

local function term_size()
  -- tput's own stdout is a pipe here (we're capturing it), not the
  -- terminal, so it can't determine the real size via ioctl and may
  -- silently fall back to a stale default. Query /dev/tty directly
  -- instead, which always refers to the actual controlling terminal.
  local out = capture("stty size < /dev/tty 2>/dev/null")
  local rows, cols = out:match("(%d+)%s+(%d+)")
  local h, w = tonumber(rows), tonumber(cols)
  -- `or 80` is not enough: a detached or not-yet-sized tty reports "0 0",
  -- and tonumber("0") is 0, which is truthy in Lua. That collapsed every
  -- column to the minimum instead of falling back.
  if not w or w < 40 then w = 80 end
  if not h or h < 10 then h = 24 end
  return h, w
end

local function term_width()
  local _, w = term_size()
  return w
end

-- Centers header text across the terminal, by codepoint count rather than
-- byte count.
--
-- Two corrections over the previous version, which sat five columns left
-- of centre:
--
--   * No extra allowance for the 󰇙 separator. It is a Nerd Font
--     private-use codepoint, and terminals render those at one column
--     (private-use ranges are East_Asian_Width=Ambiguous, which kitty and
--     friends treat as narrow). The package rows already assume exactly
--     this for the status icons, and they line up. Counting each
--     separator as two pushed the text left by half their number.
--   * fzf indents the header by HEADER_INDENT columns; measured constant
--     across --multi / --no-input / bare. Subtract it so the text is
--     centred on the terminal rather than within the indented region.
local HEADER_INDENT = 2

local function center_text(text, width)
  local len = (utf8 and utf8.len(text)) or #text
  local pad = math.floor((width - len) / 2) - HEADER_INDENT
  if pad < 0 then pad = 0 end
  return string.rep(" ", pad) .. text
end

local function show_logo()
  io.write(read_file(LOGO_PATH), "\n")
end

local function hard_clear()
  -- \027c is RIS, a full terminal reset that also wipes scrollback and
  -- resets charset/colors. Clear the screen and scrollback only.
  io.write("\027[H\027[2J\027[3J")
end

-- Terminals ship with XON/XOFF flow control enabled, which eats C-s (XOFF)
-- and C-q (XON) before fzf ever sees them -- C-s would appear to freeze the
-- UI rather than toggle the list. Turn it off for the run and put the
-- original termios back on the way out.
local SAVED_TTY = nil

local function tty_setup()
  SAVED_TTY = trim(capture("stty -g < /dev/tty 2>/dev/null"))
  sh("stty -ixon < /dev/tty 2>/dev/null")
end

local function tty_restore()
  if SAVED_TTY and SAVED_TTY ~= "" then
    sh("stty " .. SAVED_TTY .. " < /dev/tty 2>/dev/null")
    SAVED_TTY = nil
  end
end

local function pause(msg)
  io.write(msg or "\nPress RETURN to continue.")
  io.read("*l")
end

-- dependencies

local DEPS = {
  { pkg = "fzf",                     bin = "fzf",      why = "the interface itself" },
  { pkg = "gawk",                    bin = "gawk",     why = "the list formatter" },
  { pkg = "expac",                   bin = "expac",    why = "package size columns" },
  { pkg = "pacman-contrib",          bin = "paccache", why = "cache maintenance" },
  { pkg = "ttf-jetbrains-mono-nerd",                   why = "the icons and separators" },
}

local function have(bin)
  return sh("command -v " .. shq(bin) .. " >/dev/null 2>&1")
end

-- Font packages ship no binary, so `command -v` cannot see them. An entry
-- without a `bin` is checked against the package database instead.
local function dep_present(d)
  if d.bin then return have(d.bin) end
  return sh("pacman -Qq " .. shq(d.pkg) .. " >/dev/null 2>&1")
end

local function ensure_deps()
  local missing = {}
  for _, d in ipairs(DEPS) do
    if not dep_present(d) then missing[#missing + 1] = d end
  end
  if #missing == 0 then return end

  local names = {}
  for _, d in ipairs(missing) do names[#names + 1] = d.pkg end

  hard_clear()
  show_logo()
  print("  ZENU needs a few packages that aren't installed yet:")
  print("")
  for _, d in ipairs(missing) do
    print(string.format("    %-24s %s", d.pkg, d.why))
  end
  print("")
  sh("sudo pacman -S --needed --noconfirm " .. table.concat(names, " "))

  -- Everything after this point -- the paru bootstrap menu included -- is
  -- drawn by fzf, so a failed install here has to be said out loud rather
  -- than left to surface as a run of empty selections.
  local still = {}
  for _, d in ipairs(missing) do
    if not dep_present(d) then still[#still + 1] = d.pkg end
  end
  if #still > 0 then
    print("")
    print("  \027[1;31mStill missing: " .. table.concat(still, ", ") .. "\027[0m")
    pause()
  end
end

local function paru_installed()
  return sh("pacman -Qq paru >/dev/null 2>&1") or sh("pacman -Qq paru-git >/dev/null 2>&1")
end

-- sudo keep-alive

local sudo_pid   = nil
local sudo_ready = false

-- Held at file scope deliberately, and it must stay that way.
--
-- Lua closes io.popen handles from the garbage collector, and closing one
-- calls pclose(), which waits for the child to exit. The keep-alive child
-- loops until it is told to stop, so a handle left to fall out of scope
-- freezes the entire process the moment the collector happens to reach it
-- -- typically several screens later, looking like the terminal has just
-- gone blank. Keeping a live reference means it is only ever closed by
-- sudo_stop, which kills the child first so pclose returns at once.
local sudo_handle = nil

-- Deferred on purpose: browsing the package list needs no privileges, so
-- the password prompt only appears when something is actually about to be
-- installed or removed.
local function sudo_ensure()
  if sudo_ready then return true end
  if not sh("sudo -n true 2>/dev/null") then
    if not sh("sudo -v") then
      print("Auth failed.")
      return false
    end
  end
  sudo_ready = true

  local lua_pid = trim(capture("echo $PPID"))
  local keepalive = write_script("keepalive.sh", string.format([[
#!/usr/bin/env bash
echo $$
while true; do
  sudo -n true 2>/dev/null
  sleep 60
  kill -0 %s 2>/dev/null || exit
done
]], lua_pid))
  sudo_handle = io.popen(keepalive, "r")
  if sudo_handle then
    sudo_pid = trim(sudo_handle:read("*l") or "")
  end
  return true
end

local function sudo_stop()
  if sudo_pid and sudo_pid ~= "" then
    -- pkill -P first: killing the bash wrapper alone orphans its sleep.
    sh("pkill -P " .. sudo_pid .. " 2>/dev/null")
    sh("kill " .. sudo_pid .. " 2>/dev/null")
    sudo_pid = nil
  end
  if sudo_handle then
    -- Only safe once the child is gone: this pclose()es and would
    -- otherwise wait forever on the keep-alive loop.
    sudo_handle:close()
    sudo_handle = nil
  end
end

-- package data

local INSTALLED = nil

local function installed_set()
  if INSTALLED then return INSTALLED end
  INSTALLED = {}
  for _, pkg in ipairs(lines_of(capture("pacman -Qq 2>/dev/null"))) do
    INSTALLED[pkg] = true
  end
  return INSTALLED
end

local function invalidate()
  INSTALLED = nil
end

-- Fresh update check that needs no privileges at all.
--
-- The old code ran `paru -Sy` on every entry to the manage view (and again
-- on every return trip from the update view), which meant a password prompt
-- before you could even look at the list. `checkupdates` syncs into its own
-- private database under the user's cache instead of /var/lib/pacman/sync,
-- so it is just as fresh without root; `paru -Qua` covers the AUR side.
-- Both are run concurrently since the repo sync dominates the wall time.
local function fetch_updates()
  local cmd
  if have("checkupdates") then
    cmd = "{ checkupdates & paru -Qua --color=never & wait; } 2>/dev/null | sort -u"
  else
    -- Without pacman-contrib the best available is a check against whatever
    -- the system databases already hold.
    cmd = "paru -Qu --color=never 2>/dev/null | sort -u"
  end
  return lines_of(capture(cmd))
end

-- An explicit, user-initiated database sync. This is the only thing that
-- refreshes what the manage view considers "available", and it is offered
-- from the maintenance view rather than fired implicitly.
local function sync_repos()
  if not sudo_ensure() then return false end
  sh("sudo pacman -Sy")
  invalidate()
  return true
end

-- Replaces `paru --clean`, which ran after every transaction, emptied the
-- package cache entirely (destroying any ability to downgrade) and still
-- left pacman's interrupted download-* directories behind.
local function trim_cache()
  if not have("paccache") then return end
  if not sudo_ensure() then return end
  sh("sudo paccache -rk2 >/dev/null 2>&1")
end

-- list pipeline

-- Formats every package row in a single gawk pass fed by process
-- substitution. This replaces `paru -Sl` (923 ms for 133k lines) with
-- `pacman -Sl` plus paru's own AUR name cache (211 ms + 2 ms), and it
-- keeps the 16 MB of formatted rows out of the Lua heap entirely.
--
-- Emits, whitespace-delimited so fzf can address the fields directly:
--   1 = icon   2 = package name   3 = size   4 = repo tag
local LIST_AWK = [==[
BEGIN {
  # icon_avail / icon_inst arrive via -v from the Lua side.
  RESET = "\033[0m"; DIM = "\033[2m"

  # Short tag + color per repo. The old code assumed 8 columns was enough
  # for the longest tag ("MULTILIB") and used %8s, which pads but never
  # truncates -- so on a box with the testing repos enabled "CORE-TESTING"
  # and "EXTRA-TESTING" ran past the field and broke the right alignment.
  tag["core"]="CORE";               col["core"]="\033[36m"
  tag["extra"]="EXTRA";             col["extra"]="\033[32m"
  tag["multilib"]="MULTILIB";       col["multilib"]="\033[33m"
  tag["core-testing"]="CORE-T";     col["core-testing"]="\033[31m"
  tag["extra-testing"]="EXTRA-T";   col["extra-testing"]="\033[31m"
  tag["multilib-testing"]="MLIB-T"; col["multilib-testing"]="\033[31m"
  tag["aur"]="AUR";                 col["aur"]="\033[35m"
  tag["local"]="LOCAL";             col["local"]="\033[97m"

  name_fmt = "%-" pkg_w "s"
  size_fmt = "%" size_w "s"
  repo_fmt = "%" repo_w "s"
  pre["avail"] = icon_avail " "
  pre["inst"]  = icon_inst " "
  pre["dep"]   = DIM icon_inst " "
}
function human(b,   u, i) {
  if (b == "" || b + 0 <= 0) return "-"
  split("B K M G T", u, " ")
  i = 1
  while (b >= 1024 && i < 5) { b /= 1024; i++ }
  return sprintf((i == 1 ? "%d%s" : "%.1f%s"), b, u[i])
}
function tail(repo, state,   k, t, c) {
  k = repo SUBSEP state
  if (k in tailc) return tailc[k]
  if (repo in tag) { t = tag[repo]; c = col[repo] }
  else             { t = toupper(substr(repo, 1, repo_w)); c = "\033[37m" }
  if (state == "dep") c = DIM
  return tailc[k] = " " c sprintf(repo_fmt, t) RESET
}
function row(pkg, repo,   state, sz) {
  if      (!(pkg in inst)) { state = "avail"; sz = human(dsize[pkg]) }
  else if (pkg in expl)    { state = "inst";  sz = human(isize[pkg]) }
  else                     { state = "dep";   sz = human(isize[pkg]) }
  if (only == "installed" && state == "avail") return
  # Pad, never truncate: field 2 has to stay the real package name because
  # that is exactly what gets handed to pacman. The longest name in the
  # repos and the whole AUR is 66 characters, so at 100 columns or wider
  # nothing overflows; at 80 columns 35 names out of 133k push the size and
  # repo columns right, which is a better failure than acting on a clipped
  # name.
  print pre[state] sprintf(name_fmt, pkg) sprintf(size_fmt, sz) tail(repo, state)
}
ARGIND == 1 { inst[$1]  = 1; next }                   # pacman -Qq
ARGIND == 2 { expl[$1]  = 1; next }                   # pacman -Qeq
ARGIND == 3 { isize[$1] = $2; next }                  # expac -Q %n\t%m
ARGIND == 4 { dsize[$1] = $2; next }                  # expac -S %n\t%k
ARGIND == 5 {                                         # pacman -Sl
  split($0, f, " ")
  if (f[2] in seenrepo) next    # first repo wins, matching pacman's priority
  seenrepo[f[2]] = 1
  if (f[2] in inst) seen[f[2]] = 1
  row(f[2], f[1]); next
}
ARGIND == 6 {                                         # paru's AUR name cache
  if ($1 in seenrepo) next      # a real repo package shadows its AUR twin
  if ($1 in inst) seen[$1] = 1
  row($1, "aur"); next
}
END {
  # Installed packages that are in no sync database any more (dropped from
  # the repos, or installed with -U) would otherwise vanish from the list.
  for (p in inst) if (!(p in seen)) row(p, "local")
}
]==]

-- The generated rows are cached under XDG_CACHE_HOME and keyed on the
-- mtimes of the pacman databases plus the column width, so repeat launches
-- skip the work entirely.
local LIST_SH = [==[
#!/usr/bin/env bash
# usage: list.sh <pkg_w> <full|installed>
PKG_W="$1"; MODE="$2"
cache="$ZENU_CACHE_DIR/rows.$MODE.$PKG_W"
stampf="$cache.stamp"
t0="$EPOCHREALTIME"
dbg() { [ -n "$ZENU_DEBUG" ] || return 0
        printf '[zenu] %%-28s %%6.0f ms\n' "$1" \
          "$(echo "$EPOCHREALTIME $t0" | awk '{print ($1-$2)*1000}')" >&2; }
stamp="$(stat -c %%Y /var/lib/pacman/local /var/lib/pacman/sync "$ZENU_AUR" 2>/dev/null | tr '\n' ' ')"
stamp="$stamp|$(command -v expac >/dev/null 2>&1 && echo e || echo n)"

if [ -r "$cache" ] && [ -r "$stampf" ] && [ "$(cat "$stampf")" = "$stamp" ]; then
  cat "$cache"
  dbg "rows $MODE (cache hit)"
  exit 0
fi

mkdir -p "$ZENU_CACHE_DIR"
AUR="$ZENU_AUR"; [ -r "$AUR" ] || AUR=/dev/null

part="$cache.$$"
# Every stream is an inline process substitution. Assigning one to a
# variable first and expanding it later leaves a /dev/fd path whose
# validity depends on the shell keeping the descriptor open.
# The expac streams are empty when expac is missing, which just leaves the
# size column blank; gawk's ARGIND is positional so the file indices below
# stay correct either way.
# LC_ALL=C keeps gawk's substr/length byte-based; package names are ASCII
# and this is measurably faster over 133k rows.
LC_ALL=C gawk -v pkg_w="$PKG_W" -v size_w=%d -v repo_w=%d -v only="$MODE" \
  -v icon_avail=%s -v icon_inst=%s -f "$ZENU_AWK" \
  <(pacman -Qq 2>/dev/null) \
  <(pacman -Qeq 2>/dev/null) \
  <(command -v expac >/dev/null 2>&1 && expac -Q '%%n\t%%m' 2>/dev/null) \
  <(command -v expac >/dev/null 2>&1 && expac -S '%%n\t%%k' 2>/dev/null) \
  <(pacman -Sl 2>/dev/null) \
  "$AUR" | tee "$part"
if [ "${PIPESTATUS[0]}" -eq 0 ]; then
  mv -f "$part" "$cache" && printf '%%s' "$stamp" > "$stampf"
  dbg "rows $MODE (rebuilt)"
else
  rm -f "$part"
fi
]==]

-- Dispatches on what the row actually is instead of always reaching for
-- `paru -Si`, which costs 250 ms for a repo package and 542 ms over the
-- network for an AUR one -- on every cursor movement.
--
-- Every row now gets its real preview with no key press: the C-p "full
-- details" binding is gone, and the network lookup it used to gate is
-- cached on disk instead. Holding a cursor key down through the AUR
-- section would otherwise open one request per row.
local PREVIEW_SH = [==[
#!/usr/bin/env bash
# usage: preview.sh <pkg> [repo-tag]
#   AUR     installed info, else the cached AUR record
#   LOCAL   installed info only; the package is in no sync database
#   UPDATE  sync-database info first: this list is about what is coming,
#           not about the older version still on disk
#   (other) installed, then sync database, then AUR
pkg="$1"; repo="${2:-}"
[ -n "$pkg" ] || exit 0

# `paru -Si` is a network round trip. Cache it under the same directory the
# row cache uses and reuse it for half a day; a package name cannot contain
# a slash, so the name is the file name. Written via a temporary file so a
# preview that fzf kills mid-flight cannot leave a truncated record behind.
aur_info() {
  local dir="$ZENU_CACHE_DIR/aur-si" f out
  f="$dir/$1"
  if [ -s "$f" ] && [ -z "$(find "$f" -mmin +720 2>/dev/null)" ]; then
    cat "$f"
    return 0
  fi
  mkdir -p "$dir" 2>/dev/null
  if out=$(paru -Si -- "$1" 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out" >"$f.$$" && mv -f "$f.$$" "$f"
    printf '%s\n' "$out"
  elif [ -s "$f" ]; then
    # Stale, but offline or the AUR is unreachable: stale beats blank.
    cat "$f"
  else
    printf '\033[35m%s\033[0m\n\nAUR package. Details are unavailable right now.\n' "$1"
  fi
}

case "$repo" in
  UPDATE)
    pacman -Si -- "$pkg" 2>/dev/null || aur_info "$pkg"
    ;;
  AUR)
    pacman -Qi -- "$pkg" 2>/dev/null || aur_info "$pkg"
    ;;
  LOCAL)
    pacman -Qi -- "$pkg" 2>/dev/null ||
      printf '\033[97m%s\033[0m\n\nInstalled locally; not in any sync database.\n' "$pkg"
    ;;
  *)
    pacman -Qi -- "$pkg" 2>/dev/null ||
      pacman -Si -- "$pkg" 2>/dev/null ||
      aur_info "$pkg"
    ;;
esac
]==]

local AWK_PATH, LIST_PATH, PREVIEW_PATH

local function init_scripts()
  AWK_PATH     = write_file(runpath("list.awk"), LIST_AWK)
  LIST_PATH    = write_script("list.sh",
    string.format(LIST_SH, SIZE_W, REPO_W, shq(ICON_AVAIL), shq(ICON_INST)))
  PREVIEW_PATH = write_script("preview.sh", PREVIEW_SH)
end

-- Environment for the helper scripts, prefixed onto the commands that fzf
-- and io.popen run.
local function env_prefix()
  return "ZENU_CACHE_DIR=" .. shq(CACHE_DIR)
    .. " ZENU_AUR=" .. shq(AUR_CACHE)
    .. " ZENU_AWK=" .. shq(AWK_PATH)
    .. " ZENU_CLONE=" .. shq(CLONE_DIR)
    .. (DEBUG and " ZENU_DEBUG=1" or "")
    .. " "
end

local function pkg_width(w)
  -- icon + space + name + size + space + repo tag == usable width
  local pw = w - MARGIN - 2 - SIZE_W - 1 - REPO_W
  if pw < 10 then pw = 10 end
  return pw
end

local function list_cmd(w, mode)
  return env_prefix() .. shq(LIST_PATH) .. " " .. pkg_width(w) .. " " .. mode
end

-- fzf

-- Runs fzf over `input_cmd`'s stdout and returns its selection. fzf drives
-- the UI on /dev/tty, so its stdout is free to be a pipe we capture -- no
-- temporary file needed for the list.
local function fzf_cmd(input_cmd, args)
  return capture(input_cmd .. " | fzf " .. args .. " 2>/dev/null")
end

local function fzf_list(items, args)
  local input = type(items) == "table" and table.concat(items, "\n") or items
  local path = write_file(runpath("menu.txt"), input)
  return fzf_cmd("cat " .. shq(path), args)
end

local MENU_ARGS = table.concat({
  "--no-input", "--no-scrollbar", "--layout=reverse",
  "--border=top", "--info=hidden", FZF_COLOR,
}, " ")

local function menu(items, height)
  local args = MENU_ARGS .. " --height=" .. (height or (#items + 1))
  return trim(fzf_list(items, args))
end

local function header_arg(text, w)
  return '--header=' .. shq(center_text(text, w))
end

-- Views. Each returns the name of the next view, or nil to quit, so the
-- two package views no longer call each other recursively (which grew the
-- stack and leaked a switch file on every toggle).

local SWITCH = nil

local function read_switch()
  local v = trim(read_file(SWITCH))
  write_file(SWITCH, "")
  return v
end

-- transaction summaries

local function human_bytes(n)
  n = tonumber(n) or 0
  local units = { "B", "K", "M", "G", "T" }
  local i = 1
  while n >= 1024 and i < #units do n = n / 1024; i = i + 1 end
  if i == 1 then return string.format("%d%s", n, units[i]) end
  return string.format("%.1f%s", n, units[i])
end

-- Apparent size of a directory tree, for reporting reclaimed space.
--
-- The sudo prefix is not optional book-keeping. pacman's interrupted
-- download-* directories under /var/cache/pacman/pkg are mode 700 root, so
-- an unprivileged du silently skips exactly the bytes the cache view exists
-- to report -- "Remove stale download-* directories" always claimed it had
-- freed 0B. Every caller that removes anything takes sudo first, so by the
-- time the figure matters the credential is already there; -n keeps this
-- from ever turning a measurement into a password prompt.
local function dir_bytes(path)
  local pre = sudo_ready and "sudo -n " or ""
  return tonumber(trim(capture(
    pre .. "du -sb " .. shq(path) .. " 2>/dev/null | cut -f1"))) or 0
end

local function dir_human(path)
  return human_bytes(dir_bytes(path))
end

-- Wraps a list of package names to the terminal width.
local function print_names(names, indent, width)
  local line = ""
  for _, n in ipairs(names) do
    if line == "" then
      line = indent .. n
    elseif #line + #n + 2 <= width then
      line = line .. "  " .. n
    else
      print(line)
      line = indent .. n
    end
  end
  if line ~= "" then print(line) end
end

-- Installed size of every package, keyed by name. Per package rather than one
-- grand total: a net figure hides the shape of a transaction, and the sizes of
-- packages that get removed cannot be looked up once they are gone.
local function pkg_sizes()
  local t, n = {}, 0
  for _, line in ipairs(lines_of(capture("expac -Q '%n %m' 2>/dev/null"))) do
    local name, sz = line:match("^(%S+)%s+(%d+)$")
    if name then t[name] = tonumber(sz); n = n + 1 end
  end
  if n == 0 then return nil end -- expac missing or failed; not an empty system
  return t
end

-- What a sync transaction would cost, in bytes: what gets downloaded, what the
-- new versions occupy, and what the versions they replace hand back. Sizes come
-- from the sync databases, so AUR targets are absent by construction -- nothing
-- knows their size until they are built -- and get counted as `unknown` so the
-- caller can say the estimate is a floor rather than quietly understating it.
local function sync_cost(names, installed)
  local cost = { download = 0, add = 0, replace = 0, unknown = #names }
  if #names == 0 then return cost end

  local q = {}
  for _, n in ipairs(names) do q[#q + 1] = shq(n) end
  local raw = capture("expac -S '%n %m %k' " .. table.concat(q, " ") .. " 2>/dev/null")
  for _, line in ipairs(lines_of(raw)) do
    local name, size, dl = line:match("^(%S+)%s+(%d+)%s+(%d+)$")
    if name then
      cost.add = cost.add + tonumber(size)
      cost.download = cost.download + tonumber(dl)
      -- Already present means this is a replacement, not an addition: only
      -- the difference between the two versions actually lands on disk.
      cost.replace = cost.replace + (installed[name] or 0)
      cost.unknown = cost.unknown - 1
    end
  end
  return cost
end

-- What removing `names` hands back. Anything not in the local database is
-- already gone, so it contributes nothing rather than being an error.
local function remove_cost(names, installed)
  local total = 0
  for _, n in ipairs(names) do total = total + (installed[n] or 0) end
  return total
end

local function signed_bytes(n)
  return (n >= 0 and "+" or "-") .. human_bytes(math.abs(n))
end

-- Records the state a transaction will be measured against. Reading the
-- pacman log's size beforehand lets the summary afterwards report what
-- pacman *actually* did -- dependencies pulled in, packages orphaned and
-- removed, AUR builds -- rather than only what was asked for.
local function txn_mark()
  return {
    log   = tonumber(trim(capture("wc -c < " .. shq(PACMAN_LOG) .. " 2>/dev/null"))) or 0,
    sizes = pkg_sizes(),
  }
end

local VERBS = { "upgraded", "installed", "reinstalled", "downgraded", "removed" }

-- Everything appended to the log since the mark, bucketed by verb.
local function txn_events(mark)
  local ev, total = {}, 0
  for _, v in ipairs(VERBS) do ev[v] = {} end
  local raw = capture(string.format("tail -c +%d %s 2>/dev/null",
    (mark.log or 0) + 1, shq(PACMAN_LOG)))
  for _, line in ipairs(lines_of(raw)) do
    local verb, pkg, ver = line:match("%[ALPM%]%s+(%a+)%s+(%S+)%s+%((.-)%)")
    if verb and ev[verb] then
      -- "1.28.5-4 -> 1.28.6-1" for upgrades, a bare version otherwise.
      local old, new = ver:match("^(%S+)%s*%->%s*(%S+)$")
      ev[verb][#ev[verb] + 1] = { pkg = pkg, ver = ver, old = old, new = new }
      total = total + 1
    end
  end
  ev.total = total
  return ev
end

-- Bytes gained and bytes given back since the mark, counted per package so the
-- two sides stay visible. An upgrade contributes to whichever side it landed
-- on; without the split, a big install and a big removal in one transaction
-- cancel out and the summary reports a misleading "nothing much happened".
local function disk_delta(mark)
  local before = mark.sizes
  if not before then return nil end
  local after = pkg_sizes()
  if not after then return nil end

  local added, removed = 0, 0
  for name, sz in pairs(after) do
    local d = sz - (before[name] or 0) -- new packages, and upgrades that grew
    if d > 0 then added = added + d end
  end
  for name, sz in pairs(before) do
    local d = (after[name] or 0) - sz -- gone packages, and upgrades that shrank
    if d < 0 then removed = removed - d end
  end
  return added, removed
end

-- The Disk row shared by every transaction summary, or nil when nothing moved.
-- Both sides are shown only when both are non-zero: a plain install would
-- otherwise carry a "-0B" that means nothing.
local function disk_rows(mark)
  local added, removed = disk_delta(mark)
  if not added or (added == 0 and removed == 0) then return nil end

  local value
  if added > 0 and removed > 0 then
    value = string.format("+%s  -%s  \027[2mnet %s\027[0m",
      human_bytes(added), human_bytes(removed), signed_bytes(added - removed))
  elseif added > 0 then
    value = "+" .. human_bytes(added)
  else
    value = "-" .. human_bytes(removed)
  end
  return { { "Disk", value } }
end

local STD_MENU = { "Package Manager", "Check for updates", "Maintenance", "Quit" }

-- The one shared exit menu. Returns a view name rather than nil so callers
-- can tell "go to maintenance" apart from "quit".
local function finish_menu()
  local choice = menu(STD_MENU, #STD_MENU + 1)
  if choice == "Package Manager" then return "manage" end
  if choice == "Check for updates" then return "update" end
  if choice == "Maintenance" then return "maintain" end
  return "quit"
end

local SECTION_LABEL = {
  upgraded = "Upgraded", installed = "Installed", reinstalled = "Reinstalled",
  downgraded = "Downgraded", removed = "Removed",
}

-- Renders the summary block and the shared menu, returning the next view.
--
-- `extra` is for operations that leave no trace in the pacman log (cache
-- pruning, clone deletion): a list of {label, value} rows shown instead.
-- The listing is budgeted against the terminal height so a large upgrade
-- cannot push the menu off the bottom of the screen.
local function summary_screen(events, extra, ok)
  local h, w = term_size()
  hard_clear()
  show_logo()
  print("")

  if ok == false then
    print("  \027[1;31mTransaction failed\027[0m")
    print("  \027[2mAnything listed below did complete before it stopped.\027[0m")
    print("")
  end

  print("  \027[1mSummary\027[0m")
  print("")

  -- logo + heading + blanks + menu + margin
  local budget = h - 14
  if ok == false then budget = budget - 3 end
  if budget < 4 then budget = 4 end
  local used, clipped = 0, 0

  local function room(n) return used + n <= budget end

  if events then
    for _, verb in ipairs(VERBS) do
      local list = events[verb]
      if list and #list > 0 then
        print(string.format("    %-11s %4d", SECTION_LABEL[verb], #list))
        used = used + 1
        local pad = 0
        for _, e in ipairs(list) do if #e.pkg > pad then pad = #e.pkg end end
        if pad > 34 then pad = 34 end
        io.write("\027[2m")
        for _, e in ipairs(list) do
          if room(1) then
            local ver = e.old and (e.old .. " \u{2192} " .. e.new) or e.ver
            print(string.format("      %-" .. pad .. "s  %s", e.pkg, ver))
            used = used + 1
          else
            clipped = clipped + 1
          end
        end
        io.write("\027[0m")
      end
    end
  end

  if clipped > 0 then
    print(string.format("      \027[2m+ %d more\027[0m", clipped))
  end

  if extra then
    for _, row in ipairs(extra) do
      print(string.format("    %-11s %s", row[1], row[2]))
    end
  end

  local nothing = (not extra) and (not events or events.total == 0)
  if nothing then
    print("    Nothing changed.")
  end

  print("")
  return finish_menu()
end

-- history

local function history_entries(limit)
  limit = limit or 50
  -- Read backwards and stop at `limit`: the old version walked all 16,880
  -- lines of a 1.3 MB log, kept all 3,383 matches, then threw away all but
  -- the last 50 -- and did it again on every entry to the view.
  local raw = capture(string.format(
    "tac %s 2>/dev/null | grep -m %d -E '\\[ALPM\\] (installed|upgraded)' 2>/dev/null",
    shq(PACMAN_LOG), limit))

  local out = {}
  for _, e in ipairs(lines_of(raw)) do
    local date, action, pkg, ver = e:match("%[(.-)%]%s*%[ALPM%]%s*(%w+)%s+(.-)%s*%((.-)%)")
    if date and pkg then
      local tag = action == "upgraded" and "↑" or "+"
      out[#out + 1] = string.format("%s  %s  %s %s", date, tag, pkg, ver)
    else
      out[#out + 1] = e
    end
  end
  return out
end

-- Reads a history line back into the package name and the version it was
-- upgraded from, so a bad update can be rolled back to a cached package.
local function parse_history(line)
  local pkg, vers = line:match("[↑+]%s+(%S+)%s+(.+)$")
  if not pkg then return nil end
  local old = vers:match("^(%S+)%s*->")
  return pkg, old
end

-- Returns a view name when a transaction actually ran, nil otherwise so
-- the caller knows to show a plain Back menu instead of a summary.
local function downgrade(pkg, old)
  if not old then
    print("  That entry is a fresh install, not an upgrade - nothing to roll back to.")
    return nil
  end
  local pattern = string.format("%s/%s-%s-*.pkg.tar.*", PKG_CACHE, pkg, old)
  local found = lines_of(capture("ls -1 " .. pattern .. " 2>/dev/null | grep -v '\\.sig$'"))
  if #found == 0 then
    print(string.format("  No cached package for %s %s in %s.", pkg, old, PKG_CACHE))
    print("  Newly cached versions are kept from now on (paccache -rk2), so this")
    print("  will work for future downgrades.")
    return nil
  end
  if not sudo_ensure() then return nil end
  local mark = txn_mark()
  local ok = sh("sudo pacman -U " .. shq(found[1]))
  invalidate()
  return summary_screen(txn_events(mark), disk_rows(mark), ok)
end

local function history_view()
  local entries = history_entries(200)
  if #entries == 0 then
    hard_clear()
    print("  No history found.")
    print("")
    menu({ "Back" }, 2)
    return nil
  end
  local w = term_width()
  local args = table.concat({
    "--no-input", "--no-scrollbar", "--border=top", "--header-border=line",
    "--info=hidden", "--height=60%", "--reverse", FZF_COLOR,
    "--bind", shq("esc:abort"),
    header_arg("RETURN Downgrade  󰇙  ESC Close", w),
    -- Field 3 is the package name: the row is "<date> <tag> <pkg> <ver>"
    -- and the log's timestamp is a single unbroken token.
    "--preview", shq(env_prefix() .. PREVIEW_PATH .. " {3}"),
    '--preview-window=bottom:50%,noinfo',
  }, " ")
  local sel = trim(fzf_list(entries, args))
  if sel == "" then return nil end

  hard_clear()
  local pkg, old = parse_history(sel)
  local next_view
  if not pkg then
    print("  Could not read a package name from that entry.")
  else
    next_view = downgrade(pkg, old)
  end
  if not next_view then
    print("")
    menu({ "Back" }, 2)
  end
  return next_view
end

-- update view

local function update_view()
  while true do
    hard_clear()
    show_logo()
    print("")
    -- The repo sync is a real network download, so say so rather than
    -- leaving a blank screen for ten-odd seconds.
    io.write("  Checking for updates...")
    io.flush()
    local updates = timed("fetch_updates", fetch_updates)
    hard_clear()

    if #updates == 0 then
      show_logo()
      print("  No updates available.")
      print("")
      local choice = menu({ "Re-check for updates", "Package Manager", "Maintenance", "Quit" }, 5)
      if choice == "Package Manager" then return "manage"
      elseif choice == "Maintenance" then return "maintain"
      elseif choice == "Re-check for updates" then -- loop
      else return nil end
    else
      local w = term_width()
      local VER_W = 20
      local GAP   = 3
      local pkg_w = w - (VER_W * 2 + GAP + MARGIN)
      if pkg_w < 10 then pkg_w = 10 end

      local rows = {}
      for _, line in ipairs(updates) do
        local pkg, oldv, newv = line:match("^(%S+)%s+(%S+)%s+%-%>%s+(%S+)")
        pkg  = pkg or line
        oldv = oldv or ""
        newv = newv or ""
        rows[#rows + 1] = string.format(
          "%-" .. pkg_w .. "s%" .. VER_W .. "s" .. string.rep(" ", GAP) .. "%" .. VER_W .. "s",
          pkg:sub(1, pkg_w), oldv:sub(1, VER_W), newv:sub(1, VER_W))
      end

      local header = "TAB Flag  󰇙  C-a Invert  󰇙  C-r History  󰇙  C-u Manage  󰇙  C-t Maintain  󰇙  RETURN Sync"
      local args = table.concat({
        "--multi", "--no-input", "--no-scrollbar", FZF_COLOR,
        "--border=top", "--header-border=line",
        "--accept-nth", "1",
        -- Not ctrl-m: the terminal delivers it as carriage return, so
        -- binding it would shadow RETURN.
        "--bind", shq("esc:ignore,ctrl-a:toggle-all,ctrl-d:clear-multi"
          .. ",ctrl-r:execute-silent(echo history > " .. SWITCH .. ")+abort"
          .. ",ctrl-u:execute-silent(echo manage > " .. SWITCH .. ")+abort"
          .. ",ctrl-t:execute-silent(echo maintain > " .. SWITCH .. ")+abort"),
        header_arg(header, w),
        "--preview", shq(env_prefix() .. PREVIEW_PATH .. " {1} UPDATE"),
        '--preview-window=bottom:50%,noinfo',
      }, " ")

      local selected = fzf_list(rows, args)
      local switch = read_switch()
      if switch == "manage" then return "manage" end
      if switch == "maintain" then return "maintain" end
      if switch == "history" then
        local next_view = history_view()
        if next_view == "quit" then return nil end
        if next_view and next_view ~= "update" then return next_view end
      elseif trim(selected) ~= "" then
        local pkgs = {}
        for _, p in ipairs(lines_of(selected)) do
          p = trim(p)
          if p ~= "" then pkgs[#pkgs + 1] = shq(p) end
        end
        if #pkgs > 0 then
          if not sudo_ensure() then return nil end
          hard_clear()
          local mark = txn_mark()
          -- checkupdates syncs a private database, so /var/lib/pacman/sync
          -- is still whatever it was; the real databases have to be synced
          -- before anything is actually pulled in.
          local ok
          if #pkgs == #updates then
            ok = sh("paru -Syu --noconfirm")
          else
            print("\027[33mSelecting a subset is a partial upgrade, which Arch does not")
            print("support cleanly. Syncing first and installing only what you chose.\027[0m")
            print("")
            ok = sh("paru -Sy && paru -S --needed --noconfirm " .. table.concat(pkgs, " "))
          end
          invalidate()
          trim_cache()

          local next_view = summary_screen(txn_events(mark), disk_rows(mark), ok)
          if next_view == "manage" then return "manage"
          elseif next_view == "maintain" then return "maintain"
          elseif next_view == "quit" then return nil end
          -- "update": fall through and re-check
        end
      else
        -- ESC with nothing selected: offer a way out rather than looping.
        local choice = menu({ "Re-check for updates", "Package Manager", "Maintenance", "Quit" }, 5)
        if choice == "Package Manager" then return "manage"
        elseif choice == "Maintenance" then return "maintain"
        elseif choice == "Re-check for updates" then -- loop
        else return nil end
      end
    end
  end
end

-- manage view

-- Everything `-Rs` would take out besides the packages you picked.
-- Returns nil plus pacman's message when the removal is refused (usually
-- because something still depends on a target) -- worth catching here,
-- since the transaction itself runs with --noconfirm.
local function removal_deps(names)
  local q = {}
  for _, n in ipairs(names) do q[#q + 1] = shq(n) end
  local out = capture("pacman -Rs --print --print-format '%n' "
    .. table.concat(q, " ") .. " 2>&1")
  if out:match("error:") then return nil, trim(out) end

  local target = {}
  for _, n in ipairs(names) do target[n] = true end
  local deps = {}
  for _, p in ipairs(lines_of(out)) do
    if not target[p] then deps[#deps + 1] = p end
  end
  return deps
end

-- Everything that would be pulled in alongside the packages you picked.
-- `--needed` mirrors the flag the real install uses, so the preview and
-- the transaction agree. pacman cannot resolve AUR targets, so those come
-- back separately: only paru knows their dependencies, and working them
-- out means hitting the network.
local function install_deps(names)
  local function resolve(targets)
    local q = {}
    for _, n in ipairs(targets) do q[#q + 1] = shq(n) end
    local out = capture("pacman -S --needed --print --print-format '%n' "
      .. table.concat(q, " ") .. " 2>&1")
    if out:match("error:") then return nil end
    return lines_of(out)
  end

  local all, unresolved = resolve(names), {}
  if not all then
    -- One bad target fails the whole call, so fall back to per-target.
    all = {}
    for _, n in ipairs(names) do
      local r = resolve({ n })
      if r then
        for _, p in ipairs(r) do all[#all + 1] = p end
      else
        unresolved[#unresolved + 1] = n
      end
    end
  end

  local target, seen, deps = {}, {}, {}
  for _, n in ipairs(names) do target[n] = true end
  for _, p in ipairs(all) do
    if not target[p] and not seen[p] then
      seen[p] = true
      deps[#deps + 1] = p
    end
  end
  return deps, unresolved
end

-- You already picked the packages in the list; this confirms that choice
-- and nothing more, instead of handing you paru's full dependency dump.
local function confirm_transaction(ins_n, rem_n)
  local w = term_width()
  hard_clear()
  show_logo()
  print("")

  -- One local-database read for both halves of the screen: the install side
  -- needs it to tell an upgrade from an addition, the removal side to price
  -- what it is about to delete.
  local installed = pkg_sizes() or {}
  local gain, free, partial = 0, 0, false

  if #ins_n > 0 then
    print("  \027[32mInstall\027[0m")
    for _, p in ipairs(ins_n) do print("    " .. p) end
    local deps, unresolved = install_deps(ins_n)
    if #deps > 0 then
      print(string.format("    \027[2mwith %d dependenc%s:\027[0m",
        #deps, #deps == 1 and "y" or "ies"))
      io.write("\027[2m")
      print_names(deps, "      ", w - 2)
      io.write("\027[0m")
    end
    if #unresolved > 0 then
      print("    \027[2mdependencies for " .. table.concat(unresolved, ", ")
        .. " are resolved by paru during the build\027[0m")
    end

    local targets = {}
    for _, p in ipairs(ins_n) do targets[#targets + 1] = p end
    for _, p in ipairs(deps) do targets[#targets + 1] = p end
    local cost = sync_cost(targets, installed)
    gain = cost.add - cost.replace
    partial = cost.unknown > 0
    if cost.add > 0 then
      -- Only worth separating "Install" from "Disk" when some of the targets
      -- replace versions already on disk; otherwise the two are the same number.
      local line = string.format("    \027[2mDownload\027[0m %s   \027[2mDisk\027[0m %s",
        human_bytes(cost.download), signed_bytes(gain))
      if cost.replace > 0 then
        line = line .. string.format("   \027[2m(%s new, %s replaced)\027[0m",
          human_bytes(cost.add), human_bytes(cost.replace))
      end
      print(line)
    end
    if partial then
      print(string.format("    \027[2m%d AUR package%s not counted -- size is unknown until built\027[0m",
        cost.unknown, cost.unknown == 1 and "" or "s"))
    end
    print("")
  end

  local blocked = nil
  if #rem_n > 0 then
    print("  \027[31mRemove\027[0m")
    for _, p in ipairs(rem_n) do print("    " .. p) end
    local deps, err = removal_deps(rem_n)
    if not deps then
      blocked = err
    else
      if #deps > 0 then
        print(string.format("    \027[2mand %d package%s no longer required:\027[0m",
          #deps, #deps == 1 and "" or "s"))
        io.write("\027[2m")
        print_names(deps, "      ", w - 2)
        io.write("\027[0m")
      end
      local all = {}
      for _, p in ipairs(rem_n) do all[#all + 1] = p end
      for _, p in ipairs(deps) do all[#all + 1] = p end
      free = remove_cost(all, installed)
      if free > 0 then
        print(string.format("    \027[2mDisk\027[0m %s", signed_bytes(-free)))
      end
    end
    print("")
  end

  -- Only when both halves are non-empty: with one half the section line above
  -- is already the total, and repeating it just adds a line to read.
  if gain ~= 0 and free > 0 then
    print(string.format("  \027[1mNet\027[0m %s%s", signed_bytes(gain - free),
      partial and "  \027[2m(excluding AUR builds)\027[0m" or ""))
    print("")
  end

  if blocked then
    print("  \027[1;31mThis removal cannot proceed:\027[0m")
    for _, l in ipairs(lines_of(blocked)) do print("    " .. l:gsub("^error:%s*", "")) end
    print("")
    menu({ "Back" }, 2)
    return false
  end

  return menu({ "Confirm", "Cancel" }, 3) == "Confirm"
end

local function manage_view()
  -- Deliberately no sync here. `paru -Sy` needs root, and the whole point
  -- of deferring sudo is that browsing the list costs nothing. The list is
  -- built from whatever the local databases already hold; the update view
  -- is where freshness actually matters.
  while true do
    local w = term_width()
    local full_cmd = list_cmd(w, "full")
    local inst_cmd = list_cmd(w, "installed")

    local P_ALL  = "\027[38;2;155;191;191m  > \027[0m"
    local P_INST = "\027[38;2;155;191;191m  installed > \027[0m"

    -- fzf 0.74 can hold the toggle state itself: the transform reads the
    -- current prompt and emits the actions for the other mode. The old
    -- version kept the state in a temp file and pre-rendered both lists.
    -- [==[ ... ]==]: the bash [[ ... ]] test below contains ]] , which
    -- would close a plain Lua long string early.
    local toggle = write_script("toggle.sh", string.format([==[
#!/usr/bin/env bash
if [[ "$FZF_PROMPT" == *installed* ]]; then
  printf 'change-prompt(%%s)+reload(%%s)' %s %s
else
  printf 'change-prompt(%%s)+reload(%%s)' %s %s
fi
]==], shq(P_ALL), shq(full_cmd), shq(P_INST), shq(inst_cmd)))

    local header = "TAB Flag  󰇙  C-a Invert  󰇙  C-s Installed  󰇙  C-u Update  󰇙  C-t Maintain  󰇙  RETURN Sync"
    local args = table.concat({
      "--multi", "--ansi", "--no-scrollbar",
      "--nth", "2", "--accept-nth", "2",
      "--tiebreak=chunk,index",
      "--border=top", "--info=hidden", "--header-border=line",
      FZF_COLOR,
      -- transform(...) rather than transform:, which would swallow every
      -- binding after it. Not ctrl-m either: that is RETURN.
      "--bind", shq("esc:ignore,ctrl-a:toggle-all,ctrl-d:clear-multi"
        .. ",ctrl-s:transform(" .. toggle .. ")"
        .. ",ctrl-u:execute-silent(echo update > " .. SWITCH .. ")+abort"
        .. ",ctrl-t:execute-silent(echo maintain > " .. SWITCH .. ")+abort"),
      header_arg(header, w),
      "--prompt=" .. shq(P_ALL),
      "--preview", shq(env_prefix() .. PREVIEW_PATH .. " {2} {4}"),
      '--preview-window=bottom:50%,noinfo',
    }, " ")

    -- Not wrapped in timed(): this call spans the whole interactive fzf
    -- session, so it would measure how long you looked at the list. The
    -- list build reports its own timing from inside list.sh.
    local selected = fzf_cmd(full_cmd, args)

    local switch = read_switch()
    if switch == "update" then return "update" end
    if switch == "maintain" then return "maintain" end

    if trim(selected) ~= "" then
      -- fzf hands back field 2 verbatim, so there is no line to unpick and
      -- no risk of clipping a name; installed state comes from pacman.
      local inst = installed_set()
      local ins_n, ins_q, rem_n, rem_q = {}, {}, {}, {}
      for _, pkg in ipairs(lines_of(selected)) do
        pkg = trim(pkg)
        if pkg ~= "" then
          if inst[pkg] then
            rem_n[#rem_n + 1] = pkg; rem_q[#rem_q + 1] = shq(pkg)
          else
            ins_n[#ins_n + 1] = pkg; ins_q[#ins_q + 1] = shq(pkg)
          end
        end
      end

      if #ins_n > 0 or #rem_n > 0 then
        if confirm_transaction(ins_n, rem_n) then
          if not sudo_ensure() then return nil end
          hard_clear()
          local mark = txn_mark()
          -- Confirmation already happened here, so paru is not asked to
          -- prompt again with its own transaction listing.
          local ok = true
          if #ins_q > 0 then
            ok = sh("paru -S --needed --noconfirm " .. table.concat(ins_q, " ")) and ok
          end
          if #rem_q > 0 then
            ok = sh("paru -Rs --noconfirm " .. table.concat(rem_q, " ")) and ok
          end
          invalidate()
          trim_cache()

          local next_view = summary_screen(txn_events(mark), disk_rows(mark), ok)
          hard_clear()
          if next_view == "update" then return "update"
          elseif next_view == "maintain" then return "maintain"
          elseif next_view == "quit" then return nil end
          -- "manage": fall through and show the list again
        end
      end
    end
  end
end

-- maintenance view

-- pacdiff falls back to `vim -d` (and only to `nvim -d` when EDITOR is
-- exactly "nvim"), then dies if that binary is absent. ZENU used to force
-- DIFFPROG=vimdiff, which is not shipped by any Arch package at all, so the
-- action failed on every machine without a `vimdiff` in PATH. Pick the first
-- viewer that is genuinely installed, and leave a user-set DIFFPROG alone.
local DIFF_PROGS = {
  { bin = "nvim",    cmd = "nvim -d" },
  { bin = "vim",     cmd = "vim -d" },
  { bin = "vimdiff", cmd = "vimdiff" },
  { bin = "meld",    cmd = "meld" },
  { bin = "kdiff3",  cmd = "kdiff3" },
}

local function diff_prog()
  local env = os.getenv("DIFFPROG")
  if env and trim(env) ~= "" then return env end
  for _, d in ipairs(DIFF_PROGS) do
    if have(d.bin) then return d.cmd end
  end
  return nil
end

local function maint_orphans()
  local orphans = lines_of(capture("pacman -Qtdq 2>/dev/null"))
  hard_clear()
  if #orphans == 0 then
    print("  No orphaned packages.")
    print("")
    menu({ "Back" }, 2)
    return "maintain"
  end
  local w = term_width()
  local args = table.concat({
    "--multi", "--no-input", "--no-scrollbar", "--border=top",
    "--header-border=line", "--info=hidden", "--height=60%", "--reverse", FZF_COLOR,
    "--bind", shq("esc:abort,ctrl-a:toggle-all,ctrl-d:clear-multi"),
    header_arg("TAB Flag  󰇙  C-a Invert  󰇙  RETURN Remove  󰇙  ESC Back", w),
    "--preview", shq("pacman -Qi {1}"),
    '--preview-window=bottom:50%,noinfo',
  }, " ")
  local sel = fzf_list(orphans, args)
  local pkgs = {}
  for _, p in ipairs(lines_of(sel)) do
    p = trim(p)
    if p ~= "" then pkgs[#pkgs + 1] = shq(p) end
  end
  if #pkgs == 0 then return "maintain" end
  if not sudo_ensure() then return "maintain" end
  hard_clear()
  local mark = txn_mark()
  local ok = sh("sudo pacman -Rns " .. table.concat(pkgs, " "))
  invalidate()
  return summary_screen(txn_events(mark), disk_rows(mark), ok)
end

local function maint_pacnew()
  local files = lines_of(capture("pacdiff -o 2>/dev/null"))
  hard_clear()
  if #files == 0 then
    print("  No .pacnew or .pacsave files pending.")
    print("")
    menu({ "Back" }, 2)
    return "maintain"
  end
  print("  Pending configuration files:")
  print("")
  for _, f in ipairs(files) do print("    " .. f) end
  print("")
  local choice = menu({ "Review them now (pacdiff)", "Back" }, 3)
  if choice == "Review them now (pacdiff)" then
    local dp = diff_prog()
    if not dp then
      hard_clear()
      print("  No diff viewer is installed.")
      print("")
      print("  Install one of nvim, vim, meld or kdiff3, or set DIFFPROG to")
      print("  the viewer you want pacdiff to use.")
      print("")
      menu({ "Back" }, 2)
      return "maintain"
    end
    if not sudo_ensure() then return "maintain" end
    hard_clear()
    -- `pacdiff -s` is the supported way to run this from an unprivileged
    -- shell: it reaches for sudo and sudoedit only for the files it actually
    -- writes, rather than running the editor itself as root. The old call was
    -- `sudo -E DIFFPROG=... pacdiff`, and a default sudoers refuses both -E
    -- and a command-line variable assignment, so it never reached pacdiff.
    -- sudo_ensure above is still worth it: it stops the password prompt from
    -- landing in the middle of the merge.
    sh("DIFFPROG=" .. shq(dp) .. " pacdiff -s")
    -- pacdiff edits files rather than packages, so there is nothing in the
    -- pacman log to summarise; report what is still outstanding instead.
    local left = lines_of(capture("pacdiff -o 2>/dev/null"))
    return summary_screen(nil,
      { { "Reviewed", tostring(#files) },
        { "Remaining", tostring(#left) } }, true)
  end
  return "maintain"
end

-- Number of interrupted download-* directories left in the package cache.
local function stale_dirs()
  return trim(capture("find " .. shq(PKG_CACHE)
    .. " -maxdepth 1 -type d -name 'download-*' 2>/dev/null | wc -l"))
end

-- Bytes held by the cached package files, summed from find(1) rather than
-- measured with du(1). du cannot descend into the mode-700 download-*
-- directories, so it reports a "total" that silently omits them -- a wrong
-- number on the one screen whose whole job is reporting sizes. The sum of
-- the package files is exact without root, and the stale directories are
-- reported next to it by count, which is also exact.
local function pkg_cache_bytes()
  return tonumber(trim(capture("find " .. shq(PKG_CACHE)
    .. " -maxdepth 1 -name '*.pkg.tar.*' -printf '%s\\n' 2>/dev/null"
    .. " | awk '{t += $1} END {print t + 0}'"))) or 0
end

local function maint_pkgcache()
  hard_clear()
  local size    = human_bytes(pkg_cache_bytes())
  local pkgs    = trim(capture("find " .. shq(PKG_CACHE) .. " -maxdepth 1 -name '*.pkg.tar.*' 2>/dev/null | wc -l"))
  local stale   = stale_dirs()

  print("  Package cache: " .. PKG_CACHE)
  print("")
  print(string.format("    cached packages       %s, %s", pkgs, size))
  print(string.format("    stale download dirs   %s", stale))
  print("")
  print("  Stale download-* directories are left behind when a transaction is")
  print("  interrupted. They are never reused.")
  print("")

  local choice = menu({
    "Keep 2 versions per package (paccache -rk2)",
    "Remove stale download-* directories",
    "Back",
  }, 4)

  if choice:match("^Keep 2") then
    if not sudo_ensure() then return "maintain" end
    hard_clear()
    local before = pkg_cache_bytes()
    local ok = sh("sudo paccache -rk2")
    local after = trim(capture("find " .. shq(PKG_CACHE) .. " -maxdepth 1 -name '*.pkg.tar.*' 2>/dev/null | wc -l"))
    return summary_screen(nil, {
      { "Kept", after .. " package files (2 versions each)" },
      { "Freed", human_bytes(math.max(0, before - pkg_cache_bytes())) },
    }, ok)
  elseif choice:match("^Remove stale") then
    if not sudo_ensure() then return "maintain" end
    hard_clear()
    local before = dir_bytes(PKG_CACHE)
    local ok = sh("sudo find " .. shq(PKG_CACHE) .. " -maxdepth 1 -type d -name 'download-*' -exec rm -rf {} +")
    -- Count again rather than reporting the figure from before the sweep: a
    -- partial failure should say what is still sitting there.
    local left = tonumber(stale_dirs()) or 0
    local gone = math.max(0, (tonumber(stale) or 0) - left)
    return summary_screen(nil, {
      { "Removed", gone .. " stale download directories" },
      { "Freed", human_bytes(math.max(0, before - dir_bytes(PKG_CACHE))) },
      left > 0 and { "Left", left .. " could not be removed" } or nil,
    }, ok and left == 0)
  end
  return "maintain"
end

local function maint_clonecache()
  local raw = capture("du -sb " .. shq(CLONE_DIR) .. "/*/ 2>/dev/null | sort -rn")
  hard_clear()
  if trim(raw) == "" then
    print("  No AUR build clones cached.")
    print("")
    menu({ "Back" }, 2)
    return "maintain"
  end

  local inst = installed_set()
  local rows = {}
  for _, line in ipairs(lines_of(raw)) do
    local bytes, path = line:match("^(%d+)%s+(.+)$")
    if bytes then
      local name = path:gsub("/$", ""):match("([^/]+)$")
      local mark = inst[name] and "" or " (not installed)"
      rows[#rows + 1] = string.format("%8s  %s%s", human_bytes(bytes), name, mark)
    end
  end

  local w = term_width()
  local args = table.concat({
    "--multi", "--no-input", "--no-scrollbar", "--border=top",
    "--header-border=line", "--info=hidden", "--height=60%", "--reverse", FZF_COLOR,
    "--bind", shq("esc:abort,ctrl-a:toggle-all,ctrl-d:clear-multi"),
    "--accept-nth", "2",
    header_arg("TAB Flag  󰇙  C-a Invert  󰇙  RETURN Delete clone  󰇙  ESC Back", w),
    -- Field 2 is the clone directory's name, which is the AUR package name.
    "--preview", shq(env_prefix() .. PREVIEW_PATH .. " {2} AUR"),
    '--preview-window=bottom:50%,noinfo',
  }, " ")
  local sel = fzf_list(rows, args)
  if trim(sel) == "" then return "maintain" end

  local targets = {}
  for _, name in ipairs(lines_of(sel)) do
    name = trim(name)
    if name ~= "" then targets[#targets + 1] = shq(CLONE_DIR .. "/" .. name) end
  end
  if #targets == 0 then return "maintain" end

  hard_clear()
  print("  Removing " .. #targets .. " build clone(s)...")
  local before = dir_bytes(CLONE_DIR)
  local ok = sh("rm -rf " .. table.concat(targets, " "))
  return summary_screen(nil, {
    { "Removed", #targets .. " build clone(s)" },
    { "Freed", human_bytes(math.max(0, before - dir_bytes(CLONE_DIR))) },
    { "Note", "re-cloned on demand if you rebuild those packages" },
  }, ok)
end

local function maintenance_view()
  while true do
    hard_clear()
    show_logo()

    local orphans = trim(capture("pacman -Qtdq 2>/dev/null | wc -l"))
    local pacnew  = trim(capture("pacdiff -o 2>/dev/null | wc -l"))
    local cache   = human_bytes(pkg_cache_bytes())
    local stale   = stale_dirs()
    local clones  = dir_human(CLONE_DIR)

    print("")
    local synced = trim(capture("stat -c %Y /var/lib/pacman/sync 2>/dev/null"))
    local age = tonumber(synced) and math.floor((os.time() - tonumber(synced)) / 3600) or nil

    local items = {
      string.format("Orphaned packages          %s", orphans),
      string.format("Config files (.pacnew)     %s pending", pacnew),
      string.format("Package cache              %s in packages, %s stale download dirs", cache, stale),
      string.format("AUR build clones           %s", clones),
      string.format("Sync package databases     %s", age and (age .. "h old") or "unknown"),
      "Package Manager",
      "Check for updates",
      "Quit",
    }
    local choice = menu(items, #items + 1)

    if choice == "" or choice == "Quit" then return nil
    elseif choice == "Package Manager" then return "manage"
    elseif choice == "Check for updates" then return "update"
    else
      -- Sub-actions end on the shared menu, so they report where to go
      -- next; "maintain" means stay on this list.
      local next_view
      if     choice:match("^Orphaned")         then next_view = maint_orphans()
      elseif choice:match("^Config files")     then next_view = maint_pacnew()
      elseif choice:match("^Package cache")    then next_view = maint_pkgcache()
      elseif choice:match("^AUR build clones") then next_view = maint_clonecache()
      elseif choice:match("^Sync package databases") then
        hard_clear()
        if sync_repos() then
          next_view = summary_screen(nil,
            { { "Synced", "package databases" } }, true)
        end
      end
      if next_view == "quit" then return nil end
      if next_view and next_view ~= "maintain" then return next_view end
    end
  end
end

-- paru bootstrap

-- ZENU is a front end to paru, so without it there is nothing to drive. The
-- old code printed a git-clone incantation to copy by hand, which is exactly
-- what ensure_deps() puts fzf on the system to avoid. Both packages build the
-- same tool.
local PARU_CHOICES = {
  { pkg = "paru",     why = "latest tagged release" },
  { pkg = "paru-git", why = "tracks git master" },
}

local function build_from_aur(pkg)
  -- Built under the cache directory, not RUNDIR: /tmp is a tmpfs on a
  -- default Arch install and a Rust build tree is big enough for that to
  -- matter. Cleared before and after, so neither a failed build nor a
  -- successful one leaves a tree for the next attempt to trip over.
  local dir = CACHE_DIR .. "/build/" .. pkg
  local function drop() sh("rm -rf " .. shq(dir)) end

  drop()
  if not sh("mkdir -p " .. shq(dir)) then
    return false, "could not create " .. dir
  end

  print("  Cloning " .. pkg .. " from the AUR...")
  if not sh("git clone --quiet --depth 1 https://aur.archlinux.org/"
      .. pkg .. ".git " .. shq(dir)) then
    drop()
    return false, "could not clone " .. pkg
  end

  print("  Building " .. pkg .. ". This compiles Rust and takes a few minutes.")
  print("")
  -- makepkg refuses to run as root, so it is deliberately not run under
  -- sudo. Its -i step calls sudo itself, and the keep-alive started by
  -- sudo_ensure means that step does not stop to ask for a password again.
  local ok = sh("cd " .. shq(dir) .. " && makepkg -si --noconfirm --needed")
  drop()
  if not ok then
    return false, "the build failed -- scroll back for makepkg's output"
  end
  return true
end

-- A launcher entry, generated rather than shipped as a file: the Exec line
-- has to name wherever ZENU actually lives, and that is only known at run
-- time. Written during the first start, next to the paru build, and never
-- overwritten -- an entry already on disk may have been edited on purpose.
local DESKTOP_TEMPLATE = [[
[Desktop Entry]
Type=Application
Name=ZENU
GenericName=Package Manager
Comment=Packages, updates and cache maintenance, through paru
Exec=%s
Icon=system-software-install
Terminal=%s
Categories=System;PackageManager;
Keywords=pacman;paru;aur;package;update;
StartupNotify=false
Actions=update;maintain;

[Desktop Action update]
Name=Check for Updates
Exec=%s

[Desktop Action maintain]
Name=Maintenance
Exec=%s
]]

-- An Exec value is not a shell word: a path holding a reserved character has
-- to be quoted, and a few characters stay escaped inside the quotes.
local function desktop_arg(s)
  if not s:find('[%s"\'\\<>~|&;$*?#()`]') then return s end
  return '"' .. s:gsub('[\\"`$]', "\\%0") .. '"'
end

-- Returns "written", "kept" or "failed", plus the path or the reason.
local function install_desktop_entry()
  local self = trim(capture("realpath -- "
    .. shq((arg and arg[0]) or "") .. " 2>/dev/null"))
  if self == "" then
    return "failed", "could not work out where ZENU is installed"
  end

  local path = APP_DIR .. "/zenu.desktop"
  local existing = io.open(path, "r")
  if existing then
    existing:close()
    return "kept", path
  end

  -- Terminal=true leaves the choice of terminal to whatever reads the entry,
  -- and a launcher with none configured just does nothing at all. When
  -- xdg-terminal-exec is installed, name it instead: it resolves the terminal
  -- the same way the desktop's own handler does.
  local wrapped = have("xdg-terminal-exec")
  local function exec_line(mode)
    local cmd = desktop_arg(self) .. " " .. mode
    if wrapped then cmd = "xdg-terminal-exec --title=ZENU " .. cmd end
    return cmd
  end

  if not sh("mkdir -p " .. shq(APP_DIR)) then
    return "failed", "could not create " .. APP_DIR
  end

  -- Deliberately not write_file(): that exits the process on failure, and a
  -- launcher entry is not worth ending a successful bootstrap over.
  local f, err = io.open(path, "w")
  if not f then
    return "failed", "cannot write " .. path .. ": " .. tostring(err)
  end
  f:write(string.format(DESKTOP_TEMPLATE,
    exec_line("manage"), wrapped and "false" or "true",
    exec_line("update"), exec_line("maintain")))
  f:close()
  sh("chmod 644 " .. shq(path))

  -- Best effort: most launchers read the directory itself, and the ones that
  -- keep a cache want to be told.
  if have("update-desktop-database") then
    sh("update-desktop-database " .. shq(APP_DIR) .. " >/dev/null 2>&1")
  end
  return "written", path
end

local function install_paru()
  local items = {}
  for _, c in ipairs(PARU_CHOICES) do
    items[#items + 1] = string.format("%-10s %s", c.pkg, c.why)
  end
  items[#items + 1] = "Quit"

  hard_clear()
  show_logo()
  print("  paru is required and is not installed.")
  print("  Pick the one to build:")
  print("")

  -- The choice is the row, so take the package name back off the front
  -- rather than matching on the description text.
  local pkg = menu(items, #items + 1):match("^(%S+)")
  local wanted = false
  for _, c in ipairs(PARU_CHOICES) do
    if c.pkg == pkg then wanted = true end
  end
  if not wanted then return false end

  if not sudo_ensure() then return false end
  hard_clear()
  show_logo()
  print("  Installing build prerequisites...")
  print("")
  if not sh("sudo pacman -S --needed --noconfirm base-devel git") then
    print("")
    print("  \027[1;31mCould not install base-devel and git.\027[0m")
    pause()
    return false
  end
  print("")

  local built, err = build_from_aur(pkg)
  invalidate()

  hard_clear()
  show_logo()
  if built and paru_installed() then
    print("  \027[1;32m" .. pkg .. " installed.\027[0m")
    print("")
    local status, detail = install_desktop_entry()
    if status == "written" then
      print("  Launcher entry written to " .. detail .. ".")
    elseif status == "kept" then
      print("  Launcher entry already at " .. detail .. "; left alone.")
    else
      print("  \027[33mNo launcher entry: " .. detail .. "\027[0m")
    end
    pause()
    return true
  end
  print("  \027[1;31mCould not install " .. pkg .. ": "
    .. (err or "it is still not in the local database") .. "\027[0m")
  pause()
  return false
end

-- entry point

local VIEWS = {
  manage   = manage_view,
  update   = update_view,
  maintain = maintenance_view,
}

local function main()
  show_logo()
  ensure_deps()
  -- Before the paru bootstrap, not after: install_paru() builds inside
  -- RUNDIR, and sweep_stale() is what records this run's pid there. Without
  -- it a second ZENU starting mid-build would see an unclaimed directory and
  -- delete the tree out from under makepkg.
  sweep_stale()
  if not paru_installed() and not install_paru() then return end
  init_scripts()
  tty_setup()
  SWITCH = write_file(runpath("switch"), "")
  hard_clear()

  local mode = arg and arg[1]
  local view = (mode == "update") and "update"
    or (mode == "maintain" and "maintain")
    or "manage"

  -- A flat loop instead of the views calling each other: the old toggle
  -- path recursed without bound and never unwound.
  while view do
    local fn = VIEWS[view]
    if not fn then break end
    view = fn()
  end
end

local ok, err = pcall(main)
sudo_stop()
tty_restore()
cleanup()
if not ok then
  io.stderr:write("ZENU error: " .. tostring(err) .. "\n")
  print("\027[1;31mZENU crashed - press RETURN to close.\027[0m")
  io.read("*l")
  os.exit(1)
end
