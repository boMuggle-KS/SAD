const MODULE_DIR = "/data/adb/modules/str_adblocker";
const IP_BLACKLIST_PATH = "/data/adb/str-adblocker/ip-blacklist.txt";
const DOMAIN_BLACKLIST_PATH = "/data/adb/str-adblocker/domain-blacklist.txt";
const ALLOWLIST_PATH = "/data/adb/str-adblocker/allowlist.txt";
const ACTIVITY_REQUEST = "/dev/str-adblocker/activity.request";
const ACTIVITY_FILE = "/dev/str-adblocker/activity.json";
const DEFAULT_CLOUD_URL = "https://github.com/310DSD/STR-ADBlocker-rules/releases/latest/download/generation.tar.gz";
let bridge = { mode: "none", reason: "" };
const numberFormat = new Intl.NumberFormat("zh-CN");
const previewStatus = {
  version: "1.0.39", backend_state: "QUALIFYING", backend_health: "qualifying", dataplane_state: "inactive",
  backend_reason: "profile_f_not_ready", protection: "inactive", desired_mode: "enforce",
  rules: "222410", blocked: "0", tcp_classified: "0", quic_samples: "0",
  resident_processes: "1", cpu_percent: "0.1", rss_kb: "8000", effectiveness: "unobserved",
  cloud_update_interval: "129600", cloud_update_enabled: "true"
};
let state = { ...previewStatus };
let refreshPromise;
let snackTimer;
let hasLiveStatus = false;
let statusFailures = 0;
let renderedSignature = "";
const nodes = {};
let activityTimer = null;
let activityLoading = false;

function isEditableFocused() {
  const active = document.activeElement;
  if (!active) return false;
  return active.matches?.("input, textarea, select, [contenteditable='true']") || active.isContentEditable === true;
}

function cacheNodes() {
  for (const id of ["statusHero", "heroKicker", "heroBadgeValue", "versionText", "statusTitle", "statusDetail", "rulesValue", "blockedValue", "queryValue", "processValue", "resourceValue", "effectivenessValue", "effectivenessDetail", "backendValue", "healthValue", "reasonValue", "activeRulesetValue", "cloudUpdateButton", "cloudIntervalSelect", "hostsStateValue", "hostsDetailValue", "ipBlacklistCount", "domainBlacklistCount", "domainBlacklistInput", "domainBlacklistHint", "domainAllowlistCount", "domainAllowlistInput", "domainAllowlistHint", "pauseButton", "activityAllowedList", "activityBlockedList", "activityAllowedCount", "activityBlockedCount", "snackbar"]) {
    nodes[id] = document.getElementById(id);
  }
}

function bridgeExecAsync(command) {
  return new Promise((resolve, reject) => {
    const callback = `str_callback_${Date.now()}_${Math.random().toString(36).slice(2)}`;
    let settled = false;
    const finish = (...args) => {
      if (settled) return;
      settled = true;
      delete window[callback];
      if (args.length === 1 && Array.isArray(args[0])) args = args[0];
      if (args.length === 1 && args[0] && typeof args[0] === "object") {
        const result = args[0];
        resolve({
          errno: Number(result.errno ?? result.code ?? 0),
          stdout: result.stdout ?? result.output ?? result.data ?? "",
          stderr: result.stderr ?? result.error ?? ""
        });
        return;
      }
      const [errno, stdout, stderr] = args;
      resolve({ errno: Number(errno ?? 0), stdout: stdout ?? "", stderr: stderr ?? "" });
    };
    window[callback] = finish;
    try {
      const returned = window.ksu.exec(command, "{}", callback);
      if (returned && typeof returned.then === "function") {
        returned.then(finish).catch(error => {
          if (settled) return;
          settled = true;
          delete window[callback];
          reject(error);
        });
      }
    } catch (error) {
      delete window[callback];
      reject(error);
    }
  });
}

function bridgeExecSync(command) {
  const out = String(window.ksu.exec(command) ?? "");
  return Promise.resolve({ errno: 0, stdout: out, stderr: "" });
}

function bridgeExec(command) {
  if (bridge.mode === "async") return bridgeExecAsync(command);
  if (bridge.mode === "sync") {
    try {
      return bridgeExecSync(command);
    } catch (error) {
      return Promise.reject(error);
    }
  }
  return Promise.reject(new Error(bridge.reason || "WebUI 桥接不可用"));
}

