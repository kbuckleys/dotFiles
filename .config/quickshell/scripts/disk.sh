#!/usr/bin/env bash
# ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
# ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
# └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
# https://github.com/kbuckleys/
#
# Disk throughput and capacity. Throughput is the reading that belongs next to
# the network graph — a number that moves — and capacity is the one that
# belongs beside it as text.

# /sys/block holds whole devices only, so partitions are not double counted.
# loop, zram and device-mapper nodes are shadows of storage that is already
# being counted somewhere else, so they are skipped.
sample() {
  local dev sectors_r=0 sectors_w=0
  for dev in /sys/block/*; do
    case "${dev##*/}" in
      loop*|zram*|ram*|dm-*|md*) continue ;;
    esac
    [ -r "$dev/stat" ] || continue
    # field 3 is sectors read, field 7 sectors written
    read -r _ _ r _ _ _ w _ < "$dev/stat" || continue
    sectors_r=$((sectors_r + r))
    sectors_w=$((sectors_w + w))
  done
  printf '%s %s\n' "$sectors_r" "$sectors_w"
}

read -r r1 w1 < <(sample)
sleep 0.3
read -r r2 w2 < <(sample)

# a sector is 512 bytes whatever the drive's own block size is: the kernel
# reports these in 512-byte units by definition
read_bps=$(awk -v a="$r1" -v b="$r2" 'BEGIN { printf "%d", (b - a) * 512 / 0.3 }')
write_bps=$(awk -v a="$w1" -v b="$w2" 'BEGIN { printf "%d", (b - a) * 512 / 0.3 }')
[ "$read_bps" -lt 0 ] 2>/dev/null && read_bps=0
[ "$write_bps" -lt 0 ] 2>/dev/null && write_bps=0

# capacity of the filesystem the shell itself is on, in bytes
df_line="$(df -P -B1 / 2>/dev/null | awk 'NR==2 { print $2, $3, $4, $5 }')"
read -r fs_total fs_used fs_avail fs_pct <<< "$df_line"
fs_total=${fs_total:-0}
fs_used=${fs_used:-0}
fs_avail=${fs_avail:-0}
used_pct="$(printf '%s' "${fs_pct:-0%}" | tr -d '%')"

gib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }

tooltip="Disk: / — $(gib "$fs_used") GiB used of $(gib "$fs_total") GiB"
tooltip="$tooltip\nFree: $(gib "$fs_avail") GiB (${used_pct}% used)"
tooltip="$(printf '%b' "$tooltip")"

jq -nc \
  --argjson read "$read_bps" --argjson write "$write_bps" \
  --argjson used "${used_pct:-0}" --argjson total "$fs_total" \
  --argjson usedBytes "$fs_used" --arg tooltip "$tooltip" \
  '{read: $read, write: $write, used: $used, total: $total,
    usedBytes: $usedBytes, tooltip: $tooltip}'
