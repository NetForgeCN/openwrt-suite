#!/usr/bin/env bash
#
# patches/geodata.sh — v2ray-geodata 供应链加固补丁（由 scripts/sync.sh 自动调用）
#
# 上游 Makefile 原本从 releases/latest 下载 geoip.dat / geosite.dat，并从同一
# origin 现取 .sha256sum：latest 若指向备份/无资产 release 就会 404，且校验值
# 与数据同源，无法防止 origin 被篡改。本补丁把数据和哈希一起钉在 Makefile 里。
# 更新规则数据时必须同时改 tag 与两个 SHA256，并同步 packages/ 里已同步的快照。

set -euo pipefail
# 避免 bash 3.2 在 UTF-8 下把全角标点拼进变量名（$VAR（中文）→ unbound variable）
export LC_ALL=C LANG=C

dest="${1:?用法: patches/geodata.sh <包目录>}"
[[ -d "$dest" && ! -L "$dest" ]] || { echo "[geodata] 目标不是目录或为符号链接：$dest" >&2; exit 1; }
mf="$dest/Makefile"
[[ -f "$mf" && ! -L "$mf" ]] || { echo "[geodata] 缺少 Makefile：$mf" >&2; exit 1; }
grep -qxF 'PKG_NAME:=v2ray-geodata' "$mf" || { echo "[geodata] 不是 v2ray-geodata 包：$mf" >&2; exit 1; }

tag=202611250113
geoip_sha=d4ec4c5e5d5a38c1399964ea9fd8c94288426a3b31b483904b67819fc07f4466
geosite_sha=67ccb3cda9fb1b118be77d4aeb954d16fe3a12c63a6006e72709ad12dee7aab2

# 幂等：已打过补丁时只复核哈希，不重复改写
if grep -qxF "GEODATA_TAG:=$tag" "$mf"; then
    if ! grep -qxF "GEOIP_SHA256:=$geoip_sha" "$mf" ||
       ! grep -qxF "GEOSITE_SHA256:=$geosite_sha" "$mf"; then
        echo "[geodata] 已钉住 release 但 SHA256 不匹配，请人工核对" >&2
        exit 1
    fi
    exit 0
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/suite-geodata.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT

awk -v tag="$tag" -v ip="$geoip_sha" -v site="$geosite_sha" '
    /^PKG_VERSION[[:space:]]*:=/ {
        print "PKG_VERSION:=$(shell if [ -n \"$$SOURCE_DATE_EPOCH\" ]; then date -u -d \"@$$SOURCE_DATE_EPOCH\" +%Y.%m.%d; else date -u +%Y.%m.%d; fi)"
        print "# 版本跟随可复现构建时间戳；规则数据由下方固定 tag + SHA256 决定"
        next
    }
    /^GEOIP_URL[[:space:]]*:=/ {
        if (!injected) {
            print "# 不用 latest：latest 可能指向只含备份资产的 release导致 404；哈希也不再从同源现取"
            print "GEODATA_TAG:=" tag
            print "GEOIP_SHA256:=" ip
            print "GEOSITE_SHA256:=" site
            print "GEOIP_URL:=https://github.com/NetForgeCN/v2ray-rules-dat/releases/download/" tag "/geoip.dat"
            print "GEOSITE_URL:=https://github.com/NetForgeCN/v2ray-rules-dat/releases/download/" tag "/geosite.dat"
            injected=1
        }
        next
    }
    /^GEOSITE_URL[[:space:]]*:=/ { next }
    /^define Build\/Compile$/ {
        in_compile=1
        print "define Build/Compile"
        print "\t( \\"
        print "\t\tset -e ; \\"
        print "\t\tcd $(PKG_BUILD_DIR) ; \\"
        print "\t\tcurl --proto =https --proto-redir =https --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 --max-time 300 $(GEOIP_URL) -o geoip.dat ; \\"
        print "\t\tcurl --proto =https --proto-redir =https --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 --max-time 300 $(GEOSITE_URL) -o geosite.dat ; \\"
        print "\t\tprintf \"%s  %s\\n\" \"$(GEOIP_SHA256)\" geoip.dat | sha256sum -c - ; \\"
        print "\t\tprintf \"%s  %s\\n\" \"$(GEOSITE_SHA256)\" geosite.dat | sha256sum -c - ; \\"
        print "\t)"
        next
    }
    in_compile && /^endef$/ { in_compile=0; print "endef"; next }
    in_compile { next }
    { print }
' "$mf" > "$tmp"

# 结构校验：任何一项缺失都说明上游改版了补丁不再适用，必须人工介入
grep -qxF "GEODATA_TAG:=$tag" "$tmp" ||
    { echo "[geodata] 找不到 GEOIP_URL，上游结构可能已变" >&2; exit 1; }
grep -qxF "GEOIP_SHA256:=$geoip_sha" "$tmp" ||
    { echo "[geodata] 注入 GEOIP_SHA256 失败" >&2; exit 1; }
grep -qxF "GEOSITE_SHA256:=$geosite_sha" "$tmp" ||
    { echo "[geodata] 注入 GEOSITE_SHA256 失败" >&2; exit 1; }
grep -qxF 'define Build/Compile' "$tmp" ||
    { echo "[geodata] 注入 Build/Compile 失败" >&2; exit 1; }
! grep -q 'releases/latest' "$tmp" ||
    { echo "[geodata] 仍存在 releases/latest 引用" >&2; exit 1; }

cat -- "$tmp" > "$mf"
echo "[geodata] 已钉住 release ${tag}（geoip/geosite SHA256 一并固定）"
