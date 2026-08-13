#!/system/bin/sh

# Shared supervised restart closure. Callers source owned_lock.sh first so
# process_start_ticks is available for PID-reuse-safe identity checks.

lifecycle_snapshot_value() {
  lifecycle_state=$1
	lifecycle_key=$2
	lifecycle_runtime=${STR_RUNTIME_DIR:-$lifecycle_state}
	lifecycle_snapshot="$lifecycle_runtime/flowguard-state.json"
	lifecycle_result=$(sed -n "s/.*\"$lifecycle_key\" *: *\"\([^\"]*\)\".*/\1/p" "$lifecycle_snapshot" 2>/dev/null | head -n 1)
	[ -n "$lifecycle_result" ] && { printf '%s\n' "$lifecycle_result"; return; }
	lifecycle_result=$(sed -n "s/.*\"$lifecycle_key\" *: *\([0-9][0-9]*\).*/\1/p" "$lifecycle_snapshot" 2>/dev/null | head -n 1)
	[ -n "$lifecycle_result" ] && { printf '%s\n' "$lifecycle_result"; return; }
	lifecycle_result=$(sed -n "s/.*\"$lifecycle_key\" *: *true.*/true/p" "$lifecycle_snapshot" 2>/dev/null | head -n 1)
	[ -n "$lifecycle_result" ] && { printf '%s\n' "$lifecycle_result"; return; }
	sed -n "s/.*\"$lifecycle_key\" *: *false.*/false/p" "$lifecycle_snapshot" 2>/dev/null | head -n 1
}

lifecycle_daemon_alive() {
  lifecycle_moddir=$1
  lifecycle_candidate=$2
  # lifecycle.sh is sourced by several commands, so resolve the helper from
  # the module directory supplied by the caller instead of assuming $0.
  . "$lifecycle_moddir/bin/runtime_identity.sh" || return 1
  runtime_process_matches "$lifecycle_candidate" "$lifecycle_moddir/bin/strd" /proc
}

lifecycle_target_active() {
  lifecycle_moddir=$1
  lifecycle_state=$2
  lifecycle_oldpid=$3
  lifecycle_oldstart=$4
  lifecycle_key=$5
  lifecycle_expected=$6
  lifecycle_key=$(lifecycle_snapshot_key "$lifecycle_key")
  # The PID file is published before the first snapshot of a replacement
  # daemon. Prefer it so a valid restart is not held hostage by the previous
  # snapshot; retain the snapshot fallback for one-shot test harnesses.
  lifecycle_runtime=${STR_RUNTIME_DIR:-$lifecycle_state}
  lifecycle_newpid=$(cat "$lifecycle_runtime/strd.pid" 2>/dev/null)
  case "$lifecycle_newpid" in ''|*[!0-9]*) lifecycle_newpid=$(lifecycle_snapshot_value "$lifecycle_state" pid) ;; esac
  lifecycle_newstart=$(process_start_ticks "$lifecycle_newpid")
  lifecycle_value=$(lifecycle_snapshot_value "$lifecycle_state" "$lifecycle_key")
  lifecycle_daemon_alive "$lifecycle_moddir" "$lifecycle_newpid" || return 1
  [ "$lifecycle_value" = "$lifecycle_expected" ] || return 1
  [ "$lifecycle_newpid" != "$lifecycle_oldpid" ] || [ "$lifecycle_newstart" != "$lifecycle_oldstart" ]
}

lifecycle_mark_completed() {
  {
    printf 'reason=%s\n' "$1"
    printf 'id=%s\n' "$2"
  } > "$3/restart.completed.new" || return 1
  chmod 0600 "$3/restart.completed.new"
  mv -f "$3/restart.completed.new" "$3/restart.completed"
}

lifecycle_allowed_keys() {
  case "$1" in desired_mode|ruleset|domain_blacklist|domain_allowlist|ip_blacklist|runtime_version) return 0 ;; *) return 1 ;; esac
}

# Map the restart-request key to the snapshot field that proves the new
# daemon loaded the requested configuration. Both the supervisor and the
# requester must agree on this mapping.
lifecycle_snapshot_key() {
  case "$1" in
    runtime_version) printf 'version\n' ;;
    domain_blacklist) printf 'domain_blacklist_count\n' ;;
    domain_allowlist) printf 'allowlist_count\n' ;;
    ip_blacklist) printf 'ip_blacklist_count\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Capture the current daemon identity into lifecycle_oldpid/oldstart. Used by