function probeBridgeAsync() {
  return new Promise(resolve => {
    const callback = `str_probe_${Date.now()}_${Math.random().toString(36).slice(2)}`;
    let done = false;
    const finish = result => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      delete window[callback];
      resolve(result);
    };
    const timer = setTimeout(() => finish({ ok: false, error: "async_timeout" }), 8000);
    window[callback] = (errno, stdout, stderr) => {
      if (String(stdout ?? "").includes("str-bridge-ok")) finish({ ok: true });
      else finish({ ok: false, error: `async_mismatch errno=${errno} out=${String(stdout ?? "").slice(0, 40)} err=${String(stderr ?? "").slice(0, 40)}` });
    };
    try {
      const returned = window.ksu.exec("echo str-bridge-ok", "{}", callback);
      if (returned && typeof returned.then === "function") {
        returned.then(result => {
          if (String(result?.stdout ?? "").includes("str-bridge-ok")) finish({ ok: true });
          else finish({ ok: false, error: "async_return_mismatch" });
        }).catch(error => finish({ ok: false, error: String(error?.message || error) }));
      }
    } catch (error) {
      finish({ ok: false, error: String(error?.message || error) });
    }
  });
}

function probeBridgeSync() {
  try {
    const out = String(window.ksu.exec("echo str-bridge-ok") ?? "");
    return out.includes("str-bridge-ok") ? { ok: true } : { ok: false, error: `sync_mismatch out=${out.slice(0, 60)}` };
  } catch (error) {
    return { ok: false, error: String(error?.message || error) };
  }
}

let probePromise = null;

async function probeBridge() {
  if (probePromise) return probePromise;
  probePromise = (async () => {
    if (typeof window.ksu?.exec !== "function") {
      bridge = { mode: "none", reason: "当前页面未检测到控制桥接（window.ksu）。请通过 SAD 控制应用打开本页，不要在普通浏览器中打开。" };
      return;
    }
    const asyncResult = await probeBridgeAsync();
    if (asyncResult.ok) {
      bridge = { mode: "async" };
      return;
    }
    const syncResult = probeBridgeSync();
    if (syncResult.ok) {
      bridge = { mode: "sync" };
      return;
    }
    bridge = { mode: "none", reason: `桥接调用失败（异步: ${asyncResult.error}; 同步: ${syncResult.error}）。请确认模块已正确安装并通过 SAD 控制应用打开本页。` };
  })();
  try {
    return await probePromise;
  } finally {
    probePromise = null;
  }
}

function parseValues(text) {
  if (Array.isArray(text)) text = text.join("\n");
  if (text && typeof text !== "string") {
    text = text.stdout ?? text.output ?? text.data ?? String(text);
  }
  return String(text || "").split(/\r?\n/).reduce((result, line) => {
    const at = line.indexOf("=");
    if (at > 0) result[line.slice(0, at).trim()] = line.slice(at + 1).trim();
    return result;
  }, {});
}

function parseLiveStatus(text) {
  const parsed = parseValues(text);
  if (parsed.status_source !== "live" || parsed.status_schema !== "2" || !parsed.backend_state || !parsed.version) {
    throw new Error("invalid_or_stale_status_output");
  }
  return parsed;
}

function setText(id, value) {
  const node = nodes[id] || document.getElementById(id);
  if (node) node.textContent = value;
}

function numeric(value) {
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function count(value) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? numberFormat.format(parsed) : "--";
}

function blacklistLines(value) {
  const lines = String(value || "").split(/\r?\n/).map(line => line.split("#", 1)[0].trim()).filter(Boolean);
  if (lines.length > 1000) throw new Error("最多只能保存 1000 条");
  for (const line of lines) {
    if (!/^[0-9a-fA-F:.]+(?:\/\d{1,3})?$/.test(line)) throw new Error(`格式无法识别：${line}`);
  }
  return [...new Set(lines)].join("\n") + (lines.length ? "\n" : "");
}

function setBlacklistPage(open) {
  document.getElementById("overviewView").hidden = open;
  document.getElementById("blacklistView").hidden = !open;
  if (open) document.getElementById("ipBlacklistInput").focus();
}

async function openBlacklistEditor() {
  try {
    const result = await bridgeExec(`cat ${IP_BLACKLIST_PATH} 2>/dev/null`);
    if (Number(result.errno) !== 0 && result.stderr) throw new Error(result.stderr);
    const input = document.getElementById("ipBlacklistInput");
    input.value = result.stdout || "";
    const entries = input.value.trim() ? blacklistLines(input.value).split(/\n/).filter(Boolean).length : 0;
    setText("ipBlacklistCount", `${entries} 条`);
    setBlacklistPage(true);
  } catch (error) {
    notify(`读取黑名单失败：${error.message || "未知错误"}`);
  }
}

