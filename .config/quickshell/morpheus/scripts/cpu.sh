#!/usr/bin/env bash
# ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
# ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
# └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
# https://github.com/kbuckleys/

trim() { printf '%s' "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }

s1="$(mktemp)"
s2="$(mktemp)"
grep '^cpu' /proc/stat > "$s1"
sleep 0.3
grep '^cpu' /proc/stat > "$s2"

total_usage="$(
  awk '
    FNR==NR {
      if ($1 ~ /^cpu$/) { t = 0; for (i = 2; i <= NF; i++) t += $i; tall = t; tidle = $5 + $6 }
      next
    }
    {
      if ($1 ~ /^cpu$/) { t = 0; for (i = 2; i <= NF; i++) t += $i; t2 = t; i2 = $5 + $6 }
    }
    END { dt = t2 - tall; di = i2 - tidle; if (dt > 0) printf "%d", 100 * (dt - di) / dt }
  ' "$s1" "$s2"
)"
total_usage=${total_usage:-0}

cores=""
while read -r key val; do
  [ "$key" = "total" ] && continue
  cores="$cores  ${key#cpu} $val%\n"
done < <(awk '
    FNR==NR {
      if ($1 ~ /^cpu$/) { t = 0; for (i = 2; i <= NF; i++) t += $i; tall = t; tidle = $5 + $6 }
      else if ($1 ~ /^cpu[0-9]+$/) { t = 0; for (i = 2; i <= NF; i++) t += $i; c[$1 "t"] = t; c[$1 "i"] = $5 + $6 }
      next
    }
    {
      if ($1 ~ /^cpu[0-9]+$/) { t = 0; for (i = 2; i <= NF; i++) t += $i; ct[$1] = t; ci[$1] = $5 + $6 }
    }
    END {
      for (k in ct) {
        d = ct[k] - c[k "t"]; i = ci[k] - c[k "i"]
        if (d > 0) printf "%s %d\n", k, 100 * (d - i) / d
      }
    }
  ' "$s1" "$s2" | sort -V)

rm -f "$s1" "$s2"

name="$(trim "$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2)")"
[ -z "$name" ] && name="$(trim "$(lscpu 2>/dev/null | awk -F: '/^Model name/ {print $2; exit}')")"

threads="$(nproc 2>/dev/null)"
cores_count="$(lscpu 2>/dev/null | awk -F: '/^Core.*socket/ {gsub(/ /, "", $2); print $2; exit}')"
sockets="$(lscpu 2>/dev/null | awk -F: '/^Socket/ {gsub(/ /, "", $2); print $2; exit}')"
cores_count=$((cores_count * sockets))

freq=""
freqsum=0; freqn=0
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
  [ -f "$f" ] && { freqsum=$((freqsum + $(cat "$f"))); freqn=$((freqn + 1)); }
done
[ "$freqn" -gt 0 ] && freq="$((freqsum / freqn / 1000))"

temp=""
tp="$(find /sys/devices/platform/coretemp.0/hwmon -name 'temp1_input' 2>/dev/null | head -n1)"
[ -n "$tp" ] && temp="$(( $(cat "$tp") / 1000 ))"

load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
procs="$(cut -d' ' -f4 /proc/loadavg 2>/dev/null)"

tooltip="CPU: ${name}\nCores: ${cores_count:-?} cores / ${threads:-?} threads"
[ -n "$freq" ] && tooltip="$tooltip\nFrequency: $(awk -v f="$freq" 'BEGIN { printf "%.2f", f / 1000 }') GHz"
[ -n "$temp" ] && tooltip="$tooltip\nTemperature: ${temp}°C"
[ -n "$load" ] && tooltip="$tooltip\nLoad Average: ${load}"
[ -n "$procs" ] && tooltip="$tooltip\nRunning: ${procs}"
tooltip="$tooltip\n\nUsage: ${total_usage}%\n\nPer Core:"
tooltip="$tooltip\n$cores"
tooltip="$(printf '%b' "$tooltip")"

text=" <span foreground='#9bbfbf'>CPU</span>  ${total_usage}% "

jq -nc --argjson usage "$total_usage" --arg text "$text" --arg tooltip "$tooltip" \
  '{usage: $usage, text: $text, tooltip: $tooltip}'
