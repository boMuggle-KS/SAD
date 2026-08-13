#!/system/bin/sh

# Consumes control requests written by the companion app (no root in the app:
# it only writes a file into its own external directory) and executes them
# module-side as root. Runs independently of the service.sh supervisor loop so
# requests are served in every module state, including the 300s fail-open
# cooldown. Consume-and-delete uses a rename handshake: a request is moved to
# .proc before reading, so a newer request the app writes concurrently always
# lands in a fresh file and is never lost.
# Usage: control-watch.sh MODDIR

MODDIR=${1:-${0%/*}/..}
STATE=${STR_STATE_DIR:-/data/adb/str-adblocker}
RUNTIME=${STR_RUNTIME_DIR:-/dev/str-adblocker}
REQUEST_DIR=/storage/emulated/0/Android/data/com.str_adblocker.control/files
REQUEST="$REQUEST_DIR/sad.request"
REQUEST_PROC="$REQUEST_DIR/sad.request.proc"
WATCH_LOCK="$RUNTIME/control-watch.lock"
WATCH_PID="$RUNTIME/control-watch.pid"

. "$MODDIR/bin/owned_lock.sh"

acquire_owned_lock "$WATCH_LOCK" || exit 0
trap 'release_owned_lock "$WATCH_LOCK"; rm -f "$WATCH_PID"' EXIT

printf '%s\n' "$$" > "$WATCH_PID" 2>/dev/null || true
chmod 0600 "$WATCH_PID" 2>/dev/null || true

push_current_state() {
  state=RUNNING
  reason=unknown
  if [ -e "$STATE/pause" ]; then
    state=PAUSED
    reason=user_paused
  elif [ -r "$RUNTIME/backend" ]; then
    state=$(sed -n 's/.*state=\([^ ]*\).*/\1/p' "$RUNTIME/backend" 2>/dev/null | head -n 1)
    reason=$(sed -n 's/.*reason=\([^ ]*\).*/\1/p' "$RUNTIME/backend" 2>/dev/null | head -n 1)
    case "$state" in ''|*[!A-Za-z0-9._-]*) state=RUNNING ;; esac
    case "$reason" in ''|*[!A-Za-z0-9._-]*) reason=unknown ;; esac
  fi
  sh "$MODDIR/bin/notify.sh" "$MODDIR" "$state" "$reason" force
}

consume_request() {
  [ -f "$REQUEST" ] || return 0
  mv -f "$REQUEST" "$REQUEST_PROC" 2>/dev/null || return 0
  req=$(sed -n '1p' "$REQUEST_PROC" 2>/dev/null)
  case "$req" in
    pause)
      : > "$STATE/pause" 2>/dev/null || true
      sh "$MODDIR/bin/backend.sh" "$MODDIR" stop >/dev/null 2>&1
      ;;
    resume)
      rm -f "$STATE/pause"
      ;;
    sync)
      push_current_state
      ;;
  esac
  rm -f "$REQUEST_PROC"
}

while [ -d "$MODDIR" ]; do
  consume_request
  sleep 2
done
