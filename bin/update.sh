#!/system/bin/sh

set -u

MODDIR=${1:-${0%/*}/..}
# Mode-first invocations (cloud/request) carry no module path argument; the
# module directory is always the script's own parent in that case.
case "${1:-}" in
  cloud|request|rebuild-hosts|rebuild-request) MODDIR=${0%/*}/.. ;;
esac
STATE=${STR_STATE_DIR:-/data/adb/str-adblocker}
RUNTIME=${STR_RUNTIME_DIR:-/dev/str-adblocker}
export STR_STATE_DIR="$STATE" STR_RUNTIME_DIR="$RUNTIME"
ALLOWLIST="$STATE/allowlist.txt"
DEFAULT_ALLOWLIST="$MODDIR/config/default-allowlist.txt"
LOCK="$STATE/update.lock"
SOURCE_NAMES="hagezi-normal antiad-easylist 1hosts-lite adguard-dns adguard-base adguard-chinese banad oisd-big"
ENDPOINT_SOURCE="$STATE/endpoints.source"
MIN_RULES=200000
MAX_RULES=2500000
DOWNLOAD_BUDGET=${DOWNLOAD_BUDGET:-900}
RULESET_ROOT="$STATE/rulesets"
STAGING_REPORT="$STATE/staging-report"
STAGING_TIMEOUT_TICKS=1800
STAGING_MAX_OUTPUT=16384
STAGING_MAX_TEMP_KIB=65536
RESTART_WAIT_TICKS=100
HOTSET_MAX=30000
HOTSET_COMMON=20000
HOTSET_ANTIAD=6000
HOTSET_HAGEZI=4000
HOTSET_MODULE_PATH="$MODDIR/system/etc/hosts"
. "$MODDIR/bin/ruleset.sh"
. "$MODDIR/bin/owned_lock.sh"
. "$MODDIR/bin/lifecycle.sh"

# Preserve the bundled, digest-bound endpoint evidence when no user-managed
# feed has been installed. A state feed still takes precedence.
[ -s "$ENDPOINT_SOURCE" ] || ENDPOINT_SOURCE="$MODDIR/rules/endpoints.txt"

say() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >> "$STATE/cloud-update.console" 2>/dev/null || true
  log -t STR-AdBlocker "$*" 2>/dev/null || true
}

cloud_progress() {
  printf 'stage=%s\ntimestamp=%s\n' "$1" "$(date +%s)" > "$RUNTIME/cloud-update.stage.new" 2>/dev/null
  chmod 0600 "$RUNTIME/cloud-update.stage.new" 2>/dev/null
  mv -f "$RUNTIME/cloud-update.stage.new" "$RUNTIME/cloud-update.stage" 2>/dev/null || true
}

cleanup() {
  release_owned_lock "$LOCK"
}

# POSIX sh executes function definitions in order: these download helpers are
# used by the cloud-mode block below, so they must be defined before it runs.
run_download() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 90 "$@"
  else
    "$@"
  fi
}

download() {
  output=$1
  shift
  dl_start=$(date +%s)
  for url in "$@"; do
    [ "$(date +%s)" -lt $((dl_start + DOWNLOAD_BUDGET)) ] || {
      say "Download budget exceeded; existing rules were kept"
      return 1
    }
    say "Downloading $url"
    if [ -x "$MODDIR/bin/fetch" ]; then
      if fetch_err=$(run_download "$MODDIR/bin/fetch" -o "$output" --max-bytes 67108864 "$url" 2>&1); then
        return 0
      fi
      say "fetch failed ($url): $fetch_err"
    elif command -v curl >/dev/null 2>&1; then
      run_download curl -fsSL --connect-timeout 10 --max-time 120 --retry 1 -o "$output" "$url" && return 0
    elif command -v wget >/dev/null 2>&1; then
      run_download wget -q -T 20 -t 1 -O "$output" "$url" && return 0
    else
      say "No HTTPS downloader found (fetch is not executable at $MODDIR/bin/fetch); existing rules were kept"
      return 1
    fi
  done
  return 1
}

# Print the China-region acceleration mirror chain for one canonical GitHub
# URL, origin last, one URL per line. Non-GitHub URLs are used as configured
# without a chain.
mirror_chain() {
  printf '%s\n' \
    "https://cors.isteed.cc/$1" \
    "https://gh.ddlc.top/$1" \
    "https://gh-proxy.com/$1" \
    "https://ghfast.top/$1" \
    "https://ghproxy.net/$1" \
    "$1"
}

mkdir -p "$STATE" "$RUNTIME"
mkdir -p "$RULESET_ROOT" || exit 1
chmod 0700 "$RULESET_ROOT"

# Rebuild the hosts hotset from a cloud generation domain list after applying
# the device allowlist. Rewrites hosts and hotset.manifest; prints the
# filtered count on success. Defined before the mode blocks because
# rebuild-hosts calls it without holding the general lock first.
rebuild_hotset() {
  domains_file=$1
  hosts_file=$2
  hotset_manifest=$3
  hotset_ruleset=$4
  default_allow_file=${DEFAULT_ALLOWLIST:-}
  if { [ -f "$ALLOWLIST" ] && [ -r "$ALLOWLIST" ]; } || \
     { [ -n "$default_allow_file" ] && [ -f "$default_allow_file" ] && [ -r "$default_allow_file" ]; }; then
    {
      if [ -f "$ALLOWLIST" ] && [ -r "$ALLOWLIST" ]; then cat "$ALLOWLIST"; fi
      if [ -n "$default_allow_file" ] && [ -f "$default_allow_file" ] && [ -r "$default_allow_file" ]; then cat "$default_allow_file"; fi
    } | LC_ALL=C sort -u > "$LOCK/allowlist.sorted" || return 1
  else
    : > "$LOCK/allowlist.sorted"
  fi
  awk -v allowfile="$LOCK/allowlist.sorted" '
    BEGIN {
      while ((getline line < allowfile) > 0) {
        sub(/\r$/, "", line); sub(/[[:space:]#].*$/, "", line)
        line = tolower(line); sub(/^\|\|/, "", line); sub(/\^$/, "", line); sub(/^\./, "", line)
        if (line ~ /^[a-z0-9.-]+$/ && line != "") allow[line] = 1
      }
      close(allowfile)
    }
    {
      sub(/\r$/, ""); domain = tolower($0)
      suffix = domain
      keep = 1
      while (suffix != "") {
        if (suffix in allow) { keep = 0; break }
        sub(/^[^.]+\.?/, "", suffix)
      }
      if (keep) print domain
    }
  ' "$domains_file" > "$LOCK/hotset.filtered" || return 1
  filtered=$(wc -l < "$LOCK/hotset.filtered" | tr -d ' ')
  case "$filtered" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$filtered" -lt 1000 ] || [ "$filtered" -gt "$HOTSET_MAX" ]; then
    say "Rejected suspicious filtered hotset ($filtered entries)"
    return 1
  fi
  {
    printf '# STR AdBlocker hosts hotset\n'
    printf '# ruleset=%s\n' "$hotset_ruleset"
    printf '# domains=%s\n' "$filtered"
    printf '# Generated from the cloud policy filtered by the device allowlist; do not edit.\n'
    while IFS= read -r domain; do
      printf '0.0.0.0 %s\n:: %s\n' "$domain" "$domain"
    done < "$LOCK/hotset.filtered"
  } > "$hosts_file.new" || return 1
  mv -f "$hosts_file.new" "$hosts_file" || return 1
  filtered_digest=$(sha256sum "$hosts_file" 2>/dev/null | awk '{ print $1 }')
  [ -n "$filtered_digest" ] || return 1
  {
    printf 'format=1\n'
    printf 'hotset=%s\n' "$filtered"
    printf 'ruleset=%s\n' "$hotset_ruleset"
    printf 'sha256=%s\n' "$filtered_digest"
  } > "$hotset_manifest.new" || return 1
  mv -f "$hotset_manifest.new" "$hotset_manifest" || return 1
  printf '%s\n' "$filtered"
}

# Publish one generation's hotset into the module bind source while preserving
# the existing inode when possible. Writing into the live inode keeps a bind
# mount on the system hosts target immediately consistent without a remount;
# replacing the file with a new inode would leave the old bind pointing at
# stale bytes until ensure-hosts detaches and rebinds.
publish_module_hotset() {
  generation_hotset=$1
  [ -s "$generation_hotset" ] || return 1
  expected_sha=$(sha256sum "$generation_hotset" 2>/dev/null | awk '{ print $1; exit }')
  [ -n "$expected_sha" ] || return 1
  current_sha=$(sha256sum "$HOTSET_MODULE_PATH" 2>/dev/null | awk '{ print $1; exit }')
  [ "$current_sha" = "$expected_sha" ] && return 0
  if [ -e "$HOTSET_MODULE_PATH" ] && cat "$generation_hotset" > "$HOTSET_MODULE_PATH" 2>/dev/null; then
    chmod 0644 "$HOTSET_MODULE_PATH" 2>/dev/null || true
    module_sha=$(sha256sum "$HOTSET_MODULE_PATH" 2>/dev/null | awk '{ print $1; exit }')
    [ "$module_sha" = "$expected_sha" ] && return 0
  fi
  # Read-only or missing sources fall back to an atomic new inode; the
  # ensure-hosts write-through/remount then reconciles the live target.
  if cp "$generation_hotset" "$HOTSET_MODULE_PATH.new" 2>/dev/null; then
    chmod 0644 "$HOTSET_MODULE_PATH.new"
    mv -f "$HOTSET_MODULE_PATH.new" "$HOTSET_MODULE_PATH"
    return 0
  fi
  rm -f "$HOTSET_MODULE_PATH.new" 2>/dev/null || true
  return 1
}

# Request mode: queue one cloud update for the running supervisor. The
# supervisor owns the download so manual triggers never race the periodic
# check or the update lock.
if [ "${1:-}" = request ]; then
  REQUEST_URL=$(cat "$STATE/cloud-update-url" 2>/dev/null)
  case "$REQUEST_URL" in
    https://*) ;;
    *) say "Cloud update URL is not configured"; exit 7 ;;
  esac
  printf '%s\n' "$REQUEST_URL" > "$STATE/cloud-update.request.new" || {
    say "Cannot write cloud update request"
    exit 5
  }
  chmod 0600 "$STATE/cloud-update.request.new" || {
    say "Cannot chmod cloud update request"
    exit 5
  }
  mv -f "$STATE/cloud-update.request.new" "$STATE/cloud-update.request" || {
    say "Cannot publish cloud update request"
    exit 5
  }
  [ -s "$STATE/cloud-update.request" ] || {
    say "Cloud update request was not persisted"
    exit 5
  }
  say "Cloud update requested"
  exit 0
fi

# Request mode: queue one hosts rebuild for the running supervisor. Allowlist
# saves write this marker and return immediately; service.sh applies the
# rebuild when no cloud update holds the generation lock, so a save can never
# fail with "update already running" or collide with an in-flight update.
if [ "${1:-}" = rebuild-request ]; then
  printf '%s\n' "$(date +%s)" > "$STATE/hosts-rebuild.request.new" || {
    say "Cannot write hosts rebuild request"
    exit 5
  }
  chmod 0600 "$STATE/hosts-rebuild.request.new" || {
    say "Cannot chmod hosts rebuild request"
    exit 5
  }
  mv -f "$STATE/hosts-rebuild.request.new" "$STATE/hosts-rebuild.request" || {
    say "Cannot publish hosts rebuild request"
    exit 5
  }
  [ -s "$STATE/hosts-rebuild.request" ] || {
    say "Hosts rebuild request was not persisted"
    exit 5
  }
  say "Hosts rebuild requested"
  exit 0
fi

# Rebuild mode: reapply the device allowlist to the ACTIVE generation's hosts
# hotset immediately. WebUI allowlist saves request this through the
# supervisor so whitelisted domains stop being mapped in /system/etc/hosts
# without waiting for a new cloud generation. Idempotent: always regenerates
# from the pristine domain list, so removing allowlist entries restores the
# full hotset. Must hold the generation lock for consistency with cloud
# publishes; when a cloud update owns the lock the request is kept (deferred)
# and service.sh retries it after the update completes.
if [ "${1:-}" = rebuild-hosts ]; then
  if ! acquire_owned_lock "$LOCK"; then
    if [ ! -s "$STATE/hosts-rebuild.request" ]; then
      printf '%s\n' "$(date +%s)" > "$STATE/hosts-rebuild.request.new" 2>/dev/null || true
      chmod 0600 "$STATE/hosts-rebuild.request.new" 2>/dev/null || true
      mv -f "$STATE/hosts-rebuild.request.new" "$STATE/hosts-rebuild.request" 2>/dev/null || true
    fi
    say "Hosts rebuild deferred; cloud update in progress"
    exit 0
  fi
  trap 'cleanup; rm -f "$RUNTIME/hosts-rebuild.running" "$RUNTIME/hosts-rebuild.pid" 2>/dev/null || true' EXIT
  rm -f "$STATE/hosts-rebuild.request" 2>/dev/null || true
  # Resolve the ACTIVE generation (bundled module rules or a published cloud
  # generation) and rebuild its hosts derivative in place. Both sources carry
  # hotset.domains so a fresh install with bundled rules gets the same
  # allowlist-rebuild behaviour as an updated device.
  if ! resolve_ruleset "$MODDIR" "$STATE" 1; then
    say "Active ruleset is unavailable; existing hosts were kept"
    exit 4
  fi
  gen_dir=${RULES_PATH%/rules.bin}
  hotset_ruleset=$(awk -F= '$1 == "ruleset" { print $2; exit }' "$MANIFEST_PATH" 2>/dev/null)
  ruleset_token_valid "$hotset_ruleset" || {
    say "Active ruleset token is invalid; existing hosts were kept"
    exit 4
  }
  if [ ! -r "$gen_dir/hotset.domains" ] || [ ! -r "$gen_dir/hotset.hosts" ] || \
     [ ! -r "$gen_dir/hotset.manifest" ]; then
    say "Active ruleset hosts are unavailable; existing hosts were kept"
    exit 4
  fi
  if ! filtered=$(rebuild_hotset "$gen_dir/hotset.domains" "$gen_dir/hotset.hosts" "$gen_dir/hotset.manifest" "$hotset_ruleset"); then
    say "Allowlist hosts rebuild failed; existing hosts were kept"
    exit 4
  fi
  if ! publish_module_hotset "$gen_dir/hotset.hosts"; then
    say "Allowlist hosts publish failed; existing hosts were kept"
    exit 4
  fi
  sh "$MODDIR/bin/backend.sh" "$MODDIR" ensure-hosts >/dev/null 2>&1 || true
  say "Allowlist applied to hosts ($filtered entries kept)"
  exit 0
fi

if ! acquire_owned_lock "$LOCK"; then
  say "Update already running"
  exit 2
fi
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Publish a fully built, validated generation under RULESET_ROOT and switch
# the active ruleset atomically. Shared by the on-device and cloud builders.
publish_generation() {
  generation=$1
  new_token=$2
  count=$3
  hotset_count=$4
  digest=$5
  hotset_digest=$6
  endpoint_digest=$7
  endpoint_count=$8
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$MODDIR/bin/strd" -validate-rules -rules "$generation/rules.bin" -manifest "$generation/manifest" \
      -allowlist "$ALLOWLIST" -domain-blacklist "$STATE/domain-blacklist.txt" -endpoints "$generation/endpoints.txt" -state "$STATE/flowguard-state.json" >/dev/null || {
      say "Compiled policy validation failed or timed out; existing rules were kept"
      return 5
    }
  elif ! "$MODDIR/bin/strd" -validate-rules -rules "$generation/rules.bin" -manifest "$generation/manifest" \
    -allowlist "$ALLOWLIST" -domain-blacklist "$STATE/domain-blacklist.txt" -endpoints "$generation/endpoints.txt" -state "$STATE/flowguard-state.json" >/dev/null; then
    say "Compiled policy validation failed; existing rules were kept"
    return 5
  fi
  mv "$generation" "$RULESET_ROOT/$new_token" || return 5

  # Publish the hosts derivative independently. A failure here keeps the prior
  # hotset while the verified binary generation remains available to FlowGuard.
  mkdir -p "${HOTSET_MODULE_PATH%/*}" 2>/dev/null || true
  if [ -d "${HOTSET_MODULE_PATH%/*}" ] && publish_module_hotset "$RULESET_ROOT/$new_token/hotset.hosts"; then
    :
  else
    say "Hotset publish failed; existing hosts hotset was kept"
  fi

  previous=
  if resolve_ruleset "$MODDIR" "$STATE" 1 && [ "$RULESET_ORIGIN" != bundled ]; then
    previous_dir=${RULES_PATH%/rules.bin}
    previous=${previous_dir##*/}
    ruleset_token_valid "$previous" || previous=
  fi
  if [ -n "$previous" ] && [ -d "$RULESET_ROOT/$previous" ]; then
    printf '%s\n' "$previous" > "$STATE/rules.previous.new" || return 5
    chmod 0600 "$STATE/rules.previous.new"
    mv -f "$STATE/rules.previous.new" "$STATE/rules.previous" || return 5
  else
    rm -f "$STATE/rules.previous" "$STATE/rules.previous.new"
  fi
  printf '%s\n' "$new_token" > "$STATE/rules.active.new" || return 5
  chmod 0600 "$STATE/rules.active.new"
  mv -f "$STATE/rules.active.new" "$STATE/rules.active" || return 5

  for candidate in "$RULESET_ROOT"/*; do
    [ -d "$candidate" ] || continue
    candidate_token=${candidate##*/}
    [ "$candidate_token" = "$new_token" ] && continue
    [ -n "$previous" ] && [ "$candidate_token" = "$previous" ] && continue
    case "$candidate_token" in
      ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*) continue ;;
    esac
    rm -rf "${RULESET_ROOT:?}/$candidate_token"
  done

  printf 'updated ruleset=%s rules=%s sources=%s\n' "$new_token" "$count" "$(printf '%s,' $SOURCE_NAMES | sed 's/,$//')" > "$STATE/status"
  chmod 0600 "$STATE/status"

  if lifecycle_request_restart "$MODDIR" "$STATE" rules_updated ruleset "$new_token" "$RESTART_WAIT_TICKS"; then
    say "Updated $count domains from the provider union. FlowGuard loaded $new_token."
    return 0
  else
    say "Updated $count domains, but the new ruleset is not verified active; restart remains pending."
    return 6
  fi
}

