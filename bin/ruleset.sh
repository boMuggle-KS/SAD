#!/system/bin/sh

# Resolve one immutable ruleset generation. Callers receive RULES_PATH,
# MANIFEST_PATH, ENDPOINTS_PATH, and RULESET_ORIGIN without ever combining two
# generations. Endpoint sidecars are optional, but when present they must live
# beside the exact rules.bin/manifest pair selected here.

ruleset_token_valid() {
  case "$1" in
    ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*) return 1 ;;
  esac
}

ruleset_pair_valid() {
  candidate_rules=$1
  candidate_manifest=$2
  verify_digest=${3:-0}
  expected_ruleset=${4:-}
  [ -s "$candidate_rules" ] && [ -s "$candidate_manifest" ] || return 1
  if [ -n "$expected_ruleset" ]; then
    manifest_ruleset=$(awk -F= '$1 == "ruleset" { print $2; exit }' "$candidate_manifest" 2>/dev/null)
    [ "$manifest_ruleset" = "$expected_ruleset" ] || return 1
  fi
  [ "$verify_digest" = 1 ] || return 0
  command -v sha256sum >/dev/null 2>&1 || return 1
  expected_digest=$(awk -F= '$1 == "sha256" { print $2; exit }' "$candidate_manifest" 2>/dev/null)
  [ "${#expected_digest}" -eq 64 ] || return 1
  case "$expected_digest" in *[!0123456789abcdef]*) return 1 ;; esac
  actual_digest=$(sha256sum "$candidate_rules" 2>/dev/null | awk '{ print $1 }')
  [ "$actual_digest" = "$expected_digest" ]
}

# shellcheck disable=SC2034
resolve_ruleset() {
  rules_module=$1
  rules_state=$2
  verify_ruleset=${3:-0}
  RULES_PATH="$rules_module/rules/rules.bin"
  MANIFEST_PATH="$rules_module/rules/manifest"
  ENDPOINTS_PATH=
  [ -f "$rules_module/rules/endpoints.txt" ] && ENDPOINTS_PATH="$rules_module/rules/endpoints.txt"
  RULESET_ORIGIN=bundled

  for pointer_name in rules.active rules.previous; do
    pointer_path="$rules_state/$pointer_name"
    [ -s "$pointer_path" ] || continue
    token=$(sed -n '1p' "$pointer_path" 2>/dev/null)
    ruleset_token_valid "$token" || continue
    candidate_dir="$rules_state/rulesets/$token"
    if ruleset_pair_valid "$candidate_dir/rules.bin" "$candidate_dir/manifest" "$verify_ruleset" "$token"; then
      RULES_PATH="$candidate_dir/rules.bin"
      MANIFEST_PATH="$candidate_dir/manifest"
      ENDPOINTS_PATH=
      [ -f "$candidate_dir/endpoints.txt" ] && ENDPOINTS_PATH="$candidate_dir/endpoints.txt"
      if [ "$pointer_name" = rules.active ]; then
        RULESET_ORIGIN=updated
      else
        RULESET_ORIGIN=updated-rollback
      fi
      return 0
    fi
  done

  ruleset_pair_valid "$RULES_PATH" "$MANIFEST_PATH" "$verify_ruleset"
}