# both the supervised and the external request paths so the wait loops can
# tell a replacement daemon apart from the process they asked to stop.
lifecycle_capture_identity() {
  lifecycle_moddir=$1
  lifecycle_state=$2
  lifecycle_runtime=${STR_RUNTIME_DIR:-$lifecycle_state}
  lifecycle_oldpid=$(cat "$lifecycle_runtime/strd.pid" 2>/dev/null)
  if lifecycle_daemon_alive "$lifecycle_moddir" "$lifecycle_oldpid"; then
    lifecycle_oldstart=$(process_start_ticks "$lifecycle_oldpid")
  else
    lifecycle_oldpid=0
    lifecycle_oldstart=0
  fi
}

# Write a supervised restart request under the restart lock, then stop the
# old daemon so the service supervisor (running in the system cgroup) replaces
# it. The requester never starts a replacement itself; only service.sh may
# spawn strd, otherwise a WebUI-triggered restart would inherit the manager
# app cgroup and be frozen with it.
lifecycle_write_request() {
  lifecycle_moddir=$1
  lifecycle_state=$2
  lifecycle_reason=$3
  lifecycle_key=$4
  lifecycle_expected=$5
  lifecycle_runtime=${STR_RUNTIME_DIR:-$lifecycle_state}
  lifecycle_restart_lock="$lifecycle_runtime/restart.lock"

  lifecycle_capture_identity "$lifecycle_moddir" "$lifecycle_state"
  acquire_owned_lock "$lifecycle_restart_lock" || return 1
  lifecycle_requester_start=$(process_start_ticks "$$")
  case "$lifecycle_requester_start" in ''|*[!0-9]*) lifecycle_requester_start=0 ;; esac
  lifecycle_request_id="$(date +%s):$$:$lifecycle_requester_start:$lifecycle_oldpid:$lifecycle_oldstart"

  {
    printf 'id=%s\n' "$lifecycle_request_id"
    printf 'reason=%s\n' "$lifecycle_reason"
    printf 'key=%s\n' "$lifecycle_key"
    printf 'value=%s\n' "$lifecycle_expected"
  } > "$lifecycle_state/restart.request.new" || {
    release_owned_lock "$lifecycle_restart_lock"
    return 1
  }
  chmod 0600 "$lifecycle_state/restart.request.new"
  mv -f "$lifecycle_state/restart.request.new" "$lifecycle_state/restart.request" || {
    release_owned_lock "$lifecycle_restart_lock"
    return 1
  }
  [ "$lifecycle_oldpid" = 0 ] || kill "$lifecycle_oldpid" 2>/dev/null || true
  release_owned_lock "$lifecycle_restart_lock"
  return 0
}