# Cloud mode: download a prebuilt generation, verify it, and publish it.
if [ "${1:-}" = cloud ]; then
  # Cloud-mode runs are invoked by the supervisor; a direct invocation must
  # not leave a stale progress marker behind after the run completes.
  trap 'cleanup; rm -f "$RUNTIME/cloud-update.stage" "$RUNTIME/cloud-update.stage.new" 2>/dev/null || true' EXIT
  : > "$STATE/cloud-update.console" 2>/dev/null || true
  CLOUD_URL=${2:-}
  case "$CLOUD_URL" in
    https://*) ;;
    *) say "Cloud update URL must be HTTPS"; exit 7 ;;
  esac
  CLOUD_TARBALL="$LOCK/cloud.tar.gz"
  CLOUD_LATEST="$LOCK/cloud-latest.json"
  CLOUD_GEN="$LOCK/cloud-gen"
  rm -rf "$CLOUD_GEN"
  mkdir "$CLOUD_GEN" || exit 5
  DOWNLOAD_BUDGET=300
  cloud_progress download
  # GitHub release assets are fetched through China-region acceleration
  # mirrors first, with the original URL as the final fallback. Custom
  # (non-GitHub) HTTPS URLs are used as configured.
  #
  # The always-current `releases/latest` alias is resolved through the tiny
  # latest.json first, then the tarball is pulled from the exact
  # release-tag URL. The rules workflow prewarms exactly that tag URL on the
  # mirrors, so the large asset is served from cache instead of being
  # re-fetched from GitHub origin on every device. Any discovery or tag
  # failure falls back to the configured URL.
  GITHUB_TAIL=${CLOUD_URL#*github.com/}
  case "$CLOUD_URL" in
    *github.com/*)
      GITHUB_URL="https://github.com/$GITHUB_TAIL"
      case "$GITHUB_URL" in
        */releases/latest/*)
          latest_json_url=$(printf '%s' "$GITHUB_URL" | sed 's#/releases/latest/.*#/releases/latest/download/latest.json#')
          DOWNLOAD_BUDGET=60
          download "$CLOUD_LATEST" $(mirror_chain "$latest_json_url")
          DOWNLOAD_BUDGET=300
          token=
          if [ -s "$CLOUD_LATEST" ]; then
            token=$(awk 'match($0, /"token"[[:space:]]*:[[:space:]]*"[^"]*"/) { s = substr($0, RSTART, RLENGTH); sub(/.*"token"[[:space:]]*:[[:space:]]*"/, "", s); sub(/".*/, "", s); print s; exit }' "$CLOUD_LATEST" 2>/dev/null)
            case "$token" in
              [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
              *) token= ;;
            esac
          fi
          if [ -n "$token" ]; then
            tag_tarball_url=$(printf '%s' "$GITHUB_URL" | sed "s#/releases/.*#/releases/download/rules-$token/generation.tar.gz#")
            if download "$CLOUD_TARBALL" $(mirror_chain "$tag_tarball_url"); then
              :
            else
              say "Cloud tag download failed; retrying configured URL"
              download "$CLOUD_TARBALL" $(mirror_chain "$GITHUB_URL") || {
                say "Cloud generation download failed; existing rules were kept"
                exit 3
              }
            fi
          else
            say "Cloud latest discovery failed; retrying configured URL"
            download "$CLOUD_TARBALL" $(mirror_chain "$GITHUB_URL") || {
              say "Cloud generation download failed; existing rules were kept"
              exit 3
            }
          fi
          ;;
        *)
          download "$CLOUD_TARBALL" $(mirror_chain "$GITHUB_URL") || {
            say "Cloud generation download failed; existing rules were kept"
            exit 3
          }
          ;;
      esac
      ;;
    *)
      download "$CLOUD_TARBALL" "$CLOUD_URL" || {
        say "Cloud generation download failed; existing rules were kept"
        exit 3
      }
      ;;
  esac
  cloud_progress verify
  expected_sha=
  if [ -s "$CLOUD_LATEST" ]; then
    expected_sha=$(awk 'match($0, /"archive_sha256"[[:space:]]*:[[:space:]]*"[^"]*"/) { s = substr($0, RSTART, RLENGTH); sub(/.*"archive_sha256"[[:space:]]*:[[:space:]]*"/, "", s); sub(/".*/, "", s); print s; exit }' "$CLOUD_LATEST" 2>/dev/null)
  fi
  case "$expected_sha" in
    ""|[!0-9a-f]*) expected_sha= ;;
    *) [ "${#expected_sha}" = 64 ] || expected_sha= ;;
  esac
  if [ -n "$expected_sha" ]; then
    "$MODDIR/bin/fetch" unpack -expected-sha "$expected_sha" "$CLOUD_TARBALL" "$CLOUD_GEN" || {
      say "Cloud generation archive verification or extraction failed; existing rules were kept"
      exit 4
    }
  else
    "$MODDIR/bin/fetch" unpack "$CLOUD_TARBALL" "$CLOUD_GEN" || {
      say "Cloud generation extraction failed; existing rules were kept"
      exit 4
    }
  fi
  for required in rules.bin manifest hotset.hosts hotset.manifest endpoints.txt hotset.domains; do
    [ -s "$CLOUD_GEN/$required" ] || {
      say "Cloud generation is missing $required; existing rules were kept"
      exit 4
    }
  done
  if [ ! -s "$MODDIR/rules/ed25519.pub" ]; then
    say "Cloud update rejected: trust anchor $MODDIR/rules/ed25519.pub is missing; existing rules were kept"
    exit 4
  fi
  if [ ! -s "$CLOUD_GEN/generation.sig" ]; then
    say "Cloud generation is missing its signature; existing rules were kept"
    exit 4
  fi
  "$MODDIR/bin/fetch" verify-gen -pubkey "$MODDIR/rules/ed25519.pub" -manifest "$CLOUD_GEN/manifest" -signature "$CLOUD_GEN/generation.sig" || {
    say "Cloud generation signature verification failed; existing rules were kept"
    exit 4
  }
  new_token=$(awk -F= '$1 == "ruleset" { print $2; exit }' "$CLOUD_GEN/manifest")
  if ! ruleset_token_valid "$new_token"; then
    say "Cloud generation ruleset is invalid; existing rules were kept"
    exit 4
  fi
  if [ -r "$STATE/rules.active" ] && [ "$(cat "$STATE/rules.active" 2>/dev/null)" = "$new_token" ]; then
    say "Cloud ruleset $new_token is already active"
    # Same-token updates skip generation publish, but a module update can
    # reset the bundled system hosts copy while the active generation stays a
    # cloud hotset. Resync the module bind source in place, then reconcile the
    # live target so the mounted file always matches the active manifest.
    if [ -r "$STATE/rulesets/$new_token/hotset.hosts" ]; then
      mkdir -p "${HOTSET_MODULE_PATH%/*}" 2>/dev/null || true
      if [ -r "$STATE/rulesets/$new_token/hotset.domains" ] && [ -r "$STATE/rulesets/$new_token/hotset.manifest" ]; then
        if filtered=$(rebuild_hotset "$STATE/rulesets/$new_token/hotset.domains" "$STATE/rulesets/$new_token/hotset.hosts" "$STATE/rulesets/$new_token/hotset.manifest" "$new_token"); then
          say "Allowlist reapplied to hosts ($filtered entries kept)"
        else
          say "Allowlist hosts rebuild failed; existing hosts hotset was kept"
        fi
      fi
      publish_module_hotset "$STATE/rulesets/$new_token/hotset.hosts" || say "Hotset resync failed; existing hosts hotset was kept"
    fi
    sh "$MODDIR/bin/backend.sh" "$MODDIR" ensure-hosts >/dev/null 2>&1 || true
    exit 0
  fi
  count=$(awk -F= '$1 == "rules" { print $2; exit }' "$CLOUD_GEN/manifest")
  case "$count" in ''|*[!0-9]*) say "Cloud generation rule count is invalid"; exit 4 ;; esac
  if [ "$count" -lt "$MIN_RULES" ] || [ "$count" -gt "$MAX_RULES" ]; then
    say "Rejected suspicious cloud ruleset ($count entries); existing rules were kept"
    exit 4
  fi
  digest=$(sha256sum "$CLOUD_GEN/rules.bin" 2>/dev/null | awk '{ print $1 }')
  expected_digest=$(awk -F= '$1 == "sha256" { print $2; exit }' "$CLOUD_GEN/manifest")
  if [ -z "$digest" ] || [ "$digest" != "$expected_digest" ]; then
    say "Cloud rules digest mismatch; existing rules were kept"
    exit 4
  fi
  hotset_count=$(awk -F= '$1 == "hotset" { print $2; exit }' "$CLOUD_GEN/hotset.manifest")
  case "$hotset_count" in ''|*[!0-9]*) say "Cloud hotset count is invalid"; exit 4 ;; esac
  if [ "$hotset_count" -lt 1000 ] || [ "$hotset_count" -gt "$HOTSET_MAX" ]; then
    say "Rejected suspicious cloud hotset ($hotset_count entries); existing rules were kept"
    exit 4
  fi
  hotset_digest=$(sha256sum "$CLOUD_GEN/hotset.hosts" 2>/dev/null | awk '{ print $1 }')
  expected_hotset=$(awk -F= '$1 == "sha256" { print $2; exit }' "$CLOUD_GEN/hotset.manifest")
  if [ -z "$hotset_digest" ] || [ "$hotset_digest" != "$expected_hotset" ]; then
    say "Cloud hotset digest mismatch; existing rules were kept"
    exit 4
  fi
  endpoint_digest=$(sha256sum "$CLOUD_GEN/endpoints.txt" 2>/dev/null | awk '{ print $1 }')
  expected_endpoint=$(awk -F= '$1 == "endpoint_sha256" { print $2; exit }' "$CLOUD_GEN/manifest")
  if [ -z "$endpoint_digest" ] || [ "$endpoint_digest" != "$expected_endpoint" ]; then
    say "Cloud endpoint digest mismatch; existing rules were kept"
    exit 4
  fi
  endpoint_count=$(awk -F= '$1 == "endpoint_count" { print $2; exit }' "$CLOUD_GEN/manifest")
  case "$endpoint_count" in ''|*[!0-9]*) endpoint_count=0 ;; esac
  provider_digest=$(awk -F= '$1 == "provider_sha256" { print $2; exit }' "$CLOUD_GEN/manifest")
  case "$provider_digest" in
    *[!0123456789abcdef]*) say "Cloud provider digest is invalid"; exit 4 ;;
    *) [ "${#provider_digest}" -eq 64 ] || { say "Cloud provider digest is invalid"; exit 4; } ;;
  esac

  # Cloud hosts are compiled without device state; rebuild them when the
  # per-device allowlist is configured.
  if [ -s "$ALLOWLIST" ]; then
    filtered_count=$(rebuild_hotset "$CLOUD_GEN/hotset.domains" "$CLOUD_GEN/hotset.hosts" "$CLOUD_GEN/hotset.manifest" "$new_token") || {
      say "Hotset allowlist rebuild failed; existing rules were kept"
      exit 4
    }
    hotset_count=$filtered_count
    hotset_digest=$(sha256sum "$CLOUD_GEN/hotset.hosts" 2>/dev/null | awk '{ print $1 }')
  fi

  cloud_progress publish
  publish_generation "$CLOUD_GEN" "$new_token" "$count" "$hotset_count" "$digest" "$hotset_digest" "$endpoint_digest" "$endpoint_count"
  publish_status=$?
  # Refresh the hosts bind after any successful publish so a replaced module
  # hosts inode is remounted even if the supervised restart path misses it.
  sh "$MODDIR/bin/backend.sh" "$MODDIR" ensure-hosts >/dev/null 2>&1 || true
  exit $publish_status
