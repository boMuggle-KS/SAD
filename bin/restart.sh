#!/system/bin/sh

# Supervised restart request for the resident daemon. Only service.sh (which
# runs in the system cgroup) may start strd; this helper never spawns the
# daemon from the caller's context, so a WebUI-triggered restart cannot place
# strd inside the manager app cgroup.
#
# Usage: restart.sh MODDIR reason key value [wait_ticks]

MODDIR=${1:-${0%/*}/..}
STATE=${STR_STATE_DIR:-/data/adb/str-adblocker}
RUNTIME=${STR_RUNTIME_DIR:-/dev/str-adblocker}
export STR_STATE_DIR="$STATE" STR_RUNTIME_DIR="$RUNTIME"
REASON=${2:-manual}
KEY=${3:-ruleset}
VALUE=${4:-}
WAIT_TICKS=${5:-600}

. "$MODDIR/bin/owned_lock.sh"
. "$MODDIR/bin/lifecycle.sh"

lifecycle_request_external "$MODDIR" "$STATE" "$REASON" "$KEY" "$VALUE" "$WAIT_TICKS"
status=$?
case "$status" in
  0) printf 'restart applied\n' ;;
  2) printf 'saved; restart pending (service.sh will apply it)\n' ;;
  *) printf 'restart request failed\n' ;;
esac
exit "$status"
