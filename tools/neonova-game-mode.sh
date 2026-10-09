#!/system/bin/sh
# neonova-game-mode.sh   on | off | status      (run as root)
#
# A reversible "game profile" for the Redmi Note 7 (SDM660: cpu0-3 little, cpu4-7 big).
# It raises the FLOOR of the big cluster and of the GPU so frequency ramp-up lag
# causes fewer frame drops while a game is running. It does not raise any maximum,
# does not touch thermal limits, and does not change the governor.
# Cost: more power and more heat while it is on. Turn it off when you stop playing,
# or just reboot: sysfs settings do not survive a restart.
#
# The percentages are starting points, not measured values. A higher percentage
# means a higher floor (smoother but warmer):
#   CPU_MIN_PCT=30 GPU_MIN_PCT=40 sh neonova-game-mode.sh on

SYS="${SYS:-/sys}"
STATE="${STATE:-/data/local/tmp/neonova-game-mode.state}"
CPU_MIN_PCT="${CPU_MIN_PCT:-30}"
GPU_MIN_PCT="${GPU_MIN_PCT:-40}"
BIG_CPUS="${BIG_CPUS:-4 5 6 7}"
GPU="$SYS/class/kgsl/kgsl-3d0/devfreq"

# pick <space separated numbers> <percent>: item at that percent of the sorted list
pick() {
  sorted="$(echo "$1" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n)"
  n="$(echo "$sorted" | wc -l)"
  [ "$n" -gt 0 ] || return 1
  i=$(( n * $2 / 100 ))
  [ "$i" -ge "$n" ] && i=$(( n - 1 ))
  echo "$sorted" | sed -n "$(( i + 1 ))p"
}

# set_val <file> <value>: remember the old value once, then write the new one
set_val() {
  [ -w "$1" ] || { echo "skip (not writable): $1"; return 1; }
  echo "$1=$(cat "$1")" >> "$STATE"
  echo "$2" > "$1" && echo "set $1 -> $2"
}

case "$1" in
  on)
    if [ -e "$STATE" ]; then echo "already on (state file exists). Run: off"; exit 1; fi
    : > "$STATE"
    # big cluster: floor = CPU_MIN_PCT of the way up the frequency list
    c0="${BIG_CPUS%% *}"
    freqs="$(cat "$SYS/devices/system/cpu/cpu$c0/cpufreq/scaling_available_frequencies" 2>/dev/null)"
    f="$(pick "$freqs" "$CPU_MIN_PCT")"
    max="$(cat "$SYS/devices/system/cpu/cpu$c0/cpufreq/scaling_max_freq" 2>/dev/null)"
    if [ -n "$f" ] && { [ -z "$max" ] || [ "$f" -le "$max" ]; }; then
      for c in $BIG_CPUS; do set_val "$SYS/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq" "$f"; done
    else
      echo "could not pick a big-cluster floor (freqs='$freqs' max='$max')"
    fi
    # GPU: floor = GPU_MIN_PCT of the way up
    g="$(pick "$(cat "$GPU/available_frequencies" 2>/dev/null)" "$GPU_MIN_PCT")"
    gmax="$(cat "$GPU/max_freq" 2>/dev/null)"
    if [ -n "$g" ] && { [ -z "$gmax" ] || [ "$g" -le "$gmax" ]; }; then
      set_val "$GPU/min_freq" "$g"
    else
      echo "could not pick a GPU floor (max='$gmax')"
    fi
    echo "game mode ON"
    ;;
  off)
    [ -s "$STATE" ] || { echo "nothing to restore"; rm -f "$STATE"; exit 0; }
    # restore in reverse order, so values are put back the way they were found
    for line in $(sort -r "$STATE" | sed 's/ /%20/g'); do
      f="${line%%=*}"; v="${line#*=}"
      echo "$v" > "$f" && echo "restored $f -> $v"
    done
    rm -f "$STATE"
    echo "game mode OFF"
    ;;
  status)
    if [ -e "$STATE" ]; then echo "game mode: ON"; cat "$STATE"; else echo "game mode: OFF"; fi
    c0="${BIG_CPUS%% *}"
    echo "big cluster min/max: $(cat "$SYS/devices/system/cpu/cpu$c0/cpufreq/scaling_min_freq" 2>/dev/null) / $(cat "$SYS/devices/system/cpu/cpu$c0/cpufreq/scaling_max_freq" 2>/dev/null)"
    echo "gpu min/max/cur:     $(cat "$GPU/min_freq" 2>/dev/null) / $(cat "$GPU/max_freq" 2>/dev/null) / $(cat "$GPU/cur_freq" 2>/dev/null)"
    ;;
  *)
    echo "usage: $0 on|off|status"; exit 2 ;;
esac
