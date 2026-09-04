#!/usr/bin/sh

# ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
# ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
# └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
# https://github.com/kbuckleys/
#
# The portal's file chooser, answered by janus instead of yazi in a terminal.
#
# xdg-desktop-portal-termfilechooser runs this and BLOCKS on it: whatever is in
# "$out" when this exits is what the asking application receives, and an empty
# file means the user cancelled.
#
# Two things this has to get right, both learned the hard way:
#
#   It must not hang when janus is not there. The first version waited on the
#   marker file forever, so a shell that was restarting — or simply not running
#   — left Firefox waiting on a dialog that was never going to appear, with
#   nothing anywhere saying why.
#
#   It must say what happened. The portal's own log reports only "could not
#   execute ...: exit code 0", which is true and useless. This keeps its own.

multiple="$1"
directory="$2"
save="$3"
path="$4"
out="$5"
debug="$6"

log="${XDG_CACHE_HOME:-$HOME/.cache}/janus/portal.log"
mkdir -p "$(dirname "$log")"
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$log"; }

# NOT `set -e`. Every failure here has a correct response that is not "die
# silently", and dying silently is what leaves the caller hanging.
if [ "$debug" = 1 ]; then
    set -x
fi

say "request multiple=$multiple directory=$directory save=$save path=$path"

: > "$out"
rm -f "$out.done"

if ! qs ipc call Janus pick "$multiple" "$directory" "$save" "$path" "$out" >>"$log" 2>&1; then
    say "janus did not answer the ipc call — is the shell running? cancelling"
    exit 0
fi

# No overall timeout: choosing a file takes as long as it takes, and cutting
# that short would hand the application a cancel nobody asked for. The guard is
# janus itself — if the shell goes away mid-pick, stop waiting rather than
# holding the caller open forever.
while [ ! -e "$out.done" ]; do
    sleep 0.1
    if ! qs ipc call Janus status >/dev/null 2>&1; then
        say "janus went away mid-pick; cancelling"
        rm -f "$out.done"
        exit 0
    fi
done

rm -f "$out.done"
say "answered with $(wc -l < "$out") path(s)"
