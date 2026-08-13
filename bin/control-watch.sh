#!/system/bin/sh

# Consumes control requests written by the companion app (no root in the app:
# it only writes files into its own external directory) and executes them
# module-side as root. Runs independently of the service.sh supervisor loop so
# requests are served in every module state, including the 300s fail-open
# cooldown. Consume-and-delete uses a rename handshake: a request is moved to
# .proc before reading, so a newer request the app writes concurrently always
# lands in a fresh file and is never lost.
#
# Two request kinds:
#   sad.request      - control ops: pause / resume / sync (state push back)
#   sad.exec.request - shell command (base64) for the app-hosted WebUI bridge;
#                      result written to sad.exec.<id>.result and pushed to the
#                      app via EXEC_RESULT broadcast (no app-side polling).
#
# The app's external files dir is addressed via /data/media/0: since Android 14
# the /storage/emulated/0 FUSE view denies even root access to Android/data,
# while the raw /data/media/0 path stays readable for uid 0 on every version.
#
# Usage: control-watch.sh MODDIR

MODDIR=${1:-${0%/*}/..}
STATE=${STR_STATE_DIR:-/data/adb/str-adblocker}
RUNTIME=${STR_RUNTIME_DIR:-/dev/str-adblocker}
RAW_REQUEST_DIR=/data/media/0/Android/data/com.str_adblocker.control/files
FUSE_REQUEST_DIR=/storage/emulated/0/Android/data/com.str_adblocker.control/files
WATCH_LOCK="$RUNTIME/control-watch.lock"
WATCH_PID="$RUNTIME/control-watch.pid"
EXEC_ACTION=com.str_adblocker.control.EXEC_RESULT
EXEC_TIMEOUT=45
OUTPUT_CAP=262144
EXEC_LOG="$RUNTIME/exec.broadcast.log"

. "$MODDIR/bin/owned_lock.sh"

if [ -d "$RAW_REQUEST_DIR" ]; then
  REQUEST_DIR=$RAW_REQUEST_DIR
elif [ -d "$FUSE_REQUEST_DIR" ]; then
  REQUEST_DIR=$FUSE_REQUEST_DIR
else
  # Fall back anyway: the directory may appear when the app first runs.
  REQUEST_DIR=$RAW_REQUEST_DIR
fi

acquire_owned_lock "$WATCH_LOCK" || exit 0
trap 'release_owned_lock "$WATCH_LOCK"; rm -f "$WATCH_PID"' EXIT

printf '%s\n' "$$" > "$WATCH_PID" 2>/dev/null || true
chmod 0600 "$WATCH_PID" 2>/dev/null || true

REQUEST="$REQUEST_DIR/sad.request"
REQUEST_PROC="$REQUEST_DIR/sad.request.proc"
EXEC_REQUEST="$REQUEST_DIR/sad.exec.request"
EXEC_PROC="$REQUEST_DIR/sad.exec.request.proc"

# A watcher killed mid-consume leaves .proc files behind; they shadow nothing
# (fresh requests get fresh names) but would be re-consumed later, so drop them.
rm -f "$REQUEST_PROC" "$EXEC_PROC" 2>/dev/null || true

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

consume_exec() {
  [ -f "$EXEC_REQUEST" ] || return 0
  mv -f "$EXEC_REQUEST" "$EXEC_PROC" 2>/dev/null || return 0
  exec_id=$(awk -F= '$1 == "id" { print $2; exit }' "$EXEC_PROC" 2>/dev/null)
  exec_cmd=$(awk -F= '$1 == "cmd" { print $2; exit }' "$EXEC_PROC" 2>/dev/null)
  case "$exec_id" in ''|*[!A-Za-z0-9_-]*) rm -f "$EXEC_PROC"; return 0 ;; esac
  exec_out="$REQUEST_DIR/.exec-out.$$"
  exec_err="$REQUEST_DIR/.exec-err.$$"
  : > "$exec_out" 2>/dev/null || true
  : > "$exec_err" 2>/dev/null || true
  if [ -n "$exec_cmd" ] && command=$(printf '%s' "$exec_cmd" | base64 -d 2>/dev/null); then
    timeout "$EXEC_TIMEOUT" sh -c "$command" >"$exec_out" 2>"$exec_err"
    exec_errno=$?
    exec_errno=${exec_errno:-1}
  else
    exec_errno=1
    printf 'invalid exec request\n' > "$exec_err"
  fi
  exec_result="$REQUEST_DIR/sad.exec.$exec_id.result"
  exec_result_new="$exec_result.new"
  {
    printf 'errno=%s\n' "$exec_errno"
    printf 'stdout=%s\n' "$(head -c "$OUTPUT_CAP" "$exec_out" 2>/dev/null | base64 | tr -d '\n')"
    printf 'stderr=%s\n' "$(head -c "$OUTPUT_CAP" "$exec_err" 2>/dev/null | base64 | tr -d '\n')"
  } > "$exec_result_new" 2>/dev/null || true
  chmod 0644 "$exec_result_new" 2>/dev/null || true
  mv -f "$exec_result_new" "$exec_result" 2>/dev/null || true
  rm -f "$exec_out" "$exec_err" "$EXEC_PROC"
  [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] || return 0
  if ! command -v am >/dev/null 2>&1; then
    log -t STR-AdBlocker "exec result broadcast skipped: am not found in PATH" 2>/dev/null
    return 0
  fi
  exec_am_out=$(am broadcast --include-stopped-packages \
    -n com.str_adblocker.control/.StateReceiver \
    -a "$EXEC_ACTION" --es id "$exec_id" 2>&1)
  exec_am_errno=$?
  {
    printf '%s id=%s errno=%s out=%s\n' \
      "$(date +%s)" "$exec_id" "${exec_am_errno:-1}" "${exec_am_out:-empty}"
  } >> "$EXEC_LOG" 2>/dev/null || true
  if [ -f "$EXEC_LOG" ] && [ "$(stat -c %s "$EXEC_LOG" 2>/dev/null)" -gt 8192 ]; then
    tail -c 4096 "$EXEC_LOG" > "$EXEC_LOG.new" 2>/dev/null
    mv -f "$EXEC_LOG.new" "$EXEC_LOG" 2>/dev/null || true
  fi
  if [ "${exec_am_errno:-1}" != 0 ]; then
    log -t STR-AdBlocker "exec result broadcast failed: errno=${exec_am_errno:-1} ${exec_am_out:-}" 2>/dev/null
  fi
}

while [ -d "$MODDIR" ]; do
  consume_request
  consume_exec
  sleep 1
done