async function saveBlacklist() {
  const hint = document.getElementById("ipBlacklistHint");
  try {
    const normalized = blacklistLines(document.getElementById("ipBlacklistInput").value);
    const encoded = btoa(normalized);
    const entries = normalized ? normalized.split(/\n/).filter(Boolean).length : 0;
    const command = `mkdir -p /data/adb/str-adblocker && printf '%s' '${encoded}' | base64 -d > ${IP_BLACKLIST_PATH}.new && chmod 0600 ${IP_BLACKLIST_PATH}.new && mv -f ${IP_BLACKLIST_PATH}.new ${IP_BLACKLIST_PATH} && sh ${MODULE_DIR}/bin/restart.sh ${MODULE_DIR} blacklist_updated ip_blacklist ${entries} 600`;
    const result = await bridgeExec(command);
    if (Number(result.errno) !== 0) throw new Error(String(result.stdout || result.stderr || "").trim() || "保存失败");
    setText("ipBlacklistCount", `${entries} 条`);
    hint.textContent = "已保存并已生效。";
    notify("IP 黑名单已保存并生效");
  } catch (error) {
    hint.textContent = error.message || "输入格式无效";
    notify("黑名单未保存");
  }
}

async function testBlacklistPath() {
  const hint = document.getElementById("ipBlacklistHint");
  try {
    await refreshStatus();
    const adapter = state.profile_t_adapter || "unavailable";
    const blocked = count(state.endpoint_blocked || 0);
    hint.textContent = adapter === "unavailable" ? "endpoint 拦截链路尚未加载。" : `endpoint 链路已加载，当前累计阻断 ${blocked} 次；真实命中需访问名单地址。`;
  } catch (error) {
    hint.textContent = `检查失败：${error.message || "状态不可用"}`;
  }
}

function domainLines(value) {
  const lines = String(value || "").split(/\r?\n/).map(line => line.split("#", 1)[0].trim().toLowerCase()).filter(Boolean);
  if (lines.length > 1000) throw new Error("域名黑名单最多 1000 条");
  const result = [];
  const seen = new Set();
  for (const raw of lines) {
    let line = raw.replace(/^\.+/, "").replace(/\.+$/, "");
    if (line.startsWith("*.")) line = line.slice(2);
    if (line.length > 253) throw new Error(`??????? 253 ????${raw}`);
    if (line.split(".").some(label => label.length > 63)) throw new Error(`??????? 63 ????${raw}`);
    if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/.test(line)) {
      throw new Error(`格式无法识别：${raw}`);
    }
    if (!seen.has(line)) {
      seen.add(line);
      result.push(line);
    }
  }
  return result.join("\n") + (result.length ? "\n" : "");
}

function setDomainBlacklistPage(open) {
  document.getElementById("overviewView").hidden = open;
  document.getElementById("domainBlacklistView").hidden = !open;
  if (open) document.getElementById("domainBlacklistInput").focus();
}

async function openDomainBlacklistEditor() {
  try {
    const result = await bridgeExec(`cat ${DOMAIN_BLACKLIST_PATH} 2>/dev/null`);
    if (Number(result.errno) !== 0 && result.stderr) throw new Error(result.stderr);
    const input = document.getElementById("domainBlacklistInput");
    input.value = result.stdout || "";
    const entries = input.value.trim() ? domainLines(input.value).split(/\n/).filter(Boolean).length : 0;
    setText("domainBlacklistCount", `${entries} 条`);
    setDomainBlacklistPage(true);
  } catch (error) {
    notify(`读取域名黑名单失败：${error.message || "未知错误"}`);
  }
}

