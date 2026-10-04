#!/system/bin/sh
# neonova-save-panic-log.sh
#
# Saves the previous boot's kernel log (pstore / last_kmsg) before it is lost.
# After a kernel panic the log sits in /sys/fs/pstore until the next power-off or
# until something deletes it, so copy it out on every boot.
#
# Install (as root):
#   cp neonova-save-panic-log.sh /data/adb/service.d/
#   chmod 755 /data/adb/service.d/neonova-save-panic-log.sh
# Remove it by deleting that file.
#
# Output: /sdcard/Download/neonova-panic-logs/<date-time>/
# Proof that it ran at all: /data/local/tmp/neonova-panic-saver.log

OUT_BASE="${OUT_BASE:-/sdcard/Download/neonova-panic-logs}"
PSTORE="${PSTORE:-/sys/fs/pstore}"
LOG="${LOG:-/data/local/tmp/neonova-panic-saver.log}"

echo "$(date '+%Y-%m-%d %H:%M:%S') saver ran" >> "$LOG" 2>/dev/null

# nothing in pstore: nothing to save
if [ ! -d "$PSTORE" ] || [ -z "$(ls -A "$PSTORE" 2>/dev/null)" ]; then
  echo "  pstore empty, nothing to save" >> "$LOG" 2>/dev/null
  exit 0
fi

# the sdcard may not be mounted yet at this stage: wait up to about 3 minutes
PARENT="$(dirname "$OUT_BASE")"
i=0
while [ ! -d "$PARENT" ] && [ "$i" -lt 90 ]; do
  sleep 2
  i=$((i + 1))
done
[ -d "$PARENT" ] || OUT_BASE="/data/local/tmp/neonova-panic-logs"

DEST="$OUT_BASE/$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$DEST" || exit 1

cp -r "$PSTORE"/* "$DEST"/ 2>>"$LOG"
[ -r /proc/last_kmsg ] && cat /proc/last_kmsg > "$DEST/last_kmsg.txt" 2>/dev/null

{
  echo "uname: $(uname -a)"
  if command -v getprop >/dev/null 2>&1; then
    echo "boot reason (last): $(getprop sys.boot.reason.last)"
    echo "boot reason history:"
    getprop persist.sys.boot.reason.history
  fi
} > "$DEST/info.txt" 2>/dev/null

# only clear pstore once the copy is really there
if [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  rm -f "$PSTORE"/* 2>/dev/null
  echo "  saved to $DEST" >> "$LOG" 2>/dev/null
fi
exit 0