fi

DOMAINS="$LOCK/domains"
SORTED="$LOCK/domains.sorted"

write_staging_report() {
  report_state=$1
  report_pid=$2
  report_exit=$3
  report_timeout=$4
  report_sample=$5
  report_peak_rss=$6
  report_peak_fds=$7
  report_peak_cpu=$8
  report_output=$9
  report_temp=${10}
  report_samples=${11}
  report_orphan=${12}
  report_stamp=$(date +%s)
  report_tmp="$STAGING_REPORT.new"
  {
    printf 'scope=provider_staging\n'
    printf 'state=%s\n' "$report_state"
    printf 'pid=%s\n' "$report_pid"
    printf 'exit=%s\n' "$report_exit"
    printf 'timeout=%s\n' "$report_timeout"
    printf 'sample_state=%s\n' "$report_sample"
    printf 'peak_rss_kib=%s\n' "$report_peak_rss"
    printf 'peak_fds=%s\n' "$report_peak_fds"
    printf 'peak_cpu_ticks=%s\n' "$report_peak_cpu"
    printf 'output_bytes=%s\n' "$report_output"
    printf 'temporary_bytes_kib=%s\n' "$report_temp"
    printf 'sample_count=%s\n' "$report_samples"
    printf 'orphan=%s\n' "$report_orphan"
    printf 'timestamp=%s\n' "$report_stamp"
  } > "$report_tmp" || return 1
  chmod 0600 "$report_tmp"
  mv -f "$report_tmp" "$STAGING_REPORT"
}

