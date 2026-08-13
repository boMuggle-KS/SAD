#!/system/bin/sh

MODDIR=${0%/*}
STATE=${STR_STATE_DIR:-/data/adb/str-adblocker}
RUNTIME=${STR_RUNTIME_DIR:-/dev/str-adblocker}
export STR_STATE_DIR="$STATE" STR_RUNTIME_DIR="$RUNTIME"
SNAPSHOT="$RUNTIME/flowguard-state.json"
QUALIFICATION_HOLD="$RUNTIME/qualification.hold"
RESTART_LOCK="$RUNTIME/restart.lock"
SUPERVISOR_LOCK="$RUNTIME/supervisor.lock"
CLOUD_UPDATE_MAX_SECONDS=600
. "$MODDIR/bin/owned_lock.sh"
. "$MODDIR/bin/runtime_identity.sh"
. "$MODDIR/bin/lifecycle.sh"

daemon_alive() {
  service_pid=$1
  runtime_process_matches "$service_pid" "$MODDIR/bin/strd" /proc
}

# The control watcher is a shell script, so runtime_process_matches (which
# compares /proc/pid/exe) cannot see it; match the script name in cmdline
# instead, which also guards against pid-file recycling.
control_watcher_alive() {
  control_pid=$(cat "$RUNTIME/control-watch.pid" 2>/dev/null)
  case "$control_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -d "/proc/$control_pid" ] || return 1
  tr '\000' ' ' < "/proc/$control_pid/cmdline" 2>/dev/null | grep -qF "control-watch.sh"
}

ensure_control_watcher() {
  control_watcher_alive && return 0
  sh "$MODDIR/bin/control-watch.sh" "$MODDIR" >/dev/null 2>&1 &
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

acquire_restart_lock() {
  service_lock_count=0
  while ! acquire_owned_lock "$RESTART_LOCK"; do
    [ "$service_lock_count" -ge 600 ] && return 1
    service_lock_count=$((service_lock_count + 1))
    sleep 0.1
  done
}

wait_qualification_hold() {
  hold_count=0
  while [ -s "$QUALIFICATION_HOLD" ] && [ "$hold_count" -lt 300 ]; do
    hold_deadline=$(sed -n '1p' "$QUALIFICATION_HOLD" 2>/dev/null)
    case "$hold_deadline" in ''|*[!0-9]*) break ;; esac
    [ "$(date +%s)" -lt "$hold_deadline" ] || break
    hold_count=$((hold_count + 1))
    sleep 0.1
  done
  rm -f "$QUALIFICATION_HOLD"
}

record_cloud_update() {
  record_state=$1
  record_message=$2
  record_stamp=$(date +%s)
  {
    printf 'state=%s\n' "$record_state"
    printf 'timestamp=%s\n' "$record_stamp"
    printf 'message=%s\n' "$record_message"
  } > "$STATE/cloud-update.last.new" 2>/dev/null || return 1
  chmod 0600 "$STATE/cloud-update.last.new" 2>/dev/null || return 1
  mv -f "$STATE/cloud-update.last.new" "$STATE/cloud-update.last" 2>/dev/null || return 1
}

run_cloud_update() {
  run_url=$1
  sh "$MODDIR/bin/update.sh" cloud "$run_url" >"$RUNTIME/cloud-update.log" 2>"$RUNTIME/cloud-update.err" &
  run_sh_pid=$!
  printf '%s\n' "$run_sh_pid" > "$RUNTIME/cloud-update.pid.new" 2>/dev/null
  chmod 0600 "$RUNTIME/cloud-update.pid.new" 2>/dev/null
  mv -f "$RUNTIME/cloud-update.pid.new" "$RUNTIME/cloud-update.pid" 2>/dev/null || true
  if wait "$run_sh_pid"; then
    run_token=$(cat "$STATE/rules.active" 2>/dev/null)
    record_cloud_update ok "${run_token:-updated}"
  else
    run_exit=$?
    run_message=$(tail -n 1 "$RUNTIME/cloud-update.log" 2>/dev/null | tr -d '\r')
    run_message=$(printf '%s' "$run_message" | LC_ALL=C tr -cd '[:print:]' | head -c 200)
    case "$run_message" in
      ''|'Downloading '*) run_message= ;;
    esac
    if [ -z "$run_message" ]; then
      case "$run_exit" in
        2) run_message="update_already_running" ;;
        3) run_message="download_failed" ;;
        4) run_message="validation_failed" ;;
        5) run_message="publish_failed" ;;
        6) run_message="published_restart_pending" ;;
        7) run_message="url_not_https" ;;
        124) run_message="update_timeout" ;;
        143) run_message="update_timeout" ;;
        *) run_message="update_exit=$run_exit" ;;
      esac
    fi
    record_cloud_update failed "${run_message:-update_exit=$run_exit}"
  fi
  rm -f "$RUNTIME/cloud-update.running" "$RUNTIME/cloud-update.pid" \
    "$RUNTIME/cloud-update.started" "$RUNTIME/cloud-update.stage" 2>/dev/null || true
}

cloud_update_alive() {
  cloud_pid=$1
  case "$cloud_pid" in ''|*[!0-9]*) return 1 ;; esac
  cloud_state=$(awk '{ print $3; exit }' "/proc/$cloud_pid/stat" 2>/dev/null)
  [ "$cloud_state" = "Z" ] && return 1
  kill -0 "$cloud_pid" 2>/dev/null
}

until [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ]; do sleep 2; done
mkdir -p "$STATE" "$RUNTIME"
chmod 0700 "$STATE" "$RUNTIME"
rm -f "$RUNTIME/cloud-update.running" 2>/dev/null || true
if ! acquire_owned_lock "$SUPERVISOR_LOCK"; then
  exit 0
fi
trap 'release_owned_lock "$SUPERVISOR_LOCK"' EXIT

ensure_control_watcher

failures=0
last_reason=unknown
while true; do
  # The module directory disappears during uninstall; never resurrect the
  # daemon or recreate the state directory after that.
  [ -d "$MODDIR" ] || exit 0
  if [ -e "$STATE/pause" ]; then
    if [ ! -e "$RUNTIME/pause.applied" ]; then
      sh "$MODDIR/bin/backend.sh" "$MODDIR" stop
      sh "$MODDIR/bin/backend.sh" "$MODDIR" cleanup >/dev/null 2>&1
      sh "$MODDIR/bin/backend.sh" "$MODDIR" unmount-hosts >/dev/null 2>&1
      : > "$RUNTIME/pause.applied" 2>/dev/null || true
    fi
    failures=0
    last_reason=user_paused
    printf 'backend=paused state=PAUSED reason=user_paused protection=paused timestamp=%s\n' "$(date +%s)" > "$RUNTIME/backend"
    sh "$MODDIR/bin/notify.sh" "$MODDIR" PAUSED user_paused &
    ensure_control_watcher
    sleep 2
    continue
  fi
  rm -f "$RUNTIME/pause.applied" 2>/dev/null || true
  started=$(date +%s)
  pid=
  if sh "$MODDIR/bin/backend.sh" "$MODDIR" start; then
    pid=$(cat "$RUNTIME/strd.pid" 2>/dev/null)
    # The kernel lease is the enforcement watchdog. Do not duplicate it in
    # shell: a delayed snapshot must not restart a live daemon or make the
    # user-visible state oscillate. The supervisor only owns process recovery.
    last_cloud_check=0
    while [ -n "$pid" ] && daemon_alive "$pid"; do
      cloud_now=$(date +%s)
      cloud_interval=129600
      if [ -r "$STATE/cloud-update-interval" ]; then
        cloud_interval=$(cat "$STATE/cloud-update-interval")
      fi
      case "$cloud_interval" in ''|*[!0-9]*) cloud_interval=129600 ;; esac
      [ "$cloud_interval" -ge 3600 ] || cloud_interval=3600
      [ "$cloud_interval" -le 604800 ] || cloud_interval=604800
      if [ -e "$RUNTIME/cloud-update.running" ]; then
        run_pid=$(cat "$RUNTIME/cloud-update.pid" 2>/dev/null)
        run_started=$(cat "$RUNTIME/cloud-update.started" 2>/dev/null)
        case "$run_started" in ''|*[!0-9]*) run_started=0 ;; esac
        if [ -n "$run_pid" ] && cloud_update_alive "$run_pid" && [ "$run_started" -gt 0 ] && \
            [ "$cloud_now" -ge $((run_started + CLOUD_UPDATE_MAX_SECONDS)) ]; then
          kill "$run_pid" 2>/dev/null || true
        fi
        # A marker without a tracked child (for example a run started by a
        # pre-0.5.149 supervisor) is stale: clear it so queued requests are
        # consumed instead of being blocked forever.
        if [ -z "$run_pid" ] || ! cloud_update_alive "$run_pid"; then
          rm -f "$RUNTIME/cloud-update.running" "$RUNTIME/cloud-update.pid" \
            "$RUNTIME/cloud-update.started" "$RUNTIME/cloud-update.stage" 2>/dev/null || true
        fi
      fi
      cloud_url=
      if [ ! -e "$RUNTIME/cloud-update.running" ] && [ ! -e "$RUNTIME/hosts-rebuild.running" ]; then
        if [ -s "$STATE/cloud-update.request" ]; then
          cloud_url=$(sed -n '1p' "$STATE/cloud-update.request" 2>/dev/null)
          rm -f "$STATE/cloud-update.request" 2>/dev/null || true
          case "$cloud_url" in https://*) : ;; *) cloud_url= ;; esac
        fi
        if [ -z "$cloud_url" ] && [ "$cloud_now" -ge $((last_cloud_check + cloud_interval)) ]; then
          cloud_url=$(cat "$STATE/cloud-update-url" 2>/dev/null)
          case "$cloud_url" in https://*) : ;; *) cloud_url= ;; esac
        fi
        if [ -n "$cloud_url" ]; then
          last_cloud_check=$cloud_now
          : > "$RUNTIME/cloud-update.running" 2>/dev/null || true
          printf '%s\n' "$cloud_now" > "$RUNTIME/cloud-update.started.new" 2>/dev/null
          chmod 0600 "$RUNTIME/cloud-update.started.new" 2>/dev/null
          mv -f "$RUNTIME/cloud-update.started.new" "$RUNTIME/cloud-update.started" 2>/dev/null || true
          run_cloud_update "$cloud_url" >/dev/null 2>&1 &
        fi
      fi
      # Hosts rebuild queue: allowlist saves write hosts-rebuild.request and
      # return immediately. Apply it once no cloud update owns the generation
      # lock; if update.sh still finds the lock busy it defers and keeps the
      # request, so this loop retries after the update completes.
      if [ -e "$RUNTIME/hosts-rebuild.running" ]; then
        rebuild_pid=$(cat "$RUNTIME/hosts-rebuild.pid" 2>/dev/null)
        if [ -z "$rebuild_pid" ] || ! cloud_update_alive "$rebuild_pid"; then
          rm -f "$RUNTIME/hosts-rebuild.running" "$RUNTIME/hosts-rebuild.pid" 2>/dev/null || true
        fi
      fi
      if [ ! -e "$RUNTIME/hosts-rebuild.running" ] && [ -s "$STATE/hosts-rebuild.request" ] && \
          [ ! -e "$RUNTIME/cloud-update.running" ]; then
        : > "$RUNTIME/hosts-rebuild.running" 2>/dev/null || true
        sh "$MODDIR/bin/update.sh" rebuild-hosts >"$RUNTIME/hosts-rebuild.log" 2>&1 &
        rebuild_sh_pid=$!
        printf '%s\n' "$rebuild_sh_pid" > "$RUNTIME/hosts-rebuild.pid.new" 2>/dev/null
        chmod 0600 "$RUNTIME/hosts-rebuild.pid.new" 2>/dev/null
        mv -f "$RUNTIME/hosts-rebuild.pid.new" "$RUNTIME/hosts-rebuild.pid" 2>/dev/null || true
      fi
      ensure_control_watcher
      sleep 2
    done
  fi
  stopped=$(date +%s)
  uptime=$((stopped - started))
  wait_qualification_hold
  if ! acquire_restart_lock; then
	printf 'backend=fail-open state=FAIL_OPEN reason=restart_lock_timeout timestamp=%s\n' "$(date +%s)" > "$RUNTIME/backend"
    sh "$MODDIR/bin/notify.sh" "$MODDIR" FAIL_OPEN restart_lock_timeout &
    sleep 5
    continue
  fi

	replacement_pid=$(cat "$RUNTIME/strd.pid" 2>/dev/null)
  if [ "$replacement_pid" != "${pid:-}" ] && daemon_alive "$replacement_pid"; then
    rm -f "$STATE/restart.completed" "$STATE/restart.request"
    release_owned_lock "$RESTART_LOCK"
    failures=0
    continue
  fi
  requested=0
  restart_failed=0
  if [ -s "$STATE/restart.request" ]; then
    restart_id=$(awk -F= '$1 == "id" { print $2; exit }' "$STATE/restart.request" 2>/dev/null)
    restart_reason=$(awk -F= '$1 == "reason" { print $2; exit }' "$STATE/restart.request" 2>/dev/null)
    restart_key=$(awk -F= '$1 == "key" { print $2; exit }' "$STATE/restart.request" 2>/dev/null)
    restart_value=$(awk -F= '$1 == "value" { print $2; exit }' "$STATE/restart.request" 2>/dev/null)
    case "$restart_id:$restart_reason:$restart_value" in *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-]*) : ;;
      *) case "$restart_key" in desired_mode|ruleset|domain_blacklist|domain_allowlist|ip_blacklist|runtime_version) requested=1; last_reason=$restart_reason ;; esac ;;
    esac
  fi
	current_reason=$(sed -n 's/.*reason=\([^ ]*\).*/\1/p' "$RUNTIME/backend" 2>/dev/null | head -n 1)
  [ "$requested" = 1 ] || { [ -n "$current_reason" ] && last_reason=$current_reason; }
  sh "$MODDIR/bin/backend.sh" "$MODDIR" cleanup
  if [ "$requested" = 1 ]; then
    if sh "$MODDIR/bin/backend.sh" "$MODDIR" start && [ "$(snapshot_value "$(lifecycle_snapshot_key "$restart_key")")" = "$restart_value" ]; then
	  new_pid=$(cat "$RUNTIME/strd.pid" 2>/dev/null)
      rm -f "$STATE/restart.request"
      release_owned_lock "$RESTART_LOCK"
      failures=0
      continue
    fi
    sh "$MODDIR/bin/backend.sh" "$MODDIR" cleanup >/dev/null 2>&1 || true
    restart_failed=1
  fi
  release_owned_lock "$RESTART_LOCK"
  if { [ "$requested" = 1 ] && [ "$restart_failed" != 1 ]; } || [ "$uptime" -ge 60 ]; then
    failures=0
  else
    failures=$((failures + 1))
  fi
  if [ "$failures" -ge 3 ]; then
    printf 'backend=fail-open state=FAIL_OPEN reason=%s failures=%s cooldown=300 timestamp=%s\n' \
	  "$last_reason" "$failures" "$(date +%s)" > "$RUNTIME/backend"
    sh "$MODDIR/bin/notify.sh" "$MODDIR" FAIL_OPEN "$last_reason" &
    log -t STR-AdBlocker "FlowGuard circuit open after $failures consecutive failures; retrying in 300s" 2>/dev/null
    sleep 300
    failures=0
  elif [ "$requested" != 1 ] || [ "$restart_failed" = 1 ]; then
    printf 'backend=fail-open state=FAIL_OPEN reason=%s failures=%s timestamp=%s\n' \
	  "$last_reason" "$failures" "$(date +%s)" > "$RUNTIME/backend"
    sh "$MODDIR/bin/notify.sh" "$MODDIR" FAIL_OPEN "$last_reason" &
    sleep "$failures"
  fi
done
