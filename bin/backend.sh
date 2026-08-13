#!/system/bin/sh

MODDIR=${1:-${0%/*}/..}
COMMAND=${2:-status}
STATE=${STR_STATE_DIR:-/data/adb/str-adblocker}
RUNTIME=${STR_RUNTIME_DIR:-/dev/str-adblocker}
DAEMON_LOG="$STATE/daemon.log"
HOSTS_SOURCE="$MODDIR/system/etc/hosts"
HOSTS_TARGET=${STR_HOSTS_TARGET:-/system/etc/hosts}
HOSTS_BIND_MARKER="$RUNTIME/hosts.bind"
PIDFILE="$RUNTIME/strd.pid"
SNAPSHOT="$RUNTIME/flowguard-state.json"
READYFILE="$RUNTIME/strd.ready"
START_LOCK="$RUNTIME/start.lock"
QUALIFICATION_HOLD="$RUNTIME/qualification.hold"
START_WAIT_TICKS=300
. "$MODDIR/bin/ruleset.sh"
. "$MODDIR/bin/owned_lock.sh"
. "$MODDIR/bin/runtime_identity.sh"

log_message() {
  log -t STR-AdBlocker "$*" 2>/dev/null || true
}

ensure_hosts_target() {
  [ -r "$HOSTS_SOURCE" ] || { log_message "Hosts source missing: $HOSTS_SOURCE"; return 1; }
  source_sha=$(sha256sum "$HOSTS_SOURCE" 2>/dev/null | awk '{ print $1; exit }')
  target_sha=$(sha256sum "$HOSTS_TARGET" 2>/dev/null | awk '{ print $1; exit }')
  # In-place source updates share the bound inode, so the target can already
  # be current while the marker still records an older digest. A digest-verified
  # target is success; refresh the marker without touching the mount.
  if [ -n "$source_sha" ] && [ "$source_sha" = "$target_sha" ]; then
    printf '%s\n' "$source_sha" > "$HOSTS_BIND_MARKER" 2>/dev/null || true
    chmod 0600 "$HOSTS_BIND_MARKER" 2>/dev/null || true
    return 0
  fi
  [ -e "$HOSTS_TARGET" ] || { log_message "Hosts target missing: $HOSTS_TARGET"; return 1; }
  # Android systemless setups keep the target as a writable bind of a module
  # file. Writing through the target updates the live view and the backing
  # inode in one step without a remount, which avoids EBUSY entirely. The
  # remount path below is only a fallback for read-only targets.
  if cat "$HOSTS_SOURCE" > "$HOSTS_TARGET" 2>/dev/null; then
    target_sha=$(sha256sum "$HOSTS_TARGET" 2>/dev/null | awk '{ print $1; exit }')
    if [ "$source_sha" = "$target_sha" ]; then
      printf '%s\n' "$source_sha" > "$HOSTS_BIND_MARKER" 2>/dev/null || true
      chmod 0600 "$HOSTS_BIND_MARKER" 2>/dev/null || true
      log_message "Hosts target written through and verified: $HOSTS_TARGET"
      return 0
    fi
  fi
  # A previous bind of an older hosts inode stays attached after the source
  # file is atomically replaced. Detach it before rebinding: mounting over an
  # existing mount can return EBUSY on Android and leave the stale target in
  # place. umount fails harmlessly when the target is not a mountpoint.
  if [ "$source_sha" != "$target_sha" ] && grep -q " $HOSTS_TARGET " /proc/self/mountinfo 2>/dev/null; then
    umount "$HOSTS_TARGET" 2>/dev/null || umount -l "$HOSTS_TARGET" 2>/dev/null || true
  fi
  mount_tool=/system/bin/mount
  [ -x "$mount_tool" ] || mount_tool=$(command -v mount 2>/dev/null)
  # A resolver or daemon may briefly hold the old mount open and make the
  # first rebind fail with EBUSY. Retry a few times before giving up.
  attempt=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    if [ -n "$mount_tool" ] && { "$mount_tool" -o bind "$HOSTS_SOURCE" "$HOSTS_TARGET" 2>/dev/null || "$mount_tool" --bind "$HOSTS_SOURCE" "$HOSTS_TARGET" 2>/dev/null; }; then
      break
    fi
    [ "$attempt" -lt 3 ] && sleep 0.2
  done
  target_sha=$(sha256sum "$HOSTS_TARGET" 2>/dev/null | awk '{ print $1; exit }')
  if [ "$source_sha" = "$target_sha" ]; then
    printf '%s\n' "$source_sha" > "$HOSTS_BIND_MARKER" 2>/dev/null || true
    chmod 0600 "$HOSTS_BIND_MARKER" 2>/dev/null || true
    log_message "Hosts target mounted and verified: $HOSTS_TARGET"
    return 0
  fi
  printf 'Hosts target mount failed: source=%s target=%s mountpoint=%s\n' \
    "$source_sha" "$target_sha" "$HOSTS_TARGET" >> "$DAEMON_LOG" 2>/dev/null || true
  log_message "Hosts target mount failed: $HOSTS_TARGET"
  return 1
}

unmount_hosts() {
  if grep -q " $HOSTS_TARGET " /proc/self/mountinfo 2>/dev/null; then
    umount "$HOSTS_TARGET" 2>/dev/null || umount -l "$HOSTS_TARGET" 2>/dev/null || true
  fi
  rm -f "$HOSTS_BIND_MARKER" 2>/dev/null || true
}

qualification_hold_active() {
  [ -s "$QUALIFICATION_HOLD" ] || return 1
  hold_deadline=$(sed -n '1p' "$QUALIFICATION_HOLD" 2>/dev/null)
  case "$hold_deadline" in
    ''|*[!0-9]*) rm -f "$QUALIFICATION_HOLD"; return 1 ;;
  esac
  if [ "$(date +%s)" -lt "$hold_deadline" ]; then
    return 0
  fi
  rm -f "$QUALIFICATION_HOLD"
  return 1
}

daemon_alive() {
  [ -s "$PIDFILE" ] || return 1
  pid=$(cat "$PIDFILE" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  runtime_process_matches "$pid" "$MODDIR/bin/strd" /proc
}

snapshot_value() {
  snapshot_key=$1
  snapshot_result=$(sed -n "s/.*\"$snapshot_key\" *: *\"\([^\"]*\)\".*/\1/p" "$SNAPSHOT" 2>/dev/null | head -n 1)
  [ -n "$snapshot_result" ] && { printf '%s\n' "$snapshot_result"; return; }
  snapshot_result=$(sed -n "s/.*\"$snapshot_key\" *: *\([0-9][0-9]*\).*/\1/p" "$SNAPSHOT" 2>/dev/null | head -n 1)
  [ -n "$snapshot_result" ] && { printf '%s\n' "$snapshot_result"; return; }
  snapshot_result=$(sed -n "s/.*\"$snapshot_key\" *: *true.*/true/p" "$SNAPSHOT" 2>/dev/null | head -n 1)
  [ -n "$snapshot_result" ] && { printf '%s\n' "$snapshot_result"; return; }
  sed -n "s/.*\"$snapshot_key\" *: *false.*/false/p" "$SNAPSHOT" 2>/dev/null | head -n 1
}

release_start_lock() {
  release_owned_lock "$START_LOCK"
}

acquire_start_lock() {
  acquire_owned_lock "$START_LOCK"
}

start_backend() {
  mkdir -p "$STATE" "$RUNTIME"
  chmod 0700 "$STATE"
	chmod 0700 "$RUNTIME"
  qualification_hold_active && return 1
  if ! acquire_start_lock; then
    count=0
    while [ "$count" -lt "$START_WAIT_TICKS" ]; do
      daemon_alive && return 0
      count=$((count + 1))
      sleep 0.1
    done
    return 1
  fi
  if daemon_alive; then
    release_start_lock
    return 0
  fi
  rm -f "$SNAPSHOT" "$PIDFILE" "$READYFILE"
  # One authoritative bounded daemon log under the module state directory.
  # /sdcard may not be mounted during early boot, so daemon diagnostics never
  # depend on it; stdout and stderr are captured into the same file.
  mkdir -p "$STATE" 2>/dev/null || true
  : > "$DAEMON_LOG" 2>/dev/null || true
  ensure_hosts_target || true
  mode=$(cat "$STATE/mode" 2>/dev/null)
  case "$mode" in observe|enforce) : ;; *) mode=enforce ;; esac
  if ! resolve_ruleset "$MODDIR" "$STATE" 1; then
	printf 'backend=fail-open state=FAIL_OPEN reason=ruleset_resolution_failed timestamp=%s\n' "$(date +%s)" > "$RUNTIME/backend"
    sh "$MODDIR/bin/notify.sh" "$MODDIR" FAIL_OPEN ruleset_resolution_failed &
    release_start_lock
    return 1
  fi
  set -- -rules "$RULES_PATH" \
    -manifest "$MANIFEST_PATH" \
    -ruleset-origin "$RULESET_ORIGIN" \
    -allowlist "$STATE/allowlist.txt" \
    -default-allowlist "$MODDIR/config/default-allowlist.txt" \
    -domain-blacklist "$STATE/domain-blacklist.txt" \
    -ip-blacklist "$STATE/ip-blacklist.txt" \
    -state "$SNAPSHOT" -ready-file "$READYFILE" -mode "$mode"
  if [ -n "${ENDPOINTS_PATH:-}" ] && [ -f "$ENDPOINTS_PATH" ]; then
    set -- "$@" -endpoints "$ENDPOINTS_PATH"
  fi
  STR_RESIDENT_LOG="$DAEMON_LOG" GODEBUG=madvdontneed=1 "$MODDIR/bin/strd" "$@" >> "$DAEMON_LOG" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$PIDFILE"
  chmod 0600 "$PIDFILE"
  count=0
  while [ "$count" -lt "$START_WAIT_TICKS" ]; do
    [ -d "/proc/$pid" ] || break
    if [ -s "$SNAPSHOT" ] && [ "$(cat "$READYFILE" 2>/dev/null)" = "$pid" ] && \
      runtime_process_matches "$pid" "$MODDIR/bin/strd" /proc; then
      state=$(snapshot_value backend_state)
      reason=$(snapshot_value reason)
      printf 'backend=flowguard-profile-f state=%s reason=%s timestamp=%s\n' \
	  "${state:-unknown}" "${reason:-unknown}" "$(date +%s)" > "$RUNTIME/backend"
	  chmod 0600 "$RUNTIME/backend"
      sh "$MODDIR/bin/notify.sh" "$MODDIR" "${state:-unknown}" "${reason:-unknown}" &
      log_message "FlowGuard started state=${state:-unknown} pid=$pid"
      release_start_lock
      return 0
    fi
    count=$((count + 1))
    sleep 0.1
  done
  if runtime_process_matches "$pid" "$MODDIR/bin/strd" /proc; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE" "$SNAPSHOT" "$READYFILE"
	printf 'backend=fail-open state=FAIL_OPEN reason=daemon_not_ready timestamp=%s\n' "$(date +%s)" > "$RUNTIME/backend"
    sh "$MODDIR/bin/notify.sh" "$MODDIR" FAIL_OPEN daemon_not_ready &
	log_message "FlowGuard startup failed: daemon_not_ready"
  if [ -s "$DAEMON_LOG" ]; then
    tail -n 20 "$DAEMON_LOG" | while IFS= read -r daemon_line; do
      log_message "daemon: $daemon_line"
    done
  fi
  release_start_lock
  return 1
}