run_staging_compile() {
  compile_output=$1
  compile_log="$LOCK/compile.output"
  : > "$compile_log" || return 1
  "$MODDIR/bin/strd" -compile-domains "$SORTED" -compile-output "$compile_output" >"$compile_log" 2>&1 &
  staging_pid=$!
  staging_ticks=0
  staging_timeout=0
  staging_sample=measured
  peak_rss=0
  peak_fds=0
  peak_cpu=0
  sample_count=0
  orphan=0
  while kill -0 "$staging_pid" 2>/dev/null; do
    status_file="/proc/$staging_pid/status"
    stat_file="/proc/$staging_pid/stat"
    if [ ! -r "$status_file" ] || [ ! -r "$stat_file" ]; then
      staging_sample=unmeasured
    else
      rss=$(awk '/^VmRSS:/ { print $2; exit }' "$status_file" 2>/dev/null)
      fds=$(ls -U "/proc/$staging_pid/fd" 2>/dev/null | wc -l | tr -d ' ')
      cpu=$(awk '{ print $14 + $15 }' "$stat_file" 2>/dev/null)
      case "$rss:$fds:$cpu" in
        *[!0-9:]*|*::*) staging_sample=unmeasured ;;
        *)
          sample_count=$((sample_count + 1))
          [ "$rss" -gt "$peak_rss" ] && peak_rss=$rss
          [ "$fds" -gt "$peak_fds" ] && peak_fds=$fds
          [ "$cpu" -gt "$peak_cpu" ] && peak_cpu=$cpu
          ;;
      esac
    fi
    output_bytes=$(wc -c < "$compile_log" 2>/dev/null | tr -d ' ')
    temp_kib=$(du -sk "$LOCK" 2>/dev/null | awk '{ print $1 + 0 }')
    case "$output_bytes:$temp_kib" in
      *[!0-9:]*|*::*) staging_sample=unmeasured ;;
      *)
        if [ "$output_bytes" -gt "$STAGING_MAX_OUTPUT" ] || [ "$temp_kib" -gt "$STAGING_MAX_TEMP_KIB" ]; then
          staging_timeout=1
          kill -9 "$staging_pid" 2>/dev/null || true
          break
        fi
        ;;
    esac
    if [ "$staging_ticks" -ge "$STAGING_TIMEOUT_TICKS" ]; then
      staging_timeout=1
      kill -9 "$staging_pid" 2>/dev/null || true
      break
    fi
    staging_ticks=$((staging_ticks + 1))
    sleep 0.1
  done
  # The compiler is a direct child, so wait is the ownership proof. Never
  # probe or kill the numeric PID after wait: a fast PID reuse could otherwise
  # turn cleanup into an unrelated-process kill. A failed wait means the child
  # was not reapable by this shell and the staging sample is unmeasured; leave
  # recovery to the supervisor rather than guessing which process owns it.
  if wait "$staging_pid" 2>/dev/null; then
    staging_exit=0
  else
    staging_exit=$?
    [ "$staging_exit" -eq 127 ] && orphan=1
  fi
  output_bytes=$(wc -c < "$compile_log" 2>/dev/null | tr -d ' ')
  temp_kib=$(du -sk "$LOCK" 2>/dev/null | awk '{ print $1 + 0 }')
  case "$output_bytes:$temp_kib" in *[!0-9:]*|*::*) staging_sample=unmeasured ;; esac
  [ "$sample_count" -gt 0 ] || staging_sample=unmeasured
  [ "$orphan" -eq 0 ] || staging_sample=unmeasured
  if [ "$staging_timeout" -ne 0 ]; then
    staging_state=limit_exceeded
  elif [ "$staging_exit" -eq 0 ] && [ "$staging_sample" = measured ]; then
    staging_state=complete
  else
    staging_state=failed
  fi
  write_staging_report "$staging_state" "$staging_pid" "$staging_exit" "$staging_timeout" "$staging_sample" "$peak_rss" "$peak_fds" "$peak_cpu" "${output_bytes:-0}" "${temp_kib:-0}" "$sample_count" "$orphan" || return 1
  [ "$staging_state" = complete ]
}