lifecycle_request_restart() {
  lifecycle_moddir=$1
  lifecycle_state=$2
  lifecycle_reason=$3
  lifecycle_key=$4
  lifecycle_expected=$5
  lifecycle_wait_ticks=$6
  lifecycle_runtime=${STR_RUNTIME_DIR:-$lifecycle_state}
  lifecycle_restart_lock="$lifecycle_runtime/restart.lock"

  case "$lifecycle_reason:$lifecycle_expected" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-]*) return 1 ;;
  esac
  lifecycle_allowed_keys "$lifecycle_key" || return 1
  case "$lifecycle_wait_ticks" in ''|*[!0-9]*) return 1 ;; esac

  lifecycle_write_request "$lifecycle_moddir" "$lifecycle_state" "$lifecycle_reason" "$lifecycle_key" "$lifecycle_expected" || return 1

  lifecycle_count=0
  [ "$lifecycle_oldpid" != 0 ] || lifecycle_count=$lifecycle_wait_ticks
  while [ "$lifecycle_count" -lt "$lifecycle_wait_ticks" ]; do
    if lifecycle_target_active "$lifecycle_moddir" "$lifecycle_state" "$lifecycle_oldpid" \
        "$lifecycle_oldstart" "$lifecycle_key" "$lifecycle_expected" && \
        [ ! -e "$lifecycle_state/restart.request" ]; then
      return 0
    fi
    lifecycle_count=$((lifecycle_count + 1))
    sleep 0.1
  done

  lifecycle_count=0
  while ! acquire_owned_lock "$lifecycle_restart_lock"; do
    if lifecycle_target_active "$lifecycle_moddir" "$lifecycle_state" "$lifecycle_oldpid" \
        "$lifecycle_oldstart" "$lifecycle_key" "$lifecycle_expected" && \
        [ ! -e "$lifecycle_state/restart.request" ]; then
      return 0
    fi
    [ "$lifecycle_count" -ge 600 ] && return 1
    lifecycle_count=$((lifecycle_count + 1))
    sleep 0.1
  done

  if lifecycle_target_active "$lifecycle_moddir" "$lifecycle_state" "$lifecycle_oldpid" \
      "$lifecycle_oldstart" "$lifecycle_key" "$lifecycle_expected"; then
    if [ -s "$lifecycle_state/restart.request" ]; then
      lifecycle_mark_completed "$lifecycle_reason" "$lifecycle_request_id" "$lifecycle_state" && \
        rm -f "$lifecycle_state/restart.request"
    fi
    release_owned_lock "$lifecycle_restart_lock"
    return 0
  fi
  if [ ! -s "$lifecycle_state/restart.request" ]; then
    release_owned_lock "$lifecycle_restart_lock"
    return 1
  fi
  if ! sh "$lifecycle_moddir/bin/backend.sh" "$lifecycle_moddir" start; then
    release_owned_lock "$lifecycle_restart_lock"
    return 1
  fi
  if lifecycle_target_active "$lifecycle_moddir" "$lifecycle_state" "$lifecycle_oldpid" \
      "$lifecycle_oldstart" "$lifecycle_key" "$lifecycle_expected"; then
    lifecycle_mark_completed "$lifecycle_reason" "$lifecycle_request_id" "$lifecycle_state" && \
      rm -f "$lifecycle_state/restart.request"
    release_owned_lock "$lifecycle_restart_lock"
    return 0
  fi
  sh "$lifecycle_moddir/bin/backend.sh" "$lifecycle_moddir" cleanup >/dev/null 2>&1 || true
  release_owned_lock "$lifecycle_restart_lock"
  return 1
}

# External supervised restart request (WebUI bridge, action scripts): write
# the request and wait for the supervisor to apply it. Unlike
# lifecycle_request_restart this path never starts the daemon itself, so a
# restart can never land in the caller's (manager app) cgroup. Timeout means
# the request remains pending for service.sh; return 2 to keep the file change
# semantics distinct from a hard failure.
lifecycle_request_external() {
  lifecycle_moddir=$1
  lifecycle_state=$2
  lifecycle_reason=$3
  lifecycle_key=$4
  lifecycle_expected=$5
  lifecycle_wait_ticks=$6
  lifecycle_runtime=${STR_RUNTIME_DIR:-$lifecycle_state}
  lifecycle_restart_lock="$lifecycle_runtime/restart.lock"

  case "$lifecycle_reason:$lifecycle_expected" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-]*) return 1 ;;
  esac
  lifecycle_allowed_keys "$lifecycle_key" || return 1
  case "$lifecycle_wait_ticks" in ''|*[!0-9]*) return 1 ;; esac

  lifecycle_write_request "$lifecycle_moddir" "$lifecycle_state" "$lifecycle_reason" "$lifecycle_key" "$lifecycle_expected" || return 1

  lifecycle_count=0
  [ "$lifecycle_oldpid" != 0 ] || lifecycle_count=$lifecycle_wait_ticks
  while [ "$lifecycle_count" -lt "$lifecycle_wait_ticks" ]; do
    if lifecycle_target_active "$lifecycle_moddir" "$lifecycle_state" "$lifecycle_oldpid" \
        "$lifecycle_oldstart" "$lifecycle_key" "$lifecycle_expected" && \
        [ ! -e "$lifecycle_state/restart.request" ]; then
      return 0
    fi
    lifecycle_count=$((lifecycle_count + 1))
    sleep 0.1
  done
  return 2
}