async function saveDomainBlacklist() {
  const hint = document.getElementById("domainBlacklistHint");
  try {
    const normalized = domainLines(document.getElementById("domainBlacklistInput").value);
    const encoded = btoa(normalized);
    const entries = normalized ? normalized.split(/\n/).filter(Boolean).length : 0;
    const command = `mkdir -p /data/adb/str-adblocker && printf '%s' '${encoded}' | base64 -d > ${DOMAIN_BLACKLIST_PATH}.new && chmod 0600 ${DOMAIN_BLACKLIST_PATH}.new && mv -f ${DOMAIN_BLACKLIST_PATH}.new ${DOMAIN_BLACKLIST_PATH} && sh ${MODULE_DIR}/bin/restart.sh ${MODULE_DIR} blacklist_updated domain_blacklist ${entries} 600`;
    const result = await bridgeExec(command);
    if (Number(result.errno) !== 0) throw new Error(String(result.stdout || result.stderr || "").trim() || "保存失败");
    setText("domainBlacklistCount", `${entries} 条`);
    hint.textContent = "已保存并已生效。";
    notify("域名黑名单已保存并生效");
  } catch (error) {
    hint.textContent = error.message || "输入格式无效";
    notify("域名黑名单未保存");
  }
}

function setDomainAllowlistPage(open) {
  document.getElementById("overviewView").hidden = open;
  document.getElementById("domainAllowlistView").hidden = !open;
  if (open) document.getElementById("domainAllowlistInput").focus();
}

async function openDomainAllowlistEditor() {
  try {
    const result = await bridgeExec(`cat ${ALLOWLIST_PATH} 2>/dev/null`);
    if (Number(result.errno) !== 0 && result.stderr) throw new Error(result.stderr);
    const input = document.getElementById("domainAllowlistInput");
    input.value = result.stdout || "";
    const entries = input.value.trim() ? domainLines(input.value).split(/\n/).filter(Boolean).length : 0;
    setText("domainAllowlistCount", `${entries} 条`);
    setDomainAllowlistPage(true);
  } catch (error) {
    notify(`读取域名白名单失败：${error.message || "未知错误"}`);
  }
}

async function saveDomainAllowlist() {
  const hint = nodes.domainAllowlistHint || document.getElementById("domainAllowlistHint");
  try {
    const normalized = domainLines(document.getElementById("domainAllowlistInput").value);
    const encoded = btoa(normalized);
    const entries = normalized ? normalized.split(/\n/).filter(Boolean).length : 0;
    const command = `mkdir -p /data/adb/str-adblocker && printf '%s' '${encoded}' | base64 -d > ${ALLOWLIST_PATH}.new && chmod 0600 ${ALLOWLIST_PATH}.new && mv -f ${ALLOWLIST_PATH}.new ${ALLOWLIST_PATH} && sh ${MODULE_DIR}/bin/restart.sh ${MODULE_DIR} allowlist_updated domain_allowlist ${entries} 600; sh ${MODULE_DIR}/bin/update.sh rebuild-request`;
    const result = await bridgeExec(command);
    if (Number(result.errno) !== 0) throw new Error(String(result.stdout || result.stderr || "").trim() || "保存失败");
    setText("domainAllowlistCount", `${entries} 条`);
    hint.textContent = "已保存并已生效。";
    notify("域名白名单已保存并生效");
  } catch (error) {
    hint.textContent = error.message || "输入格式无效";
    notify("白名单未保存");
  }
}

async function togglePause() {
  const button = nodes.pauseButton || document.getElementById("pauseButton");
  if (!button) return;
  const paused = state.protection === "paused" || state.backend_state === "PAUSED";
  const command = paused
    ? "rm -f /data/adb/str-adblocker/pause"
    : `: > /data/adb/str-adblocker/pause && sh ${MODULE_DIR}/bin/backend.sh ${MODULE_DIR} stop`;
  try {
    const result = await bridgeExec(command);
    if (Number(result.errno) !== 0) throw new Error(String(result.stderr || result.stdout || "").trim() || "操作失败");
    notify(paused ? "已请求恢复，防护即将生效" : "已请求暂停，2 秒内生效");
    setTimeout(() => { if (!document.hidden) refreshStatus(); }, paused ? 2500 : 2200);
  } catch (error) {
    notify(`操作失败：${error.message || "未知错误"}`);
  }
}

function setActivityPage(open) {
  document.getElementById("overviewView").hidden = open;
  document.getElementById("activityView").hidden = !open;
  if (open) {
    loadActivity();
    if (!activityTimer) {
      activityTimer = setInterval(() => {
        if (!document.hidden && !document.getElementById("activityView").hidden) loadActivity(true);
      }, 1000);
    }
  } else if (activityTimer) {
    clearInterval(activityTimer);
    activityTimer = null;
  }
}