download_source() {
  source_name=$1
  case "$source_name" in
    hagezi-normal)
      download "$LOCK/$source_name" \
        https://codeberg.org/hagezi/mirror2/raw/branch/main/dns-blocklists/adblock/multi.txt \
        https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/adblock/multi.txt ;;
    antiad-easylist)
      download "$LOCK/$source_name" \
        https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-easylist.txt \
        https://cdn.jsdelivr.net/gh/privacy-protection-tools/anti-AD@master/anti-ad-easylist.txt ;;
    1hosts-lite)
      download "$LOCK/$source_name" \
        https://raw.githubusercontent.com/badmojr/1Hosts/master/Lite/domains.txt ;;
    adguard-dns)
      download "$LOCK/$source_name" \
        https://filters.adtidy.org/extension/chromium/filters/15.txt ;;
    adguard-base)
      download "$LOCK/$source_name" \
        https://filters.adtidy.org/extension/chromium/filters/2.txt ;;
    adguard-chinese)
      download "$LOCK/$source_name" \
        https://filters.adtidy.org/extension/chromium/filters/224.txt ;;
    banad)
      download "$LOCK/$source_name" \
        https://raw.githubusercontent.com/damengzhu/banad/main/jiekouAD.txt ;;
    oisd-big)
      download "$LOCK/$source_name" \
        https://big.oisd.nl ;;
    *) return 1 ;;
  esac
}