stop_backend() {
  if daemon_alive; then
    pid=$(cat "$PIDFILE")
    kill "$pid" 2>/dev/null || true
    count=0
    while runtime_process_matches "$pid" "$MODDIR/bin/strd" /proc && [ "$count" -lt 30 ]; do
      count=$((count + 1))
      sleep 0.1
    done
    if runtime_process_matches "$pid" "$MODDIR/bin/strd" /proc; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$PIDFILE" "$READYFILE"
}

case "$COMMAND" in
  start) start_backend ;;
  stop) stop_backend ;;
  cleanup)
    stop_backend
    STR_RESIDENT_LOG="$DAEMON_LOG" GODEBUG=madvdontneed=1 "$MODDIR/bin/strd" -cleanup-dataplane >> "$DAEMON_LOG" 2>&1
    cleanup_status=$?
    if [ "$cleanup_status" -ne 0 ] && [ -s "$DAEMON_LOG" ]; then
      tail -n 20 "$DAEMON_LOG" | while IFS= read -r daemon_line; do
        log_message "cleanup: $daemon_line"
      done
    fi
    exit "$cleanup_status"
    ;;
  unmount-hosts) unmount_hosts ;;
  status) daemon_alive ;;
  ensure-hosts) ensure_hosts_target ;;
  *) echo "usage: backend.sh MODDIR {start|stop|cleanup|status|ensure-hosts}" >&2; exit 2 ;;
esac
