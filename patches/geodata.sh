#!/usr/bin/env bash
#
# patches/geodata.sh — v2ray-geodata 供应链加固补丁（由 scripts/sync.sh 自动调用）
#
# 上游 Makefile 原本从 releases/latest 下载 geoip.dat / geosite.dat，并从同一
# origin 现取 .sha256sum：latest 若指向备份/无资产 release 就会 404，且校验值
# 与数据同源，无法防止 origin 被篡改。本补丁从仓库根 geodata.pin 读取 tag 与
# 两个 SHA256（唯一真源）并注入 Makefile；已打补丁的 Makefile 会被刷新到 pin
# 的当前值，因此升级规则数据只需更新 geodata.pin，不需要手动改多处。

set -Eeuo pipefail
# 避免 bash 3.2 在 UTF-8 下把全角标点拼进变量名（$VAR（中文）→ unbound variable）
export LC_ALL=C LANG=C

die() { printf '[geodata] %s\n' "$*" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root_dir="$(cd "$script_dir/.." && pwd -P)"
pin="$root_dir/geodata.pin"
[[ -f "$pin" ]] || die "找不到规则数据唯一真源：$pin"

dest="${1:?用法: patches/geodata.sh <包目录>}"
[[ -d "$dest" && ! -L "$dest" ]] || die "目标不是目录或为符号链接：$dest"
mf="$dest/Makefile"
[[ -f "$mf" && ! -L "$mf" ]] || die "缺少 Makefile：$mf"
grep -qxF 'PKG_NAME:=v2ray-geodata' "$mf" || die "不是 v2ray-geodata 包：$mf"

# 严格解析 pin：三项恰好各一次，tag URL 安全，hash 必须是 64 位小写 hex。
# 任何异常都在改动 Makefile 之前失败（fail closed，保留旧值）。
tag=""
geoip_sha=""
geosite_sha=""
seen_tag=0
seen_ip=0
seen_site=0
while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="${key%$'\r'}"
    value="${value%$'\r'}"
    case "$key" in
        ''|'#'*) continue ;;
        TAG)
            ((seen_tag == 0)) || die "geodata.pin 中 TAG 重复"
            tag="$value"; seen_tag=1 ;;
        GEOIP_SHA256)
            ((seen_ip == 0)) || die "geodata.pin 中 GEOIP_SHA256 重复"
            geoip_sha="$value"; seen_ip=1 ;;
        GEOSITE_SHA256)
            ((seen_site == 0)) || die "geodata.pin 中 GEOSITE_SHA256 重复"
            geosite_sha="$value"; seen_site=1 ;;
        *) die "geodata.pin 含未知配置项：$key" ;;
    esac
done < "$pin"

((seen_tag == 1 && seen_ip == 1 && seen_site == 1)) ||
    die "geodata.pin 必须恰好包含 TAG / GEOIP_SHA256 / GEOSITE_SHA256 各一项"
