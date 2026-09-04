#!/usr/bin/env bash
# ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
# ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
# └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
# https://github.com/kbuckleys/
#
# VAULT PINENTRY — an Assuan server that answers GETPIN from vault's own
# password field instead of drawing a window.
#
# rbw never sees the passphrase: the client sends an Unlock message over the
# agent socket and rbw-agent spawns whatever `pinentry` names in
# ~/.config/rbw/config.json, then speaks Assuan to it. So the only supported
# way to feed a password in from elsewhere is to BE that program. Vault points
# the setting here itself (see ensureRbwConfig) so this needs no manual setup.
#
# WHEN VAULT IS NOT DRIVING, THIS IS THE SYSTEM PINENTRY. The fifo's existence
# is the whole signal, and the handover happens before a single Assuan line is
# read, so `rbw` from a terminal is completely unaffected — nothing has been
# consumed that the real pinentry would have needed.

FIFO="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vault-pinentry"
# Marks the one password vault sent as already spent. It has to be a FILE, not
# a shell variable: rbw-agent spawns a BRAND NEW pinentry process for its
# re-prompt, so an in-process flag resets and the fresh process sat on the read
# timeout waiting for a password nobody would write.
SPENT="${FIFO}.spent"
[ -p "$FIFO" ] || exec /usr/bin/pinentry "$@"

# Assuan escapes these three in a D line. % must go first or it would
# double-escape the ones added after it.
esc() {
  printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/\r/%0D/g'
}

printf 'OK Pleased to meet you\n'

while IFS= read -r line; do
  case "$line" in
    GETPIN*)
      # A re-prompt: the password vault sent was rejected. There is no second
      # one coming, so decline at once rather than blocking.
      if [ -e "$SPENT" ]; then
        printf 'ERR 83886179 Operation cancelled\n'
        continue
      fi
      # One LINE, not read-to-EOF: that way the handover does not depend on
      # vault closing its end of the pipe, which Quickshell's Process gives no
      # way to do. The timeout only covers a fifo left behind by a crashed
      # shell — vault queues the password before rbw even starts, so in the
      # normal case this returns immediately.
      pw=""
      IFS= read -r -t 10 pw < "$FIFO" 2>/dev/null
      : > "$SPENT" 2>/dev/null
      if [ -z "$pw" ]; then
        printf 'ERR 83886179 Operation cancelled\n'
      else
        printf 'D %s\nOK\n' "$(esc "$pw")"
        pw=
      fi
      ;;
    BYE*)
      printf 'OK closing connection\n'
      exit 0
      ;;
    '')
      ;;
    *)
      # SETDESC / SETPROMPT / SETTITLE / SETERROR / OPTION / GETINFO …
      printf 'OK\n'
      ;;
  esac
done