for name in $SOURCE_NAMES; do
  download_source "$name" || {
    say "$name download failed; existing rules were kept"
    exit 3
  }
done

[ -f "$ALLOWLIST" ] || : > "$ALLOWLIST"

parse_source() {
source_name=$1
source_path=$2
awk -v allowfile="$ALLOWLIST" '
  function valid(d, labels, n, i) {
    if (length(d) > 253 || d !~ /^[a-z0-9.-]+$/ || d ~ /^[0-9.]+$/ || d ~ /^\./ || d ~ /\.$/ || d ~ /\.\./) return 0
    n = split(d, labels, ".")
    if (n < 2) return 0
    for (i = 1; i <= n; i++) {
      if (labels[i] == "" || length(labels[i]) > 63 || labels[i] ~ /^-/ || labels[i] ~ /-$/) return 0
    }
    return 1
  }
  function allowed(d, suffix) {
    suffix = d
    while (suffix != "") {
      if (suffix in allow) return 1
      sub(/^[^.]+\.?/, "", suffix)
    }
    return 0
  }
  BEGIN {
    while ((getline line < allowfile) > 0) {
      sub(/\r$/, "", line); sub(/[[:space:]#].*$/, "", line)
      line = tolower(line); sub(/^\|\|/, "", line); sub(/\^$/, "", line); sub(/^\./, "", line)
      if (valid(line)) allow[line] = 1
    }
    close(allowfile)
  }
  {
    sub(/\r$/, ""); sub(/[[:space:]]*#.*/, "")
    if ($0 ~ /^[[:space:]]*$/) next
    if (source == "antiad-easylist" || source == "hagezi-normal" || source == "1hosts-lite" || source == "adguard-dns" || source == "adguard-base" || source == "adguard-chinese" || source == "banad") {
      if ($0 ~ /^!/) next
      if ($0 ~ /^@@\|\|[a-z0-9.-]+\^($|\$)/) next
      if ($0 !~ /^\|\|[a-z0-9.-]+\^($|\$)/) next
      domain = $0; sub(/^\|\|/, "", domain); sub(/\^($|\$).*/, "", domain)
    } else if (NF == 1) domain = $1
    else if ($1 == "0.0.0.0" || $1 == "127.0.0.1" || $1 == "::" || $1 == "::1") domain = $2
    else next
    domain = tolower(domain); sub(/\.$/, "", domain)
    if (valid(domain) && !allowed(domain) && domain != "localhost") print domain
  }
' source="$source_name" "$source_path"
}

: > "$DOMAINS"
for name in $SOURCE_NAMES; do
  parsed="$LOCK/$name.domains"
  parse_source "$name" "$LOCK/$name" > "$parsed" || {
    say "Rule parser failed for $name; existing rules were kept"
    exit 4
  }
  LC_ALL=C sort -u "$parsed" > "$parsed.sorted" || {
    say "Rule sorting failed for $name; existing rules were kept"
    exit 4
  }
  mv -f "$parsed.sorted" "$parsed" || exit 4
  source_count=$(wc -l < "$parsed" | tr -d ' ')
  case "$source_count" in
    ''|*[!0-9]*) say "Invalid $name rule count; existing rules were kept"; exit 4 ;;
  esac
  source_min=1000
  [ "$name" = "hagezi-normal" ] && source_min=150000
  if [ "$source_count" -lt "$source_min" ] || [ "$source_count" -gt "$MAX_RULES" ]; then
    say "Rejected suspicious $name ruleset ($source_count entries); existing rules were kept"
    exit 4
  fi
  cat "$parsed" >> "$DOMAINS" || exit 4
done

LC_ALL=C sort -u "$DOMAINS" > "$SORTED" || {
  say "Rule sorting failed; existing rules were kept"
  exit 4
}

count=$(wc -l < "$SORTED" | tr -d ' ')
case "$count" in
  ''|*[!0-9]*) say "Invalid rule count; existing rules were kept"; exit 4 ;;
esac
if [ "$count" -lt "$MIN_RULES" ] || [ "$count" -gt "$MAX_RULES" ]; then
  say "Rejected suspicious ruleset ($count entries); existing rules were kept"
  exit 4
fi

# Keep the bounded, high-value hotset selection stable. The full binary uses
# the complete merged union; hosts remains the original common/primary-source
# fast set so adding providers cannot evict known high-frequency entries.
comm -12 "$LOCK/hagezi-normal.domains" "$LOCK/antiad-easylist.domains" | head -n "$HOTSET_COMMON" > "$LOCK/hotset.common" || exit 4
comm -23 "$LOCK/antiad-easylist.domains" "$LOCK/hagezi-normal.domains" | head -n "$HOTSET_ANTIAD" > "$LOCK/hotset.antiad" || exit 4
comm -23 "$LOCK/hagezi-normal.domains" "$LOCK/antiad-easylist.domains" | head -n "$HOTSET_HAGEZI" > "$LOCK/hotset.hagezi" || exit 4
cat "$LOCK/hotset.common" "$LOCK/hotset.antiad" "$LOCK/hotset.hagezi" | LC_ALL=C sort -u > "$LOCK/hotset.domains" || exit 4
hotset_count=$(wc -l < "$LOCK/hotset.domains" | tr -d ' ')
case "$hotset_count" in ''|*[!0-9]*) say "Invalid hotset count; existing rules were kept"; exit 4 ;; esac
if [ "$hotset_count" -lt 1000 ] || [ "$hotset_count" -gt "$HOTSET_MAX" ]; then
  say "Rejected suspicious hosts hotset ($hotset_count entries); existing rules were kept"
  exit 4