async function loadActivity(silent = false) {
  if (activityLoading) return;
  activityLoading = true;
  try {
    // Keep the last published snapshot visible while the daemon services the
    // request. The control loop is intentionally bounded and may take several
    // seconds to reach this marker; deleting the previous file first turns
    // that normal latency into a visible empty-list flicker.
    await bridgeExec(`: > ${ACTIVITY_REQUEST}`);
    for (let attempt = 0; attempt < 15; attempt++) {
      await new Promise(resolve => setTimeout(resolve, 400));
      // The daemon removes the request marker only after atomically publishing
      // a complete activity snapshot. Until then, keep rendering the last
      // known-good data instead of treating a missing/partial file as empty.
      const result = await bridgeExec(`if [ -e ${ACTIVITY_REQUEST} ]; then exit 3; fi; cat ${ACTIVITY_FILE} 2>/dev/null`);
      if (Number(result.errno) !== 0) continue;
      try {
        const parsed = JSON.parse(String(result.stdout || ""));
        if (!Array.isArray(parsed.items)) continue;
        renderActivity(parsed.items);
        break;
      } catch (error) {
        // A concurrent read of the atomic output is retried on the next tick.
      }
    }
  } catch (error) {
    if (!silent) notify(`读取域名活动失败：${error.message || "未知错误"}`);
  } finally {
    activityLoading = false;
  }
}

function renderActivity(items) {
  const allowed = [];
  const blocked = [];
  for (const item of items) {
    if (!item || !item.d) continue;
    (Number(item.a) === 2 ? blocked : allowed).push(item);
  }
  renderActivityList(nodes.activityAllowedList || document.getElementById("activityAllowedList"), allowed.slice(0, 100));
  renderActivityList(nodes.activityBlockedList || document.getElementById("activityBlockedList"), blocked.slice(0, 100));
  setText("activityAllowedCount", `${allowed.length} 条`);
  setText("activityBlockedCount", `${blocked.length} 条`);
}

function renderActivityList(list, items) {
  const scrollTop = list.scrollTop;
  const fragment = document.createDocumentFragment();
  for (const item of items) {
    const li = document.createElement("li");
    const time = document.createElement("span");
    time.className = "activity-time";
    time.textContent = new Date(Number(item.t)).toLocaleTimeString("zh-CN", { hour12: false });
    const domain = document.createElement("strong");
    domain.textContent = item.d;
    const tag = document.createElement("span");
    tag.className = "activity-source";
    tag.textContent = String(item.s || "unknown").toUpperCase();
    li.append(time, domain, tag);
    fragment.appendChild(li);
  }
  list.replaceChildren(fragment);
  list.scrollTop = scrollTop;
}

function hostsPresentation(stateValue) {
  return {
    mounted: ["已生效", ""],
    mismatch: ["校验失败", "文件与清单不一致"],
    unmounted: ["未挂载", "系统目标未使用热集"],
    unconfigured: ["未配置", "未发现前置热集"]
  }[stateValue] || ["未知", "等待状态读取"];
}

function reasonText(value) {
  const labels = {
    profile_f_not_ready: "启动检查未完成",
    canary_not_verified: "启动检查未完成",
    daemon_or_heartbeat_missing: "守护进程未运行",
    ruleset_resolution_failed: "规则加载失败",
    runtime_snapshot_schema_invalid: "运行状态无效",
    runtime_version_mismatch: "版本不一致"
  };
  return labels[value] || (value ? value.replaceAll("_", " ") : "暂时未知");
}

function notify(message) {
  const bar = nodes.snackbar || document.getElementById("snackbar");
  bar.textContent = message;
  bar.classList.add("is-visible");
  clearTimeout(snackTimer);
  snackTimer = setTimeout(() => bar.classList.remove("is-visible"), 2800);
}

const statePresentation = {
  PAUSED: ["已暂停", "用户暂停，全部拦截已停止"],
  ACTIVE_VERIFIED: ["保护生效", "广告与连接正在拦截"],
  OBSERVE_ONLY: ["观察模式", "仅记录流量，不拦截"],
  QUALIFYING: ["正在启动", "正在完成启动检查"],
  DEGRADED: ["保护受限", "部分保护暂不可用"],
  FAIL_OPEN: ["故障开放", "网络正常，暂未执行拦截"],
  UNSUPPORTED: ["设备不支持", "当前系统无法运行"],
  STATUS_UNAVAILABLE: ["状态不可用", "暂时无法读取模块状态"]
};

