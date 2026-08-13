#!/system/bin/sh

MODDIR=${1:-${0%/*}/..}
STATE=${STR_STATE_DIR:-/data/adb/str-adblocker}
if [ -n "${STR_RUNTIME_DIR:-}" ]; then
  RUNTIME=$STR_RUNTIME_DIR
elif [ -n "${STR_STATE_DIR:-}" ]; then
  RUNTIME=$STATE
else
  RUNTIME=/dev/str-adblocker
fi
SNAPSHOT="$RUNTIME/flowguard-state.json"
STAGING_REPORT="$STATE/staging-report"
HOTSET_PATH="$MODDIR/system/etc/hosts"
HOTSET_MANIFEST="$MODDIR/rules/hotset.manifest"
HOSTS_TARGET=${STR_HOSTS_TARGET:-/system/etc/hosts}
PROC_ROOT=${STR_PROC_ROOT:-/proc}
. "$MODDIR/bin/runtime_identity.sh"

# Read the atomic JSON snapshot once. The previous implementation launched a
# sed/head pipeline for every field, making one WebUI refresh spawn hundreds of
# short-lived processes. This parser handles both indented and compact JSON;
# only scalar fields used by status are emitted.
snapshot_keys='schema version pid heartbeat_at backend_state reason rules ruleset rules_valid desired_mode profile kernel_mode lease_until_ns resource_state resource_profile resource_generation_peak resource_accounting_state resource_admission_state resource_admission_tokens_truncated resource_admission_peak_breaches resource_child_processes resource_child_process_scope effectiveness effectiveness_window_seconds effectiveness_observed effectiveness_blocked effectiveness_opaque effectiveness_updated_at adapter_dns adapter_endpoint adapter_flow canary_uid canary_process_domain last_e2e_pass tls_allow_canary tls_block_canary quic_block_canary dns_allow_canary dns_block_canary production_rule_canary production_rule_domain canary_verdict_hits profile_s_ready profile_t_ready event_loop_alive ruleset_origin rules_sha256 provider_digest unsupported_rule_count tls_allow_canary_error_code tls_block_canary_error_code quic_block_canary_error_code dns_allow_canary_error_code dns_block_canary_error_code production_rule_canary_error_code ingress_packets ingress_bytes egress_packets egress_bytes tcp_classified quic_samples allowed blocked dropped_packets canary_allowed canary_blocked opaque_allowed ech_unknown event_overflow fail_open_passes errors dns_seen dns_blocked dns_allowed dns_opaque dns_parse_errors dns_encrypted_observed dns_userspace_samples dns_userspace_malformed dns_binding_stored tls_userspace_samples tls_userspace_malformed endpoint_userspace_samples endpoint_blocked endpoint_observed evidence_evictions evidence_slot_misses same_origin_unknown traffic_unobserved flow_start_seen flow_start_binding_hit flow_start_binding_miss flow_start_binding_expired flow_start_binding_ambiguous flow_start_binding_scope_mismatch flow_rule_block verdict_publish_ok verdict_publish_error kernel_verdict_hit resource_rss_kib resource_anon_kib resource_go_heap_kib resource_go_stack_kib resource_vm_peak_kib resource_vm_size_kib resource_rss_file_kib resource_rss_shmem_kib resource_goroutines resource_threads resource_fds resource_workers_running resource_workers_reserved resource_optional_mask resource_queue_bytes resource_queue_reservation_bytes resource_queue_live_bytes resource_queue_live_depth resource_queue_live_scope resource_control_queue_reservation_bytes resource_control_queue_live_bytes resource_control_queue_live_depth resource_diagnostic_reservation_bytes resource_diagnostic_live_bytes resource_diagnostic_live_depth resource_worker_event_mailbox_reservation_bytes resource_worker_event_mailbox_live_bytes resource_worker_event_mailbox_live_depth resource_parser_queue_reservation_bytes resource_parser_queue_live_bytes resource_parser_queue_live_depth resource_parser_slab_reservation_bytes resource_evidence_table_reservation_bytes resource_evidence_table_live_bytes resource_evidence_table_live_flows resource_evidence_table_live_records resource_queue_overflow resource_worker_event_overflow resource_cache_evictions resource_cache_hits resource_cache_misses resource_parser_drops resource_worker_restarts resource_pool_misses resource_cache_bytes resource_cache_entries resource_cache_scope resource_child_processes resource_accounting_state resource_admission_slots resource_admission_active resource_admission_tokens resource_goroutine_reserved resource_goroutine_active resource_goroutine_admission_state resource_unmeasured resource_worker_states'

snapshot_keys="$snapshot_keys dns_plaintext_seen"
snapshot_keys="$snapshot_keys tls_userspace_need_more tls_userspace_record_malformed tls_userspace_non_client_hello tls_userspace_parse_malformed"
snapshot_keys="$snapshot_keys tls_assembly_samples tls_assembly_timeout tls_assembly_budget"
snapshot_keys="$snapshot_keys quic_userspace_samples quic_userspace_decrypt_failed quic_userspace_incomplete quic_userspace_timeout quic_userspace_malformed quic_userspace_sni_unavailable quic_userspace_budget quic_userspace_publish_failed quic_userspace_publish_ok quic_userspace_rule_block"
snapshot_keys="$snapshot_keys dns_userspace_response_malformed dns_userspace_response_partial dns_userspace_response_assembly_dropped"
snapshot_keys="$snapshot_keys dns_query_opaque_samples"
snapshot_keys="$snapshot_keys dns_userspace_opaque_rule_block"
snapshot_keys="$snapshot_keys endpoint_suppressed"
snapshot_keys="$snapshot_keys dns_binding_kernel_hit dns_binding_kernel_block dns_binding_kernel_allow dns_binding_kernel_stored dns_binding_kernel_cleared"
snapshot_keys="$snapshot_keys flow_http_parsed flow_http_host_hit"
snapshot_keys="$snapshot_keys flow_http_request_line flow_start_miss_tcp flow_start_miss_udp"
snapshot_keys="$snapshot_keys allowlist_count default_allowlist_count domain_blacklist_count ip_blacklist_count"
snapshot_values=$(awk -v keys="$snapshot_keys" '
function count_matches(text, needle, n, pos) {
  n = 0
  while ((pos = index(text, needle)) > 0) {
    n++
    text = substr(text, pos + length(needle))
  }
  return n
}
BEGIN { wanted_count = split(keys, wanted, " ") }
{ json = json $0 }
END {
  for (i = 1; i <= wanted_count; i++) {
    key = wanted[i]
    needle = "\"" key "\""
    start = index(json, needle)
    if (!start) continue
    rest = substr(json, start + length(needle))
    sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
    if (substr(rest, 1, 1) == "\"") {
      rest = substr(rest, 2)
      finish = index(rest, "\"")
      value = finish ? substr(rest, 1, finish - 1) : rest
    } else {
      finish = match(rest, /[,}]/)
      value = finish ? substr(rest, 1, finish - 1) : rest
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
    }
    if (value == "null") value = ""
    print key "=" value
  }
  compact = json
  gsub(/[[:space:]]/, "", compact)
  print "__attached_links=" count_matches(compact, "\"attached\":true")
  print "__failed_links=" count_matches(compact, "\"attached\":false")
  print "__sockops_links=" count_matches(compact, "\"kind\":\"sock_ops\"")
  print "__skmsg_links=" count_matches(compact, "\"kind\":\"sk_msg\"")
  print "__tcx_links=" count_matches(compact, "\"kind\":\"tcx\"")
  print "__clsact_links=" count_matches(compact, "\"kind\":\"clsact\"")
  print "__loopback_links=" count_matches(compact, "\"interface\":\"lo\"")
}' "$SNAPSHOT" 2>/dev/null)

value() { printf '%s=%s\n' "$1" "$2"; }
snapshot_public=
attached_links=0
failed_links=0
sockops_links=0
skmsg_links=0
tcx_links=0
clsact_links=0
loopback_links=0
runtime_version=
snapshot_schema=
loaded_ruleset=
rules=
pid=
heartbeat=
backend_state=
reason=
kernel_mode=
rules_valid=
resource_admission_peak_breaches=
effectiveness=unobserved
effectiveness_window_seconds=0
effectiveness_observed=0
effectiveness_blocked=0
effectiveness_opaque=0
effectiveness_updated_at=0

while IFS='=' read -r snapshot_key snapshot_value; do
  case "$snapshot_key" in
    __attached_links) attached_links=${snapshot_value:-0} ;;
    __failed_links) failed_links=${snapshot_value:-0} ;;
    __sockops_links) sockops_links=${snapshot_value:-0} ;;
    __skmsg_links) skmsg_links=${snapshot_value:-0} ;;
    __tcx_links) tcx_links=${snapshot_value:-0} ;;
    __clsact_links) clsact_links=${snapshot_value:-0} ;;
    __loopback_links) loopback_links=${snapshot_value:-0} ;;
    schema) snapshot_schema=$snapshot_value ;;
    version) runtime_version=$snapshot_value ;;
    pid) pid=$snapshot_value ;;
    heartbeat_at) heartbeat=$snapshot_value ;;
    backend_state) backend_state=$snapshot_value ;;
    reason) reason=$snapshot_value ;;
    kernel_mode) kernel_mode=$snapshot_value ;;
    rules) rules=$snapshot_value ;;
    ruleset) loaded_ruleset=$snapshot_value ;;
    rules_valid) rules_valid=$snapshot_value ;;
    resource_admission_peak_breaches) resource_admission_peak_breaches=$snapshot_value ;;
    effectiveness) effectiveness=$snapshot_value ;;
    effectiveness_window_seconds) effectiveness_window_seconds=$snapshot_value ;;
    effectiveness_observed) effectiveness_observed=$snapshot_value ;;
    effectiveness_blocked) effectiveness_blocked=$snapshot_value ;;
    effectiveness_opaque) effectiveness_opaque=$snapshot_value ;;
    effectiveness_updated_at) effectiveness_updated_at=$snapshot_value ;;
    __*) : ;;
    *) snapshot_public="${snapshot_public}${snapshot_key}=${snapshot_value}
" ;;
  esac
done <<EOF
$snapshot_values
EOF

module_version=$(awk -F= '$1 == "version" { print $2; exit }' "$MODDIR/module.prop" 2>/dev/null)
# An installed module may be newer than the resident process until the next
# device reboot. Runtime status follows the daemon snapshot; the module file is
# only a fallback when no live snapshot version exists.
version=$runtime_version
[ -n "$version" ] || version=$module_version
[ -n "$loaded_ruleset" ] || loaded_ruleset=$(awk -F= '$1 == "ruleset" { print $2; exit }' "$MODDIR/rules/manifest" 2>/dev/null)
[ -n "$rules" ] || rules=$(awk -F= '$1 == "rules" { print $2; exit }' "$MODDIR/rules/manifest" 2>/dev/null)

# During a supervised restart, prefer a PID file only when it identifies the
# installed daemon. A stale numeric PID must never mask the live snapshot PID.
snapshot_pid=$pid
pidfile=$(cat "$RUNTIME/strd.pid" 2>/dev/null)
case "$pidfile" in
  ''|*[!0-9]*) pid=$snapshot_pid ;;
  *)
    if runtime_process_matches "$pidfile" "$MODDIR/bin/strd" "$PROC_ROOT"; then
      pid=$pidfile
    elif runtime_process_matches "$snapshot_pid" "$MODDIR/bin/strd" "$PROC_ROOT"; then
      pid=$snapshot_pid
    else
      pid=$pidfile
    fi
    ;;
esac
resident=0
cpu=0
rss=0
if runtime_process_matches "$pid" "$MODDIR/bin/strd" "$PROC_ROOT"; then
  resident=1
  rss=$(awk '/^VmRSS:/ { print $2; exit }' "$PROC_ROOT/$pid/status" 2>/dev/null)
  cpu=$(ps -p "$pid" -o %CPU= 2>/dev/null | awk 'NF { print $1; exit }')
fi

status_now=$(date +%s)
case "$heartbeat" in
  ''|*[!0-9]*) fresh=0 ;;
  *) heartbeat_age=$((status_now - heartbeat)); fresh=0
     [ "$heartbeat_age" -ge 0 ] && [ "$heartbeat_age" -le 6 ] && fresh=1 ;;
esac

# The daemon owns backend health. This shell validates snapshot origin,
# runtime-version presence, process identity, and heartbeat freshness. The
# module file may already be a newer generation before reboot; that is not a
# runtime fault and must not degrade the live old daemon.
protection=inactive
health=qualifying
backend=flowguard-profile-f
if [ "$resident" != 1 ] || [ "$fresh" != 1 ]; then
  backend=fail-open
  backend_state=FAIL_OPEN
  reason=daemon_or_heartbeat_missing
  health=fail-open
elif [ "$snapshot_schema" != 1 ]; then
  backend=fail-open
  backend_state=FAIL_OPEN
  reason=runtime_snapshot_schema_invalid
  health=fail-open
elif [ -z "$runtime_version" ]; then
  backend_state=DEGRADED
  reason=runtime_version_missing
  health=degraded
else
  case "$backend_state" in
    ACTIVE_VERIFIED) protection=active; health=verified ;;
    QUALIFYING|OBSERVE_ONLY) health=qualifying ;;
    DEGRADED|UNSUPPORTED) health=degraded ;;
    FAIL_OPEN) backend=fail-open; health=fail-open ;;
    *) backend=fail-open; backend_state=FAIL_OPEN; reason=runtime_backend_state_invalid; health=fail-open ;;
  esac
fi
dataplane_state=inactive
if [ "$resident" = 1 ] && [ "$fresh" = 1 ] && [ "$snapshot_schema" = 1 ] &&
    [ -n "$runtime_version" ]; then
  case "$kernel_mode" in
    1|3) dataplane_state=ENFORCING ;;
  esac
fi
case "$resource_admission_peak_breaches" in ''|*[!0-9]*) resource_admission_peak_breaches=0 ;; esac

active_ruleset=none
[ "$rules_valid" = true ] && active_ruleset=${loaded_ruleset:-unknown}

# Hosts is an independent prefilter. Verify the merged system target rather
# than treating the module copy as proof of an active overlay.
hotset_state=unconfigured
hotset_count=0
hotset_expected_sha=
hotset_actual_sha=
hotset_target_sha=
if [ -n "$loaded_ruleset" ] && [ -r "$STATE/rulesets/$loaded_ruleset/hotset.manifest" ]; then
  HOTSET_MANIFEST="$STATE/rulesets/$loaded_ruleset/hotset.manifest"
  [ -r "$STATE/rulesets/$loaded_ruleset/hotset.hosts" ] && HOTSET_PATH="$STATE/rulesets/$loaded_ruleset/hotset.hosts"
fi
hotset_count=$(awk -F= '$1 == "hotset" { print $2; exit }' "$HOTSET_MANIFEST" 2>/dev/null)
hotset_expected_sha=$(awk -F= '$1 == "sha256" { print $2; exit }' "$HOTSET_MANIFEST" 2>/dev/null)
hotset_actual_sha=$(sha256sum "$HOTSET_PATH" 2>/dev/null | awk '{ print $1; exit }')
hotset_target_sha=$(sha256sum "$HOSTS_TARGET" 2>/dev/null | awk '{ print $1; exit }')
hotset_source_sha=$(sha256sum "$HOTSET_PATH" 2>/dev/null | awk '{ print $1; exit }')
hotset_marker_sha=$(cat "$RUNTIME/hosts.bind" 2>/dev/null)
case "$hotset_count" in ''|*[!0-9]*) hotset_count=0 ;; esac
case "$hotset_expected_sha:$hotset_actual_sha" in
  *[!0123456789abcdef:]*|:*) hotset_state=unconfigured ;;
  *)
    if [ "${#hotset_expected_sha}" -eq 64 ] && [ "${#hotset_actual_sha}" -eq 64 ] && [ "$hotset_expected_sha" = "$hotset_actual_sha" ]; then
      # KernelSU exposes system/etc through its merged root. Hashing the
      # merged target proves the overlay is visible to this process; the
      # module copy alone only proves package integrity.
      if [ "${#hotset_target_sha}" -eq 64 ] && [ "$hotset_target_sha" = "$hotset_expected_sha" ]; then
        hotset_state=mounted
      elif [ -e "$HOSTS_TARGET" ]; then
        hotset_state=mismatch
      else
        hotset_state=unmounted
      fi
    else
      hotset_state=mismatch
    fi
    ;;
esac
private_dns=$(settings get global private_dns_mode 2>/dev/null)
case "$private_dns" in ''|null) private_dns=automatic ;; esac

staging_state=
staging_sample_state=
staging_peak_rss_kib=
staging_peak_fds=
staging_peak_cpu_ticks=
staging_output_bytes=
staging_temporary_bytes_kib=
staging_timestamp=
if [ -r "$STAGING_REPORT" ]; then
  while IFS='=' read -r staging_key staging_value; do
    case "$staging_key" in
      state) staging_state=$staging_value ;;
      sample_state) staging_sample_state=$staging_value ;;
      peak_rss_kib) staging_peak_rss_kib=$staging_value ;;
      peak_fds) staging_peak_fds=$staging_value ;;
      peak_cpu_ticks) staging_peak_cpu_ticks=$staging_value ;;
      output_bytes) staging_output_bytes=$staging_value ;;
      temporary_bytes_kib) staging_temporary_bytes_kib=$staging_value ;;
      timestamp) staging_timestamp=$staging_value ;;
    esac
  done < "$STAGING_REPORT"
fi
cloud_update_state=idle
cloud_update_at=0
cloud_update_message=
if [ -e "$RUNTIME/cloud-update.running" ]; then
  cloud_update_state=running
elif [ -s "$STATE/cloud-update.request" ]; then
  cloud_update_state=pending
elif [ -r "$STATE/cloud-update.last" ]; then
  while IFS='=' read -r cloud_key cloud_value; do
    case "$cloud_key" in
      state) cloud_update_state=$cloud_value ;;
      timestamp) cloud_update_at=$cloud_value ;;
      message) cloud_update_message=$cloud_value ;;
    esac
  done < "$STATE/cloud-update.last"
fi
case "$cloud_update_state" in running|pending|ok|failed|idle) : ;; *) cloud_update_state=idle ;; esac
case "$cloud_update_at" in ''|*[!0-9]*) cloud_update_at=0 ;; esac
cloud_update_stage=
if [ "$cloud_update_state" = running ] && [ -r "$RUNTIME/cloud-update.stage" ]; then
  cloud_update_stage=$(awk -F= '$1 == "stage" { print $2; exit }' "$RUNTIME/cloud-update.stage" 2>/dev/null)
fi
case "$cloud_update_stage" in download|verify|publish) : ;; *) cloud_update_stage= ;; esac
cloud_update_enabled=false
cloud_update_url=$(cat "$STATE/cloud-update-url" 2>/dev/null)
case "$cloud_update_url" in https://*) cloud_update_enabled=true ;; esac
cloud_update_interval=$(cat "$STATE/cloud-update-interval" 2>/dev/null)
case "$cloud_update_interval" in ''|*[!0-9]*) cloud_update_interval=129600 ;; esac
profile_t_adapter=unavailable
if [ "$tcx_links" -gt 0 ] && [ "$clsact_links" -gt 0 ]; then
  profile_t_adapter=mixed
elif [ "$tcx_links" -gt 0 ]; then
  profile_t_adapter=tcx
elif [ "$clsact_links" -gt 0 ]; then
  profile_t_adapter=clsact
fi

# A user pause stops the daemon, detaches the dataplane and unmounts hosts;
# report the paused state instead of a stale fail-open snapshot.
if [ -e "$STATE/pause" ]; then
  backend_state=PAUSED
  backend_health=paused
  backend_reason=user_paused
  protection=paused
fi

# Keep the public schema compatible while avoiding a second snapshot parse.
printf '%s' "$snapshot_public"
value status_schema 2
value status_source live
value version "${version:-unknown}"
value runtime_version "${runtime_version:-unknown}"
value mount not-required
value hosts_state "$hotset_state"
value hosts_count "$hotset_count"
value hosts_sha256 "${hotset_target_sha:-unknown}"
value hosts_source_sha "${hotset_source_sha:-unknown}"
value hosts_marker_sha "${hotset_marker_sha:-unknown}"
value hosts_target "$HOSTS_TARGET"
value hosts_scope system_resolver_prefilter
value backend "$backend"
value backend_state "${backend_state:-FAIL_OPEN}"
# 暂停分支设置的是 backend_health/backend_reason，其余路径由 health/reason 兜底
value backend_health "${backend_health:-$health}"
value backend_reason "${backend_reason:-${reason:-unknown}}"
value dataplane_state "$dataplane_state"
value kernel_mode "${kernel_mode:-0}"
value rules "${rules:-0}"
value ruleset "${loaded_ruleset:-unknown}"
value resource_admission_peak_breaches "$resource_admission_peak_breaches"
value effectiveness "${effectiveness:-unobserved}"
value effectiveness_window_seconds "${effectiveness_window_seconds:-0}"
value effectiveness_observed "${effectiveness_observed:-0}"
value effectiveness_blocked "${effectiveness_blocked:-0}"
value effectiveness_opaque "${effectiveness_opaque:-0}"
value effectiveness_updated_at "${effectiveness_updated_at:-0}"
value protection "$protection"
value profile_t_adapter "$profile_t_adapter"
value profile_t_tcx_links "$tcx_links"
value profile_t_clsact_links "$clsact_links"
value active_ruleset "$active_ruleset"
value staging_state "$staging_state"
value staging_sample_state "$staging_sample_state"
value staging_peak_rss_kib "$staging_peak_rss_kib"
value staging_peak_fds "$staging_peak_fds"
value staging_peak_cpu_ticks "$staging_peak_cpu_ticks"
value staging_output_bytes "$staging_output_bytes"
value staging_temporary_bytes_kib "$staging_temporary_bytes_kib"
value staging_timestamp "$staging_timestamp"
value cloud_update_state "$cloud_update_state"
value cloud_update_at "$cloud_update_at"
value cloud_update_message "$cloud_update_message"
value cloud_update_stage "$cloud_update_stage"
value cloud_update_enabled "$cloud_update_enabled"
value cloud_update_interval "$cloud_update_interval"
value private_dns "$private_dns"
value resident_processes "$resident"
value cpu_percent "${cpu:-0}"
value rss_kb "${rss:-0}"
