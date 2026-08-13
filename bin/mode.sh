#!/system/bin/sh

MODDIR=${1:-${0%/*}/..}
MODE=${2:-}
STATE=/data/adb/str-adblocker
RUNTIME=/dev/str-adblocker
export STR_STATE_DIR="$STATE" STR_RUNTIME_DIR="$RUNTIME"
RESTART_WAIT_TICKS=100
. "$MODDIR/bin/owned_lock.sh"
. "$MODDIR/bin/lifecycle.sh"

case "$MODE" in
  observe|enforce) ;;
  *) echo "usage: mode.sh MODDIR {observe|enforce}" >&2; exit 2 ;;
esac

mkdir -p "$STATE" "$RUNTIME" || exit 1
printf '%s\n' "$MODE" > "$STATE/mode.new" || exit 1
chmod 0600 "$STATE/mode.new"
mv -f "$STATE/mode.new" "$STATE/mode" || exit 1
lifecycle_request_restart "$MODDIR" "$STATE" "mode_$MODE" desired_mode "$MODE" "$RESTART_WAIT_TICKS"