function renderStatus() {
  const signature = JSON.stringify(state);
  if (signature === renderedSignature) return;
  renderedSignature = signature;
  const backendState = state.backend_state || "FAIL_OPEN";
  const paused = state.protection === "paused" || backendState === "PAUSED";
  const verified = backendState === "ACTIVE_VERIFIED" && state.protection === "active";
  const dataplaneActive = state.dataplane_state === "ENFORCING";
  const active = verified || dataplaneActive;
  const dataplaneDegraded = dataplaneActive && !verified;
  const qualifying = backendState === "QUALIFYING" || backendState === "OBSERVE_ONLY";
  const unavailable = backendState === "STATUS_UNAVAILABLE";
  const presentation = statePresentation[backendState] || statePresentation.FAIL_OPEN;
  const hero = nodes.statusHero || document.getElementById("statusHero");
  hero.classList.toggle("is-inactive", !active && !qualifying);
  hero.classList.toggle("is-qualifying", qualifying);
  setText("heroKicker", paused ? "用户暂停" : dataplaneDegraded ? "实时拦截" : active ? "实时防护" : qualifying ? "正在准备" : "需要检查");
  setText("heroBadgeValue", paused ? "OFF" : active ? "ON" : qualifying ? "WAIT" : "OFF");
  setText("versionText", `版本 ${state.version || "--"}`);
  setText("statusTitle", unavailable ? "状态不可用" : paused ? "已暂停" : dataplaneDegraded ? "拦截生效" : active ? "运行中" : qualifying ? "启动中" : "故障");
  setText("statusDetail", paused ? "全部拦截已停止，点击下方按钮恢复" : dataplaneDegraded ? "内核拦截链路正常，健康检查仍在降级" : presentation[1]);
  if (nodes.pauseButton) nodes.pauseButton.textContent = paused ? "恢复" : "暂停";
  setText("rulesValue", count(state.rules));
  setText("blockedValue", count(state.blocked));
  const classified = (numeric(state.tcp_classified) || 0) + (numeric(state.quic_samples) || 0);
  setText("queryValue", `${count(classified)} 次分类`);
  setText("processValue", state.resident_processes === "1" ? "在线" : "离线");
  setText("resourceValue", `CPU ${state.cpu_percent || "--"}% · RSS ${state.rss_kb ? `${count(state.rss_kb)} KiB` : "--"}`);
  const observed = numeric(state.effectiveness_observed) || 0;
  const blocked = numeric(state.effectiveness_blocked) || 0;
  const rate = observed > 0 ? `${(blocked / observed * 100).toFixed(1)}%` : "--";
  setText("effectivenessValue", state.effectiveness === "measured" ? rate : "等待流量");
  setText("effectivenessDetail", observed > 0 ? `真实流量 · ${count(observed)} 次样本` : "打开应用后自动统计");
  setText("backendValue", dataplaneDegraded ? "拦截生效" : active ? "运行中" : presentation[0]);
  setText("healthValue", active ? "正常" : (state.backend_health || "未验证"));
  setText("reasonValue", active ? "规则正常" : reasonText(state.backend_reason));
  const origin = { bundled: "内置", updated: "在线更新", "updated-rollback": "回退版本" }[state.ruleset_origin];
  const ruleset = state.active_ruleset || state.ruleset || "--";
  setText("activeRulesetValue", origin ? `${ruleset} · ${origin}` : ruleset);
  const cloudState = state.cloud_update_state || "idle";
  const cloudIntervalSeconds = numeric(state.cloud_update_interval) || 129600;
  if (nodes.cloudUpdateButton) nodes.cloudUpdateButton.disabled = cloudState === "running";
  syncCloudIntervalSelect(cloudState, cloudIntervalSeconds);
  const hostsState = state.hosts_state || "unconfigured";
  const hosts = hostsPresentation(hostsState);
  if (nodes.hostsStateValue) nodes.hostsStateValue.dataset.state = hostsState;
  setText("hostsStateValue", hosts[0]);
  setText("hostsDetailValue", hosts[1]);
}

function renderUnavailable(error) {
  state = { ...state, backend_state: "STATUS_UNAVAILABLE", backend_health: "unknown", backend_reason: error?.message || "status_bridge_failed", protection: "unknown" };
  renderStatus();
}