fi
source_url() {
  case "$1" in
    hagezi-normal) printf '%s' 'https://codeberg.org/hagezi/mirror2/raw/branch/main/dns-blocklists/adblock/multi.txt' ;;
    antiad-easylist) printf '%s' 'https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-easylist.txt' ;;
    1hosts-lite) printf '%s' 'https://raw.githubusercontent.com/badmojr/1Hosts/master/Lite/domains.txt' ;;
    adguard-dns) printf '%s' 'https://filters.adtidy.org/extension/chromium/filters/15.txt' ;;
    adguard-base) printf '%s' 'https://filters.adtidy.org/extension/chromium/filters/2.txt' ;;
    adguard-chinese) printf '%s' 'https://filters.adtidy.org/extension/chromium/filters/224.txt' ;;
    banad) printf '%s' 'https://raw.githubusercontent.com/damengzhu/banad/main/jiekouAD.txt' ;;
    oisd-big) printf '%s' 'https://big.oisd.nl' ;;
  esac
}

provider_digest_input="$LOCK/provider-digests"
: > "$provider_digest_input" || exit 4
for name in $SOURCE_NAMES; do
  source_hash=$(sha256sum "$LOCK/$name" 2>/dev/null | awk '{ print $1 }')
  [ -n "$source_hash" ] || source_hash=unavailable
  printf '%s=%s\n' "$name" "$source_hash" >> "$provider_digest_input" || exit 4
