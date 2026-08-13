#!/system/bin/sh

MODDIR=${0%/*}
STATE=/data/adb/str-adblocker
CLOUD_URL=$(cat "$STATE/cloud-update-url" 2>/dev/null)
case "$CLOUD_URL" in
  https://*) ;;
  *)
    echo "SAD: cloud update URL is not configured; set it in the module WebUI first"
    exit 7
    ;;
esac
exec "$MODDIR/bin/update.sh" cloud "$CLOUD_URL"
