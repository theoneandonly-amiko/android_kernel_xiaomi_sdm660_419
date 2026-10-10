#!/system/bin/sh
# neonova-tool.sh : "Neonova Extra", a small root menu for the Redmi Note 7 (lavender)
#
#   su -c 'sh /data/local/tmp/neonova-tool.sh'          menu
#   su -c 'sh /data/local/tmp/neonova-tool.sh status'   one-shot status
#   su -c 'sh /data/local/tmp/neonova-tool.sh cleanup-game'   (only needed once, see below)
#
# There is no game profile any more: raising the CPU/GPU floors made the phone choke.
# If an old one is still active (or you want its leftover state file gone), run
# "cleanup-game": it puts the saved minimum frequencies back and deletes the file.
#
# Everything here changes live sysfs values or runs standard Android commands.
# It edits no system files, and every kernel setting goes back to normal on reboot.
# It probes what exists and skips what is missing, so it should not break on other builds.

SYS="${SYS:-/sys}"
PROC="${PROC:-/proc}"
STATE_DIR="${STATE_DIR:-/data/local/tmp}"
OLD_GAME_STATE="$STATE_DIR/neonova-game-mode.state"   # written by the removed game profile
CHG_STATE="$STATE_DIR/neonova-charge.state"
OUT_BASE="${OUT_BASE:-/sdcard/Download/neonova-panic-logs}"
PSTORE="${PSTORE:-$SYS/fs/pstore}"
CPU="$SYS/devices/system/cpu"
GPU="$SYS/class/kgsl/kgsl-3d0/devfreq"
BAT="$SYS/class/power_supply/battery"
ZRAM="$SYS/block/zram0"
ZDEV="${ZDEV:-/dev/block/zram0}"
IOQ="${IOQ:-$SYS/block/mmcblk0/queue}"
BIG_CPUS="${BIG_CPUS:-4 5 6 7}"

B='\033[1m'; C='\033[36m'; Y='\033[33m'; R='\033[31m'; G='\033[32m'; N='\033[0m'
say()   { printf '%b\n' "$*"; }
ask()   { printf '%b' "$1"; read -r REPLY || REPLY=q; }
pause() { [ -n "$NONINT" ] && return; ask "\n${C}Enter to continue...${N}"; }
rd()    { cat "$1" 2>/dev/null; }
num()   { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

banner() {
  printf '%b' "$C"
  cat <<'ART'
  _  _ ___ ___  _  _  _____   ___
 | \| | __/ _ \| \| |/ _ \ \ / /_\
 | .` | _| (_) | .` | (_) \ V / _ \
 |_|\_|___\___/|_|\_|\___/ \_/_/ \_\
ART
  printf '%b\n' "        ${Y}E X T R A${N}"
}

# set_val <state file> <file> <value>: remember the old value, then write the new one
set_val() {
  [ -w "$2" ] || { say "  ${Y}skip (not writable): $2${N}"; return 1; }
  echo "$2=$(cat "$2")" >> "$1"
  echo "$3" > "$2" && say "  set $2 -> $3"
}

# ---------------------------------------------------------------- 1) status
status() {
  say "${B}Kernel${N}   $(uname -r)   $(uname -v | cut -c1-40)"
  say "${B}Uptime${N}   $(cut -d' ' -f1 "$PROC/uptime" 2>/dev/null) s"
  for c in 0 4; do
    d="$CPU/cpu$c/cpufreq"; [ -d "$d" ] || continue
    say "${B}cpu$c${N}     $(rd $d/scaling_governor)  cur $(rd $d/scaling_cur_freq)  min $(rd $d/scaling_min_freq)  max $(rd $d/scaling_max_freq)"
  done
  [ -d "$GPU" ] && say "${B}GPU${N}      cur $(rd $GPU/cur_freq)  min $(rd $GPU/min_freq)  max $(rd $GPU/max_freq)  $(rd $GPU/governor)"
  [ -r "$IOQ/scheduler" ] && say "${B}I/O${N}      $(rd $IOQ/scheduler)"
  if [ -d "$ZRAM" ]; then
    say "${B}zram${N}     $(rd $ZRAM/comp_algorithm)   size $(( $(rd $ZRAM/disksize) / 1048576 )) MB   $(grep zram "$PROC/swaps" 2>/dev/null | tr -s ' \t' ' ' | cut -d' ' -f4) KB used"
  fi
  say "${B}Memory${N}   available $(( $(grep MemAvailable "$PROC/meminfo" 2>/dev/null | tr -s ' ' ' ' | cut -d' ' -f2) / 1024 )) MB"
  if [ -d "$BAT" ]; then
    t="$(rd $BAT/temp)"; num "$t" && bt="$(( t / 10 )).$(( t % 10 )) C"
    say "${B}Battery${N}  $(rd $BAT/capacity)%  $(rd $BAT/status)  temp ${bt:-?}  current $(rd $BAT/current_now)"
  fi
  for z in "$SYS"/class/thermal/thermal_zone*; do
    [ -r "$z/type" ] || continue
    case "$(rd $z/type)" in *cpu*|*gpu*|*tsens*) v="$(rd $z/temp)"; num "$v" && say "  $(rd $z/type): $(( v > 1000 ? v / 1000 : v )) C";; esac
  done 2>/dev/null | head -6
  command -v getprop >/dev/null 2>&1 && say "${B}Boot${N}     last reason: $(getprop sys.boot.reason.last)"
  [ -n "$(ls -A "$PSTORE" 2>/dev/null)" ] && say "  ${Y}pstore has files: use 'Save panic log'${N}"
  [ -e "$OLD_GAME_STATE" ] && say "  ${Y}an old game profile may still be active: run 'cleanup-game'${N}"
  return 0
}

