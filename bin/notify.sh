#!/system/bin/sh

# Deduplicated state broadcast to the companion control app. The companion
# app's receiver is guarded by a signature-level permission; the AOSP
# permission check grants uid 0 unconditionally, so root broadcasts pass
# while ordinary apps are blocked from spoofing.
# Usage: notify.sh MODDIR state reason [force]

MODDIR=${1:-${0%/*}/..}
state=$2
reason=$3
force=${4:-0}
STATE=${STR_STATE_DIR:-/data/adb/str-adblocker}
RUNTIME=${STR_RUNTIME_DIR:-/dev/str-adblocker}
NOTIFY_LAST="$RUNTIME/notify.last"

case "$state" in ''|*[!A-Za-z0-9._-]*) state=RUNNING ;; esac
case "$reason" in ''|*[!A-Za-z0-9._-]*) reason=unknown ;; esac

if [ "$force" != 1 ] && [ -r "$NOTIFY_LAST" ]; then
  notify_last=$(cat "$NOTIFY_LAST" 2>/dev/null)
  [ "$notify_last" = "$state|$reason" ] && exit 0
fi

[ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] || exit 0
command -v am >/dev/null 2>&1 || exit 0

am broadcast -n com.str_adblocker.control/.StateReceiver \
  -a com.str_adblocker.control.STATE \
  --es state "$state" --es reason "$reason" >/dev/null 2>&1 || true

printf '%s\n' "$state|$reason" > "$NOTIFY_LAST" 2>/dev/null || true