function syncCloudIntervalSelect(cloudState, intervalSeconds) {
  const select = nodes.cloudIntervalSelect || document.getElementById("cloudIntervalSelect");
  if (!select) return;
  const seconds = String(intervalSeconds);
  let custom = null;
  for (const option of select.options) {
    if (option.dataset.custom === "1") { custom = option; break; }
  }
  const hasPreset = [...select.options].some(option => option.value === seconds);
  if (hasPreset) {
    if (custom) custom.remove();
  } else {
    if (!custom) {
      custom = document.createElement("option");
      custom.dataset.custom = "1";
      select.appendChild(custom);
    }
    custom.value = seconds;
    custom.textContent = `自定义 ${Math.round(Number(seconds) / 3600)} 小时`;
  }
  select.value = seconds;
  select.disabled = cloudState === "running";
}

async function setCloudInterval() {
  const select = nodes.cloudIntervalSelect || document.getElementById("cloudIntervalSelect");
  if (!select || select.disabled) return;
  const seconds = Number.parseInt(select.value, 10);
  if (!Number.isFinite(seconds) || seconds < 3600 || seconds > 604800) {
    syncCloudIntervalSelect(state.cloud_update_state, numeric(state.cloud_update_interval) || 129600);
    notify("自动更新间隔无效");
    return;
  }
  select.disabled = true;
  try {
    const result = await bridgeExec(`mkdir -p /data/adb/str-adblocker && printf '%s\n' ${seconds} > /data/adb/str-adblocker/cloud-update-interval.new && chmod 0600 /data/adb/str-adblocker/cloud-update-interval.new && mv -f /data/adb/str-adblocker/cloud-update-interval.new /data/adb/str-adblocker/cloud-update-interval`);
    if (Number(result.errno) !== 0) throw new Error(result.stderr || "save_failed");
    state.cloud_update_interval = String(seconds);
    renderStatus();
    notify(`自动更新间隔已设为 ${Math.round(seconds / 3600)} 小时`);
  } catch (error) {
    notify(`保存失败：${error.message || "未知错误"}`);
    syncCloudIntervalSelect(state.cloud_update_state, numeric(state.cloud_update_interval) || 129600);
  } finally {
    select.disabled = false;
  }
}

function setCloudPage(open) {
  document.getElementById("overviewView").hidden = open;
  document.getElementById("cloudView").hidden = !open;
  if (open) document.getElementById("cloudUrlInput").focus();
}

async function openCloudSettings() {
  try {
    const result = await bridgeExec(`cat /data/adb/str-adblocker/cloud-update-url 2>/dev/null`);
    if (Number(result.errno) !== 0 && result.stderr) throw new Error(result.stderr);
    document.getElementById("cloudUrlInput").value = String(result.stdout || "").trim();
    setText("cloudHint", "保存后立即生效，无需重启模块。");
    setCloudPage(true);
  } catch (error) {
    notify(`读取更新地址失败：${error.message || "未知错误"}`);
  }
}

async function saveCloudSettings() {
  const hint = document.getElementById("cloudHint");
  try {
    const raw = document.getElementById("cloudUrlInput").value.trim();
    if (raw && !/^https:\/\/[^\s]+$/.test(raw)) throw new Error("地址必须以 https:// 开头");
    if (raw.length > 2048) throw new Error("地址过长");
    const encoded = btoa(raw);
    const command = `printf '%s' '${encoded}' | base64 -d > /data/adb/str-adblocker/cloud-update-url.new && chmod 0600 /data/adb/str-adblocker/cloud-update-url.new && mv -f /data/adb/str-adblocker/cloud-update-url.new /data/adb/str-adblocker/cloud-update-url`;
    const result = await bridgeExec(command);
    if (Number(result.errno) !== 0) throw new Error(result.stderr || "保存失败");
    hint.textContent = raw ? "已保存，自动更新将使用该地址。" : "已清空，自动更新已停用。";
    notify(raw ? "更新地址已保存" : "自动更新已停用");
    setTimeout(() => { if (!document.hidden) refreshStatus(); }, 800);
  } catch (error) {
    hint.textContent = error.message || "保存失败";
    notify("更新地址未保存");
  }
}