# ---------------------------------------------------------------- cleanup of the removed game profile
cleanup_game() {
  [ -e "$OLD_GAME_STATE" ] || { say "no old game profile state found, nothing to do"; return; }
  if [ -s "$OLD_GAME_STATE" ]; then
    for line in $(sort -r "$OLD_GAME_STATE"); do
      f="${line%%=*}"; v="${line#*=}"
      [ -w "$f" ] && echo "$v" > "$f" && say "  restored $f -> $v"
    done
  fi
  rm -f "$OLD_GAME_STATE"; say "${G}old game profile state removed${N}"
}

# ---------------------------------------------------------------- 2) governor
governor() {
  for c in 0 4; do
    d="$CPU/cpu$c/cpufreq"; [ -w "$d/scaling_governor" ] || continue
    say "cpu$c (cluster): now $(rd $d/scaling_governor), available: $(rd $d/scaling_available_governors)"
    ask "  governor for this cluster (empty = skip): "; g="$REPLY"; [ -n "$g" ] || continue
    case " $(rd $d/scaling_available_governors) " in
      *" $g "*) [ "$c" = 0 ] && cl="0 1 2 3" || cl="$BIG_CPUS"
                for x in $cl; do echo "$g" > "$CPU/cpu$x/cpufreq/scaling_governor" 2>/dev/null; done
                say "  now: $(rd $d/scaling_governor)" ;;
      *) say "  ${R}not available${N}" ;;
    esac
  done
}

# ---------------------------------------------------------------- 3) I/O scheduler
iosched() {
  [ -w "$IOQ/scheduler" ] || { say "${R}no scheduler file${N}"; return; }
  say "I/O schedulers: $(rd $IOQ/scheduler)"
  ask "  scheduler (empty = skip): "; s="$REPLY"; [ -n "$s" ] || return
  case " $(rd $IOQ/scheduler | tr -d '[]') " in
    *" $s "*) echo "$s" > "$IOQ/scheduler" && say "  now: $(rd $IOQ/scheduler)" ;;
    *) say "  ${R}not available${N}" ;;
  esac
}

# ---------------------------------------------------------------- 4) zram
zram_apply() {  # zram_apply <algorithm> <bytes>; 10 = nothing was touched, 11 = needs rollback
  swapoff "$ZDEV" || return 10
  echo 1 > "$ZRAM/reset"            || return 11
  echo "$1" > "$ZRAM/comp_algorithm" || return 11
  echo "$2" > "$ZRAM/disksize"      || return 11
  mkswap "$ZDEV" >/dev/null         || return 11
  swapon "$ZDEV"                    || return 11
  return 0
}
zram_switch() {
  [ -d "$ZRAM" ] || { say "${R}no zram0${N}"; return; }
  algs="$(rd $ZRAM/comp_algorithm | tr -d '[]')"
  old="$(rd $ZRAM/comp_algorithm | sed 's/.*\[\(.*\)\].*/\1/')"
  oldsize="$(rd $ZRAM/disksize)"
  say "algorithm: $(rd $ZRAM/comp_algorithm)   size: $(( oldsize / 1048576 )) MB"
  ask "  algorithm (empty = keep $old): "; a="${REPLY:-$old}"
  case " $algs " in *" $a "*) ;; *) say "  ${R}not in the list${N}"; return;; esac
  ask "  size in MB, 512-4096 (empty = keep): "
  if [ -n "$REPLY" ]; then
    num "$REPLY" && [ "$REPLY" -ge 512 ] && [ "$REPLY" -le 4096 ] || { say "  ${R}bad size${N}"; return; }
    size=$(( REPLY * 1048576 ))
  else size="$oldsize"; fi
  [ "$a" = "$old" ] && [ "$size" = "$oldsize" ] && { say "  nothing to change"; return; }
  used="$(grep zram "$PROC/swaps" 2>/dev/null | tr -s ' \t' ' ' | cut -d' ' -f4)"; used="${used:-0}"
  avail="$(grep MemAvailable "$PROC/meminfo" | tr -s ' ' ' ' | cut -d' ' -f2)"
  if [ "$used" -gt 300000 ] || [ "$avail" -lt $(( used + 300000 )) ]; then
    say "  ${R}refused:${N} ${used} KB is in swap and ${avail} KB is free. swapoff has to pull it all back into RAM."
    say "  Reboot first and run this right after boot."; return
  fi
  say "  ${Y}switching: swap goes off for a moment${N}"
  zram_apply "$a" "$size"; rc=$?
  if [ $rc -eq 0 ]; then say "  ${G}done: $(rd $ZRAM/comp_algorithm)${N}"
  elif [ $rc -eq 10 ]; then say "  ${R}swapoff failed, nothing was changed${N}"
  else
    say "  ${R}failed, restoring $old / $(( oldsize / 1048576 )) MB${N}"
    zram_apply "$old" "$oldsize" && say "  ${G}restored${N}" || say "  ${R}RESTORE FAILED: reboot the phone${N}"
  fi
}

