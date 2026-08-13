#!/system/bin/sh

# Process-owned directory locks that survive stale directories after SIGKILL or
# power loss. Callers must pass a fixed absolute path under their private state.

process_start_ticks() {
  awk '{ print $22; exit }' "/proc/$1/stat" 2>/dev/null
}

write_owned_lock_owner() {
  str_lock_path=$1
  str_lock_start=$(process_start_ticks "$$")
  case "$str_lock_start" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s %s\n' "$$" "$str_lock_start" > "$str_lock_path/owner"
}

owned_lock_path_valid() {
  case "$1" in /*) [ "$1" != / ] ;; *) return 1 ;; esac
}

acquire_owned_lock() {
  str_lock_path=$1
  owned_lock_path_valid "$str_lock_path" || return 1
  if mkdir "$str_lock_path" 2>/dev/null; then
    write_owned_lock_owner "$str_lock_path" || { rm -rf "$str_lock_path"; return 1; }
    return 0
  fi

  str_lock_attempt=0
  while :; do
    str_lock_owner=$(awk '{ print $1; exit }' "$str_lock_path/owner" 2>/dev/null)
    str_lock_owner_start=$(awk '{ print $2; exit }' "$str_lock_path/owner" 2>/dev/null)
    case "$str_lock_owner" in ''|*[!0-9]*) str_lock_owner=0 ;; esac
    case "$str_lock_owner_start" in ''|*[!0-9]*) str_lock_owner_start=0 ;; esac
    if [ "$str_lock_owner" != 0 ] && [ "$str_lock_owner_start" != 0 ]; then
      break
    fi
    [ "$str_lock_attempt" -ge 10 ] && break
    str_lock_attempt=$((str_lock_attempt + 1))
    sleep 0.1
  done
  str_lock_current_start=$(process_start_ticks "$str_lock_owner")
  if [ "$str_lock_owner" = 0 ] || [ "$str_lock_owner_start" = 0 ] || \
      [ "$str_lock_current_start" != "$str_lock_owner_start" ]; then
    rm -rf "$str_lock_path"
    mkdir "$str_lock_path" 2>/dev/null || return 1
    write_owned_lock_owner "$str_lock_path" || { rm -rf "$str_lock_path"; return 1; }
    return 0
  fi
  return 1
}

release_owned_lock() {
  str_lock_path=$1
  owned_lock_path_valid "$str_lock_path" || return 1
  [ -d "$str_lock_path" ] || return 0
  str_lock_owner=$(awk '{ print $1; exit }' "$str_lock_path/owner" 2>/dev/null)
  str_lock_owner_start=$(awk '{ print $2; exit }' "$str_lock_path/owner" 2>/dev/null)
  str_lock_self_start=$(process_start_ticks "$$")
  if [ "$str_lock_owner" = "$$" ] && [ -n "$str_lock_self_start" ] && \
      [ "$str_lock_owner_start" = "$str_lock_self_start" ]; then
    rm -rf "$str_lock_path"
  fi
}
