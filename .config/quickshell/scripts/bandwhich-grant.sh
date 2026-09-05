#!/bin/sh
# ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
# ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
# └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
# https://github.com/kbuckleys/
#
# Everything zeus's net view needs from root, in one command, once per machine.
#
# Counting bytes on a wire means reading raw packets, and reading raw packets is
# privileged — there is no unprivileged path to it and this does not pretend
# there is. What it does is make the privileged part one thing you run once
# instead of a command to remember, and then keep it applied.
#
#   sudo <this script>       (or the "grant access" button, which pkexecs it)
#
# Idempotent, and it says what it changed.
#
# ── on keeping it applied ────────────────────────────────────────────────
# File capabilities live in an xattr on the binary, so they survive reboots and
# logins — but NOT an upgrade, which lands a new binary with an empty set. The
# failure is silent and months later, so something has to re-apply them, and
# what that something is depends on the distribution:
#
#   pacman        a hook, which is the native mechanism and runs exactly once
#                 per transaction
#   otherwise     a systemd path unit watching the binary, which is what every
#                 other package manager leaves us
#   neither       nothing to install; it says so rather than pretending
#
# Both are GENERATED here rather than shipped as files, so the paths in them are
# the ones actually found on this machine instead of Arch's spelling of them.

set -eu

# The four capabilities bandwhich itself names when it is run without them: two
# to capture, two to attribute what it captured to a process.
caps=cap_sys_ptrace,cap_dac_read_search,cap_net_raw,cap_net_admin+ep

if [ "$(id -u)" -ne 0 ]; then
  echo "needs root: sudo $0" >&2
  exit 1
fi

# setcap is /usr/bin on Arch and /sbin on Debian, so it is looked up, not spelled.
setcap_bin=$(command -v setcap 2>/dev/null || true)
if [ -z "$setcap_bin" ]; then
  echo "setcap not found — install libcap (Arch: libcap, Debian: libcap2-bin)." >&2
  exit 1
fi

bin=$(command -v bandwhich 2>/dev/null || true)
if [ -z "$bin" ]; then
  echo "bandwhich is not installed — install it first, then run this again." >&2
  exit 1
fi

"$setcap_bin" "$caps" "$bin"
echo "granted: $(getcap "$bin")"

# ── keep it applied across upgrades ──────────────────────────────────────
if command -v pacman >/dev/null 2>&1; then
  hook=/etc/pacman.d/hooks/bandwhich-setcap.hook
  mkdir -p "$(dirname "$hook")"
  cat > "$hook" <<EOF
# written by bandwhich-grant.sh — zeus's net view needs these capabilities,
# and an upgrade lands a binary without them.
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = bandwhich

[Action]
Description = Restoring capabilities on bandwhich...
When = PostTransaction
Exec = $setcap_bin $caps $bin
EOF
  chmod 644 "$hook"
  echo "installed: $hook (pacman hook)"

elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
  # No pacman, so there is no package-manager hook to hang this on. A path unit
  # watching the binary catches the replacement whoever does it — dpkg, rpm,
  # cargo install — which is the one thing they all have in common.
  cat > /etc/systemd/system/bandwhich-setcap.service <<EOF
[Unit]
Description=Restore capabilities on bandwhich

[Service]
Type=oneshot
ExecStart=$setcap_bin $caps $bin
EOF
  cat > /etc/systemd/system/bandwhich-setcap.path <<EOF
[Unit]
Description=Watch bandwhich for replacement

[Path]
PathChanged=$bin

[Install]
WantedBy=paths.target
EOF
  chmod 644 /etc/systemd/system/bandwhich-setcap.service \
            /etc/systemd/system/bandwhich-setcap.path
  systemctl daemon-reload
  systemctl enable --now bandwhich-setcap.path
  echo "installed: bandwhich-setcap.path (systemd watch)"

else
  echo "note: no pacman and no systemd here — nothing installed to re-apply" >&2
  echo "      the capabilities, so run this again after upgrading bandwhich." >&2
fi
