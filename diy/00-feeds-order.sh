#!/usr/bin/env bash
#
# diy/00-feeds-order.sh — feeds 顺序（在 ./scripts/feeds update 之前执行）
#
# 作用: 把 suite feed 插到 feeds 配置的【最前面】。
#       OpenWrt 的 feeds install -a 对同名包按 feeds.conf 中的出现顺序取先到者，
#       官方 packages feed 里也有 nqptp / v2ray-geodata / ddns-go 等同名包，
#       suite 排在最前即可保证全部用本仓库的版本 —— 原 compile.sh 里
#       「卸载官方 nqptp 再 -p 强装」「删除官方 v2ray-geodata 源」两个特判
#       因此不再需要。
#
# 用法: bash diy/00-feeds-order.sh <openwrt 源码目录>
# 环境变量:
#   SUITE_REPO   本仓库地址（默认 NetForgeCN/openwrt-suite）
#   FEED_NAME    feed 名（默认 suite，勿与官方 packages/luci/routing/telephony 重名）
#

set -Eeuo pipefail
export LC_ALL=C LANG=C

OW="${1:-$PWD}"
SUITE_REPO="${SUITE_REPO:-https://github.com/NetForgeCN/openwrt-suite.git}"
FEED_NAME="${FEED_NAME:-suite}"

[[ -d "$OW" ]] || { echo "[00-feeds-order] 目录不存在：$OW" >&2; exit 1; }

# feeds.conf 存在则优先（OpenWrt 用它覆盖 feeds.conf.default）
conf="feeds.conf"
[[ -f "$OW/$conf" ]] || conf="feeds.conf.default"
file="$OW/$conf"
[[ -f "$file" ]] || { echo "[00-feeds-order] 找不到 $file" >&2; exit 1; }

# 幂等：先删除任何已存在的 suite 行（旧位置/重复行一并清掉）
tmp="$(mktemp)"
awk -v feed="$FEED_NAME" '
    $0 ~ ("^[[:space:]]*src-git[[:space:]]+" feed "[[:space:]]") { next }
    { print }
' "$file" > "$tmp"

# 插入为第一条 src-git（注释行沉到后面没关系，feeds 解析跳过注释）
printf 'src-git %s %s\n' "$FEED_NAME" "$SUITE_REPO" | cat - "$tmp" > "$file"
rm -f -- "$tmp"

# 校验：suite 必须是文件中第一条 src-git
first="$(grep -E '^[[:space:]]*src-git[[:space:]]' "$file" | head -n 1)"
grep -qE "^[[:space:]]*src-git[[:space:]]+${FEED_NAME}[[:space:]]" <<<"$first" ||
    { echo "[00-feeds-order] 插入后校验失败：$file" >&2; exit 1; }

echo "[00-feeds-order] $FEED_NAME 已置于 $conf 首位（同名包优先用本仓库版本）："
echo "    $first"