# ---------------------------------------------------------------- 5) apps and storage
dex() {
  command -v cmd >/dev/null 2>&1 || { say "${R}no 'cmd' command here${N}"; return; }
  say "1) run Android's own background dexopt job (the normal maintenance)"
  say "2) recompile all apps with speed-profile (slower, uses battery and gets warm)"
  ask "  choose (empty = back): "
  case "$REPLY" in
    1) cmd package bg-dexopt-job ;;
    2) say "  running, this can take several minutes..."; cmd package compile -m speed-profile -a ;;
  esac
}
trim() { command -v sm >/dev/null 2>&1 && sm fstrim || say "${R}no 'sm' command${N}"; }

# ---------------------------------------------------------------- 6) charging
charging() {
  node="$BAT/constant_charge_current_max"
  say "capacity $(rd $BAT/capacity)%  status $(rd $BAT/status)  current_now $(rd $BAT/current_now)  temp $(rd $BAT/temp)"
  [ -r "$node" ] || { say "${Y}no constant_charge_current_max on this kernel: nothing to control${N}"; return; }
  cur="$(rd $node)"; say "charge current limit now: $cur (assumed microamps = $(( cur / 1000 )) mA)"
  [ -s "$CHG_STATE" ] && say "  ${Y}an earlier limit is active; 'r' restores the original${N}"
  ask "  new limit in mA (lower only), r = restore, empty = back: "
  case "$REPLY" in
    r) [ -s "$CHG_STATE" ] && { v="$(sed 's/^[^=]*=//' "$CHG_STATE" | head -1)"; echo "$v" > "$node" && say "  restored $v"; rm -f "$CHG_STATE"; } || say "  nothing to restore" ;;
    '') ;;
    *) if num "$REPLY" && [ $(( REPLY * 1000 )) -ge 500000 ] && [ $(( REPLY * 1000 )) -lt "$cur" ]; then
         [ -s "$CHG_STATE" ] || set_val "$CHG_STATE" "$node" "$(( REPLY * 1000 ))" || return
         [ -s "$CHG_STATE" ] && echo "$(( REPLY * 1000 ))" > "$node"; say "  limit: $(rd $node)"
       else say "  ${R}refused: must be at least 500 mA and below the current limit${N}"; fi ;;
  esac
}

# ---------------------------------------------------------------- 7) panic log
panic_save() {
  [ -n "$(ls -A "$PSTORE" 2>/dev/null)" ] || { say "pstore is empty: no panic log to save"; return; }
  dest="$OUT_BASE/$(date '+%Y%m%d-%H%M%S')"; mkdir -p "$dest" || { say "${R}cannot create $dest${N}"; return; }
  cp -r "$PSTORE"/* "$dest"/
  { echo "uname: $(uname -a)"; command -v getprop >/dev/null 2>&1 && getprop sys.boot.reason.last; } > "$dest/info.txt" 2>/dev/null
  rm -f "$PSTORE"/* 2>/dev/null; say "${G}saved to $dest${N}"
}

# ---------------------------------------------------------------- menu
menu() {
  while true; do
    banner
    say "${B}1)${N} Status                      ${B}5)${N} Apps: dexopt jobs, storage trim"
    say "${B}2)${N} CPU governor                ${B}6)${N} Charging current limit"
    say "${B}3)${N} I/O scheduler               ${B}7)${N} Save panic log now"
    say "${B}4)${N} ZRAM: algorithm / size"
    [ -e "$OLD_GAME_STATE" ] && say "${Y}c)${N} Clean up the old game profile (it is removed; this restores what it changed)"
    say "${B}q)${N} Exit"
    ask "Choose: "
    case "$REPLY" in
      1) status; pause ;;
      2) governor; pause ;;
      3) iosched; pause ;;
      4) zram_switch; pause ;;
      5) dex; ask "  also trim storage now? (y/N): "; [ "$REPLY" = y ] && trim; pause ;;
      6) charging; pause ;;
      7) panic_save; pause ;;
      c|C) cleanup_game; pause ;;
      q|Q) exit 0 ;;
      *) say "${R}?${N}" ;;
    esac
  done
}

case "$1" in
  status) NONINT=1; status ;;
  cleanup-game) NONINT=1; cleanup_game ;;
  '')     menu ;;
  *)      echo "usage: $0 [status | cleanup-game]"; exit 2 ;;
esac
