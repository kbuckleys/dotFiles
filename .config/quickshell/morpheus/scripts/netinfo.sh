#!/usr/bin/env bash
# ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
# ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
# └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
# https://github.com/kbuckleys/

iface="$(awk '$2 == "00000000" { print $1; exit }' /proc/net/route 2>/dev/null)"
if [ -n "$iface" ]; then
  ip="$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  carrier="$(cat /sys/class/net/"$iface"/carrier 2>/dev/null || printf '0')"
  printf '%s|%s|%s\n' "$iface" "$ip" "$carrier"
else
  printf '||0\n'
fi
