#!/system/bin/sh

MODULE_VERSION=$(awk -F= '$1 == "version" { print $2; exit }' "$MODPATH/module.prop" 2>/dev/null)
case "$MODULE_VERSION" in ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*) abort "! Module version is missing or invalid" ;; esac
PERSIST=${STR_STATE_DIR:-/data/adb/str-adblocker}
export STR_STATE_DIR="$PERSIST"
ui_print "- 正在安装 SAD ${MODULE_VERSION}"

if [ "${KSU:-}" != "true" ] && [ -z "${MAGISK_VER_CODE:-}" ]; then
  abort "! 需要 KernelSU 或 Magisk"
fi

if [ "${BOOTMODE:-}" != "true" ]; then
  abort "! 请通过 KernelSU/Magisk 管理器安装，不要使用 Recovery"
fi

if [ "${ARCH:-}" != "arm64" ]; then
  abort "! 需要 arm64 架构（当前：${ARCH:-未知}）"
fi

if [ "${API:-0}" -lt 33 ]; then
  abort "! 需要 Android 13 及以上（当前 API ${API:-未知}）"
fi

KERNEL_RELEASE=$(uname -r 2>/dev/null)
KERNEL_MAJOR=${KERNEL_RELEASE%%.*}
KERNEL_REST=${KERNEL_RELEASE#*.}
KERNEL_MINOR=${KERNEL_REST%%.*}
case "$KERNEL_MAJOR:$KERNEL_MINOR" in
  *[!0-9:]*|:*|*:) abort "! 无法识别内核版本（$KERNEL_RELEASE）" ;;
esac
if [ "$KERNEL_MAJOR" -lt 5 ] || { [ "$KERNEL_MAJOR" -eq 5 ] && [ "$KERNEL_MINOR" -lt 10 ]; }; then
  abort "! 需要 Linux 5.10 及以上内核（$KERNEL_RELEASE）"
fi

RULES=$(awk -F= '$1 == "rules" { print $2; exit }' "$MODPATH/rules/manifest")
case "$RULES" in ''|*[!0-9]*) abort "! 内置规则清单无效" ;; esac
if [ "$RULES" -lt 10000 ] || [ ! -s "$MODPATH/rules/rules.bin" ]; then
  abort "! 内置规则缺失或无效（$RULES 条）"
fi
EXPECTED_SHA=$(awk -F= '$1 == "sha256" { print $2; exit }' "$MODPATH/rules/manifest")
ACTUAL_SHA=$(sha256sum "$MODPATH/rules/rules.bin" 2>/dev/null | awk '{ print $1 }')
if [ -z "$EXPECTED_SHA" ] || [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  abort "! 内置规则与清单不一致"
fi

HOTSET_COUNT=$(awk -F= '$1 == "hotset" { print $2; exit }' "$MODPATH/rules/hotset.manifest" 2>/dev/null)
HOTSET_EXPECTED_SHA=$(awk -F= '$1 == "sha256" { print $2; exit }' "$MODPATH/rules/hotset.manifest" 2>/dev/null)
HOTSET_ACTUAL_SHA=$(sha256sum "$MODPATH/rules/hotset.hosts" 2>/dev/null | awk '{ print $1 }')
HOTSET_MODULE_SHA=$(sha256sum "$MODPATH/system/etc/hosts" 2>/dev/null | awk '{ print $1 }')
case "$HOTSET_COUNT" in ''|*[!0-9]*) abort "! 内置 Hosts 清单无效" ;; esac
if [ "$HOTSET_COUNT" -lt 1000 ] || [ "$HOTSET_COUNT" -gt 30000 ] || [ ! -s "$MODPATH/rules/hotset.hosts" ]; then
  abort "! 内置 Hosts 缺失或无效（$HOTSET_COUNT 条）"
fi
if [ -z "$HOTSET_EXPECTED_SHA" ] || [ "$HOTSET_ACTUAL_SHA" != "$HOTSET_EXPECTED_SHA" ] || [ "$HOTSET_MODULE_SHA" != "$HOTSET_EXPECTED_SHA" ]; then
  abort "! 内置 Hosts 与清单不一致"
fi

if [ ! -s "$MODPATH/bin/strd" ]; then
  abort "! 缺少守护进程"