async function requestCloudUpdate() {
  const button = nodes.cloudUpdateButton || document.getElementById("cloudUpdateButton");
  if (!button || button.disabled) return;
  if (bridge.mode === "none") {
    notify("控制桥接不可用：请通过 SAD 控制应用打开本页，或直接在模块页执行 action 更新");
    return;
  }
  if (state.cloud_update_enabled !== "true") {
    notify("未配置更新地址，请先编辑");
    openCloudSettings();
    return;
  }
  button.disabled = true;
  try {
    const result = await bridgeExec(`sh ${MODULE_DIR}/bin/update.sh request`);
    if (Number(result.errno) !== 0) {
      const detail = [result.stdout, result.stderr].filter(Boolean).join(" ").trim();
      throw new Error(detail ? `${detail} (errno=${result.errno})` : `request_failed (errno=${result.errno})`);
    }
    const verify = await bridgeExec(`cat /data/adb/str-adblocker/cloud-update.request 2>/dev/null`);
    if (String(verify.stdout || "").trim()) {
      notify("已请求云端更新");
    } else {
      throw new Error("请求未持久化，文件不存在");
    }
  } catch (error) {
    notify(`更新请求失败：${error.message || "未知错误"}`);
  } finally {
    button.disabled = false;
  }
  setTimeout(() => { if (!document.hidden) refreshStatus(); }, 1500);
}

async function refreshStatus(force = false) {
  // Status polling must not invoke the bridge or mutate the DOM while an editor owns focus.
  if (!force && isEditableFocused()) return false;
  if (refreshPromise) return refreshPromise;
  refreshPromise = (async () => {
    try {
      // 桥接暂时失效时每次轮询重试探测，恢复后立即回到实时数据；
      // probeBridge 自带并发守卫，不会堆叠请求。
      if (bridge.mode === "none") await probeBridge();
      if (bridge.mode !== "none") {
        const result = await bridgeExec(`sh ${MODULE_DIR}/bin/status.sh ${MODULE_DIR}`);
        if (Number(result.errno) !== 0) throw new Error(result.stderr || "status_command_failed");
        if (!force && isEditableFocused()) return false;
        state = parseLiveStatus(result.stdout);
        if (!force && isEditableFocused()) return false;
        hasLiveStatus = true;
        statusFailures = 0;
        renderStatus();
        return;
      }
      if (!force && isEditableFocused()) return false;
      // 桥接不可用时不渲染 preview 假数据，诚实显示状态不可用
      hasLiveStatus = false;
      renderUnavailable(new Error(bridge.reason || "bridge_unavailable"));
    } catch (error) {
      if (!force && isEditableFocused()) return false;
      statusFailures += 1;
      if (!hasLiveStatus || statusFailures >= 2) renderUnavailable(error);
      if (statusFailures === 1) notify("暂时无法读取模块状态");
    }
  })();
  try {
    return await refreshPromise;
  } finally {
    refreshPromise = null;
  }
}

cacheNodes();
document.getElementById("refreshButton").addEventListener("click", () => refreshStatus(true));
document.getElementById("ipBlacklistButton").addEventListener("click", openBlacklistEditor);
document.getElementById("domainBlacklistButton").addEventListener("click", openDomainBlacklistEditor);
document.getElementById("cloudUpdateButton").addEventListener("click", requestCloudUpdate);
document.getElementById("cloudIntervalSelect").addEventListener("change", setCloudInterval);
document.getElementById("cloudUrlButton").addEventListener("click", openCloudSettings);
document.getElementById("cloudBack").addEventListener("click", () => setCloudPage(false));
document.getElementById("cloudSave").addEventListener("click", saveCloudSettings);
document.getElementById("cloudUrlInput").placeholder = DEFAULT_CLOUD_URL;
document.getElementById("ipBlacklistBack").addEventListener("click", () => setBlacklistPage(false));
document.getElementById("ipBlacklistSave").addEventListener("click", saveBlacklist);
document.getElementById("ipBlacklistTest").addEventListener("click", testBlacklistPath);
document.getElementById("domainBlacklistBack").addEventListener("click", () => setDomainBlacklistPage(false));
document.getElementById("domainBlacklistSave").addEventListener("click", saveDomainBlacklist);
document.getElementById("domainAllowlistButton").addEventListener("click", openDomainAllowlistEditor);
document.getElementById("domainAllowlistBack").addEventListener("click", () => setDomainAllowlistPage(false));
document.getElementById("domainAllowlistSave").addEventListener("click", saveDomainAllowlist);
document.getElementById("pauseButton").addEventListener("click", togglePause);
document.getElementById("activityButton").addEventListener("click", () => setActivityPage(true));
document.getElementById("activityBack").addEventListener("click", () => setActivityPage(false));
document.getElementById("activityRefresh").addEventListener("click", loadActivity);
document.addEventListener("visibilitychange", () => { if (!document.hidden) refreshStatus(); });
renderStatus();
async function initBridgeAndStatus() {
  await probeBridge();
  await refreshStatus();
}
initBridgeAndStatus();
setInterval(() => { if (!document.hidden) refreshStatus(); }, 5000);