done

stamp=$(date -u +%Y%m%dT%H%M%SZ)
new_token="$stamp-$$"
generation="$LOCK/generation"
mkdir "$generation" || exit 5
if ! run_staging_compile "$generation/rules.bin"; then
  say "Native rule compilation failed; existing rules were kept"
  exit 5
fi
chmod 0644 "$generation/rules.bin"
digest=$(sha256sum "$generation/rules.bin" 2>/dev/null | awk '{ print $1 }')
[ -n "$digest" ] || digest=unavailable
{
  printf '# STR AdBlocker hosts hotset\n'
  printf '# ruleset=%s\n' "$new_token"
  printf '# domains=%s\n' "$hotset_count"
  printf '# Generated from the bundled provider policy; do not edit.\n'
  while IFS= read -r domain; do
    printf '0.0.0.0 %s\n:: %s\n' "$domain" "$domain"
  done < "$LOCK/hotset.domains"
} > "$generation/hotset.hosts" || exit 5
chmod 0644 "$generation/hotset.hosts"
hotset_digest=$(sha256sum "$generation/hotset.hosts" 2>/dev/null | awk '{ print $1 }')
[ -n "$hotset_digest" ] || hotset_digest=unavailable
{
  printf 'format=1\n'
  printf 'hotset=%s\n' "$hotset_count"
  printf 'ruleset=%s\n' "$new_token"
  printf 'sha256=%s\n' "$hotset_digest"
  printf 'common_limit=%s\n' "$HOTSET_COMMON"
  printf 'antiad_limit=%s\n' "$HOTSET_ANTIAD"
  printf 'hagezi_limit=%s\n' "$HOTSET_HAGEZI"
} > "$generation/hotset.manifest" || exit 5
chmod 0644 "$generation/hotset.manifest"
{
  printf 'format=1\n'
  printf 'ruleset=%s\n' "$new_token"
  if [ -s "$ENDPOINT_SOURCE" ]; then
    awk '!/^format=/ && !/^ruleset=/' "$ENDPOINT_SOURCE"
  fi
} > "$generation/endpoints.txt" || exit 5
chmod 0644 "$generation/endpoints.txt"
endpoint_digest=$(sha256sum "$generation/endpoints.txt" 2>/dev/null | awk '{ print $1 }')
[ -n "$endpoint_digest" ] || endpoint_digest=unavailable
endpoint_count=$(awk 'NF && $1 !~ /^(format|ruleset)=/ { count++ } END { print count + 0 }' "$generation/endpoints.txt")
{
  printf 'format=1\n'
  printf 'rules=%s\n' "$count"
  printf 'ruleset=%s\n' "$new_token"
  printf 'sha256=%s\n' "$digest"
  printf 'unsupported_rule_count=0\n'
  printf 'endpoint_sha256=%s\n' "$endpoint_digest"
  printf 'endpoint_count=%s\n' "$endpoint_count"
  printf 'sources=%s\n' "$(printf '%s,' $SOURCE_NAMES | sed 's/,$//')"
  while IFS='=' read -r source_name source_hash; do
    printf 'source_%s=%s\n' "$source_name" "$(source_url "$source_name")"
    printf 'source_%s_sha256=%s\n' "$source_name" "$source_hash"
  done < "$provider_digest_input"
  provider_digest=$(sha256sum "$provider_digest_input" 2>/dev/null | awk '{ print $1 }')
  [ -n "$provider_digest" ] || provider_digest=unavailable
  printf 'provider_sha256=%s\n' "$provider_digest"
  printf 'hotset=%s\n' "$hotset_count"
  printf 'hotset_sha256=%s\n' "$hotset_digest"
} > "$generation/manifest" || exit 5
chmod 0644 "$generation/manifest"
publish_generation "$generation" "$new_token" "$count" "$hotset_count" "$digest" "$hotset_digest" "$endpoint_digest" "$endpoint_count"
exit $?
