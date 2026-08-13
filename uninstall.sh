#!/system/bin/sh

MODDIR=${0%/*}
: > /data/adb/str-adblocker/pause 2>/dev/null || true
sh "$MODDIR/bin/backend.sh" "$MODDIR" cleanup 2>/dev/null || true
if grep -q " /system/etc/hosts " /proc/self/mountinfo 2>/dev/null; then
  umount /system/etc/hosts 2>/dev/null || umount -l /system/etc/hosts 2>/dev/null || true
fi
pkill -f "$MODDIR/bin/update.sh" 2>/dev/null || true
rm -rf /data/adb/str-adblocker
rm -rf /dev/str-adblocker