fi
chmod 0755 "$MODPATH/bin/strd" || abort "! 守护进程无法赋予执行权限"
DAEMON_VERSION=$("$MODPATH/bin/strd" -version 2>&1)
if [ "$DAEMON_VERSION" != "$MODULE_VERSION" ]; then
  abort "! 守护进程版本不匹配（模块=$MODULE_VERSION 守护进程=${DAEMON_VERSION:-不可用}）"
fi
VALIDATE_DIR=${STR_INSTALL_TMP_DIR:-$MODPATH/.install-validate-$$}
case "$VALIDATE_DIR" in ''|/|/data|/data/local|/data/local/tmp) abort "! 校验目录不安全" ;; esac
[ ! -e "$VALIDATE_DIR" ] || abort "! 校验目录已存在"
mkdir "$VALIDATE_DIR" || abort "! 无法创建校验目录"
chmod 0700 "$VALIDATE_DIR"
VALIDATE_ALLOWLIST="$VALIDATE_DIR/allowlist.txt"
if [ -f "$PERSIST/allowlist.txt" ]; then
  VALIDATE_ALLOWLIST="$PERSIST/allowlist.txt"
else
  : > "$VALIDATE_ALLOWLIST"
fi
VALIDATE_DOMAIN_BLACKLIST="$VALIDATE_DIR/domain-blacklist.txt"
if [ -f "$PERSIST/domain-blacklist.txt" ]; then
  VALIDATE_DOMAIN_BLACKLIST="$PERSIST/domain-blacklist.txt"
else
  : > "$VALIDATE_DOMAIN_BLACKLIST"
fi
if VALIDATE_RESULT=$("$MODPATH/bin/strd" \
  -validate-rules \
  -rules "$MODPATH/rules/rules.bin" \
  -manifest "$MODPATH/rules/manifest" \
  -allowlist "$VALIDATE_ALLOWLIST" \
  -default-allowlist "$MODPATH/config/default-allowlist.txt" \
  -domain-blacklist "$VALIDATE_DOMAIN_BLACKLIST" \
  -endpoints "$MODPATH/rules/endpoints.txt" \
  -state "$VALIDATE_DIR/state.json" 2>&1); then
  VALIDATE_STATUS=0
else
  VALIDATE_STATUS=$?
fi
rm -f "$VALIDATE_DIR/policy.seed" "$VALIDATE_DIR/state.json" "$VALIDATE_DIR/allowlist.txt" "$VALIDATE_DIR/domain-blacklist.txt"
rmdir "$VALIDATE_DIR" 2>/dev/null || true
if [ "$VALIDATE_STATUS" -ne 0 ]; then
  abort "! 策略校验失败：${VALIDATE_RESULT:-未知错误}"
fi
ui_print "- 守护进程与策略校验通过"

mkdir -p "$PERSIST"

if [ ! -f "$PERSIST/allowlist.txt" ]; then
  : > "$PERSIST/allowlist.txt"
fi
if [ ! -f "$PERSIST/domain-blacklist.txt" ]; then
  : > "$PERSIST/domain-blacklist.txt"
fi
if [ ! -f "$PERSIST/ip-blacklist.txt" ]; then
  : > "$PERSIST/ip-blacklist.txt"
fi
if [ ! -f "$PERSIST/cloud-update-url" ]; then
  printf '%s\n' 'https://github.com/310DSD/STR-ADBlocker-rules/releases/latest/download/generation.tar.gz' > "$PERSIST/cloud-update-url"
fi
if [ ! -f "$PERSIST/cloud-update-interval" ]; then
  printf '129600\n' > "$PERSIST/cloud-update-interval"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/bin/backend.sh" 0 0 0755
set_perm "$MODPATH/bin/lifecycle.sh" 0 0 0644
set_perm "$MODPATH/bin/owned_lock.sh" 0 0 0644
set_perm "$MODPATH/bin/strd" 0 0 0755
set_perm "$MODPATH/bin/fetch" 0 0 0755
set_perm "$MODPATH/bin/update.sh" 0 0 0755
set_perm "$MODPATH/bin/status.sh" 0 0 0755
set_perm "$MODPATH/bin/mode.sh" 0 0 0755
set_perm "$MODPATH/bin/restart.sh" 0 0 0755
set_perm "$MODPATH/system/etc/hosts" 0 0 0644
set_perm_recursive "$PERSIST" 0 0 0700 0600

ui_print "- 已安装 $RULES 条拦截域名"
ui_print "- 已安装 $HOTSET_COUNT 条 Hosts 记录"
ui_print "- 重启后自动进入防护模式"
ui_print "- 安装完成，重启后生效"