[[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$tag" != *..* ]] ||
    die "geodata.pin 的 TAG 不是安全的 release tag：$tag"
[[ "$geoip_sha" =~ ^[0-9a-f]{64}$ ]] ||
    die "geodata.pin 的 GEOIP_SHA256 不是 64 位小写 hex：$geoip_sha"
[[ "$geosite_sha" =~ ^[0-9a-f]{64}$ ]] ||
    die "geodata.pin 的 GEOSITE_SHA256 不是 64 位小写 hex：$geosite_sha"

base="https://github.com/NetForgeCN/v2ray-rules-dat/releases/download/$tag"

check_result() {
    local file="$1" key n
    for key in GEODATA_TAG GEOIP_SHA256 GEOSITE_SHA256 GEOIP_URL GEOSITE_URL; do
        n="$(grep -c "^${key}[[:space:]]*:=" "$file" || true)"
        [[ "$n" == 1 ]] || die "$key 在 Makefile 中出现 $n 次（应为 1 次）"
    done
    grep -qxF "GEODATA_TAG:=$tag" "$file" || die "注入 GEODATA_TAG 失败"
    grep -qxF "GEOIP_SHA256:=$geoip_sha" "$file" || die "注入 GEOIP_SHA256 失败"
    grep -qxF "GEOSITE_SHA256:=$geosite_sha" "$file" || die "注入 GEOSITE_SHA256 失败"
    grep -qxF "GEOIP_URL:=$base/geoip.dat" "$file" || die "注入 GEOIP_URL 失败"
    grep -qxF "GEOSITE_URL:=$base/geosite.dat" "$file" || die "注入 GEOSITE_URL 失败"
    n="$(grep -c '^define Build/Compile$' "$file" || true)"
    [[ "$n" == 1 ]] || die "Build/Compile 块出现 $n 次（应为 1 次）"
    grep -q 'sha256sum -c -' "$file" || die "Build/Compile 未校验 SHA256"
    ! grep -q 'releases/latest' "$file" || die "仍存在 releases/latest 引用"
}

tmp="$(mktemp "${TMPDIR:-/tmp}/suite-geodata.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT

if grep -qE '^GEODATA_TAG[[:space:]]*:=' "$mf"; then
    # 幂等刷新：已打补丁的 Makefile 只替换 pin 相关行，值相同时内容不变。
    awk -v tag="$tag" -v ip="$geoip_sha" -v site="$geosite_sha" -v base="$base" '
        /^GEODATA_TAG[[:space:]]*:=/ { if (!t++) print "GEODATA_TAG:=" tag; next }
        /^GEOIP_SHA256[[:space:]]*:=/ { if (!i++) print "GEOIP_SHA256:=" ip; next }
        /^GEOSITE_SHA256[[:space:]]*:=/ { if (!s++) print "GEOSITE_SHA256:=" site; next }
        /^GEOIP_URL[[:space:]]*:=/ { if (!u++) print "GEOIP_URL:=" base "/geoip.dat"; next }
        /^GEOSITE_URL[[:space:]]*:=/ { if (!v++) print "GEOSITE_URL:=" base "/geosite.dat"; next }
        { print }
    ' "$mf" > "$tmp"
else
    # 首次打补丁：上游结构变化（找不到 GEODATA_TAG/GEOIP_URL/Build/Compile）时
    # check_result 会失败，绝不发布半成品。
    awk -v tag="$tag" -v ip="$geoip_sha" -v site="$geosite_sha" -v base="$base" '
        /^PKG_VERSION[[:space:]]*:=/ {
            print "PKG_VERSION:=$(shell if [ -n \"$$SOURCE_DATE_EPOCH\" ]; then date -u -d \"@$$SOURCE_DATE_EPOCH\" +%Y.%m.%d; else date -u +%Y.%m.%d; fi)"
            print "# 版本跟随可复现构建时间戳；规则数据由仓库根 geodata.pin 注入（勿手改）"
            next
        }
        /^# 版本跟随可复现构建时间戳/ { next }
        /^GEOIP_URL[[:space:]]*:=/ {
            if (!injected) {
                print "# 不用 latest：latest 可能指向只含备份资产的 release导致 404；哈希也不再从同源现取"
                print "# 以下五项由 patches/geodata.sh 从仓库根 geodata.pin 注入，请勿在此手动修改"
                print "GEODATA_TAG:=" tag
                print "GEOIP_SHA256:=" ip
                print "GEOSITE_SHA256:=" site
                print "GEOIP_URL:=" base "/geoip.dat"
                print "GEOSITE_URL:=" base "/geosite.dat"
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
fi

check_result "$tmp"

if cmp -s -- "$tmp" "$mf"; then
    echo "[geodata] Makefile 已与 geodata.pin 一致（$tag），无需改动"
    exit 0
fi

cat -- "$tmp" > "$mf"
echo "[geodata] 已从 geodata.pin 注入 release $tag（geoip/geosite SHA256 一并固定）"
