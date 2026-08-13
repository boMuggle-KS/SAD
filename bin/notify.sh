#!/system/bin/sh

# Deduplicated state broadcast to the companion control app. The companion
# app's receiver is guarded by a signature-level permission; the AOSP
# permission check grants uid 0 unconditionally, so root broadcasts pass
# while ordinary apps are blocked from spoofing.
#
# --include-stopped-packages is required: a freshly (re)installed app sits in
# the stopped state until its first launch, and Android drops explicit
# broadcasts to stopped packages without the flag.
#
# The am output is captured into $RUNTIME/notify.broadcast.log instead of
# being discarded, so delivery failures are diagnosable on-device.
#
# Usage: notify.sh MODDIR state reason [force]

MODDIR=${1:-${0%/*}/..}
state=$2
reason=$3
force=${4:-0}
STATE=${STR_STATE_DIR:-/data/adb/str-adblocker}
RUNTIME=${STR_RUNTIME_DIR:-/dev/str-adblocker}
NOTIFY_LAST="$RUNTIME/notify.last"
NOTIFY_LOG="$RUNTIME/notify.broadcast.log"

case "$state" in ''|*[!A-Za-z0-9._-]*) state=RUNNING ;; esac
case "$reason" in ''|*[!A-Za-z0-9._-]*) reason=unknown ;; esac

if [ "$force" != 1 ] && [ -r "$NOTIFY_LAST" ]; then
  notify_last=$(cat "$NOTIFY_LAST" 2>/dev/null)
  [ "$notify_last" = "$state|$reason" ] && exit 0
fi

[ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] || exit 0
if ! command -v am >/dev/null 2>&1; then
  log -t STR-AdBlocker "state broadcast skipped: am not found in PATH" 2>/dev/null
  exit 0
fi

notify_output=$(am broadcast --include-stopped-packages \
  -n com.str_adblocker.control/.StateReceiver \
  -a com.str_adblocker.control.STATE \
  --es state "$state" --es reason "$reason" 2>&1)
notify_errno=$?
{
  printf '%s state=%s reason=%s errno=%s out=%s\n' \
    "$(date +%s)" "$state" "$reason" "${notify_errno:-1}" "${notify_output:-empty}"
} >> "$NOTIFY_LOG" 2>/dev/null || true
if [ -f "$NOTIFY_LOG" ] && [ "$(stat -c %s "$NOTIFY_LOG" 2>/dev/null)" -gt 8192 ]; then
  tail -c 4096 "$NOTIFY_LOG" > "$NOTIFY_LOG.new" 2>/dev/null
  mv -f "$NOTIFY_LOG.new" "$NOTIFY_LOG" 2>/dev/null || true
fi
if { [ "${notify_errno:-1}" != 0 ]; } || \
   { [ -n "$notify_output" ] && printf '%s' "$notify_output" | grep -qi 'security\|error\|exception\|not found\|no activity'; }; then
  log -t STR-AdBlocker "state broadcast failed: errno=${notify_errno:-1} ${notify_output:-}" 2>/dev/null
fi

printf '%s\n' "$state|$reason" > "$NOTIFY_LAST" 2>/dev/null || true
