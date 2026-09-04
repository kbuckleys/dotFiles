#!/bin/sh
# Open a "path:line" match from foot's regex mode in an editor.
# Wired up by [regex:paths] in foot.ini. foot passes the match as $1 and does
# not run the launcher through a shell, so the splitting happens here.

match=$1
file=${match%:*}
line=${match##*:}

# foot passes the match verbatim, so ~ has not been expanded by a shell
case $file in "~/"*) file="$HOME/${file#\~/}" ;; esac

exec footclient "${EDITOR:-nvim}" "+$line" "$file"
