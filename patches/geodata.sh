#!/usr/bin/env bash
#
# v2ray-geodata 同步后补丁（由 scripts/sync.sh 自动挂钩执行，参数为包目录）
#
# 背景: 上游 sbwml/v2ray-geodata 的 GEOIP_URL 默认指向 CN 精简版
#       geoip-only-cn-private.dat；NetForgeCN/Loyalsoldier fork 中改用了
#       全量 geoip.dat。改从源头同步后，用本补丁保留这一定制。
#
# 注意: 补丁必须自带校验、失败即退出非 0 —— 上游重构导致行结构变化时，
#       同步 CI 会立刻报红，而不是静默产出错误配置。
#

set -Eeuo pipefail
export LC_ALL=C LANG=C

dir="${1:-}"
[[ -n "$dir" && -f "$dir/Makefile" ]] || { echo "[geodata-patch] 缺少 Makefile：$dir" >&2; exit 1; }
mk="$dir/Makefile"

GEOIP_URL_TARGET='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'

# 已是目标值则跳过（幂等）
if grep -qF "GEOIP_URL:=$GEOIP_URL_TARGET" "$mk"; then
    echo "[geodata-patch] GEOIP_URL 已是全量 geoip.dat，无需修改"
    exit 0
fi

# 必须存在 GEOIP_URL 赋值行才可重写；找不到说明上游结构已变，必须人工介入
if ! grep -qE '^[[:space:]]*GEOIP_URL[[:space:]]*:=' "$mk"; then
    echo "[geodata-patch] 上游 Makefile 中已找不到 GEOIP_URL 赋值行，" \
         "上游可能已重构，请人工检查后更新本补丁：$mk" >&2
    exit 1
fi

# 原地重写（BSD/GNU 通用：不经 sed -i，保留原 inode 与权限）
tmp="$(mktemp)"
awk -v url="GEOIP_URL:=$GEOIP_URL_TARGET" '
    !done && $0 ~ /^[[:space:]]*GEOIP_URL[[:space:]]*:=/ { print url; done=1; next }
    { print }
' "$mk" > "$tmp"
cat -- "$tmp" > "$mk"
rm -f -- "$tmp"

# 结果校验
grep -qF "GEOIP_URL:=$GEOIP_URL_TARGET" "$mk" ||
    { echo "[geodata-patch] 重写后校验失败" >&2; exit 1; }

echo "[geodata-patch] GEOIP_URL 已重写为全量 geoip.dat：$mk"
