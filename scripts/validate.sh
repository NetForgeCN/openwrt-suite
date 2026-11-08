#!/usr/bin/env bash
#
# openwrt-suite 结构校验（同步后自动执行，也可单独运行）
#
# 校验项:
#   1. packages/ 下每个目录都必须含 Makefile（feed 可被 OpenWrt 正确扫描）
#   2. 快照内不得残留 .git 目录
#   3. sources.lock 与 sources.conf 条目一一对应
#   4. config/dot.config 存在、非空、含有效 Kconfig 行
#

set -Eeuo pipefail
export LC_ALL=C LANG=C

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
err=0

log()  { printf '[校验] %s\n' "$*"; }
fail() { printf '[校验失败] %s\n' "$*" >&2; err=1; }

# 1. 每个包目录必须有 Makefile
if [[ -d "$ROOT/packages" ]]; then
    count=0
    for d in "$ROOT/packages"/*/; do
        [[ -d "$d" ]] || continue
        count=$((count + 1))
        if [[ ! -f "$d/Makefile" ]]; then
            fail "包目录缺少 Makefile：$d"
        fi
    done
    log "packages/ 下共 $count 个包目录"
    ((count > 0)) || fail "packages/ 为空"
else
    fail "缺少 packages/ 目录"
fi

# 2. 不得残留 .git（避免把上游仓库历史带进快照）
while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    fail "快照内残留 .git 目录：$g"
done < <(find "$ROOT/packages" -name .git -type d -print 2>/dev/null)

# 3. lock 与 conf 一一对应
if [[ -f "$ROOT/sources.conf" && -f "$ROOT/sources.lock" ]]; then
    conf_slugs="$(grep -Ev '^[[:space:]]*(#|$)' "$ROOT/sources.conf" | cut -d'|' -f1 | sort)"
    lock_slugs="$(cut -d'|' -f1 "$ROOT/sources.lock" | sort)"
    if [[ "$conf_slugs" != "$lock_slugs" ]]; then
        fail "sources.conf 与 sources.lock 的源列表不一致：
    conf:  $(echo "$conf_slugs"   | tr '\n' ' ')
    lock:  $(echo "$lock_slugs"   | tr '\n' ' ')"
    else
        log "sources.lock 覆盖全部 $(echo "$conf_slugs" | wc -l | tr -d ' ') 个源"
    fi
else
    fail "缺少 sources.conf 或 sources.lock"
fi

# 4. .config 快照有效
cfg="$ROOT/config/dot.config"
if [[ -s "$cfg" ]] && grep -qE '^(CONFIG_|# CONFIG_)' "$cfg"; then
    log "config/dot.config 有效（$(wc -l < "$cfg" | tr -d ' ') 行）"
else
    fail "config/dot.config 缺失或不含 Kconfig 配置项"
fi

# 5. 提示 sources.conf 里声明、但 packages/ 中缺失的目录（仅警告）
grep -Ev '^[[:space:]]*(#|$)' "$ROOT/sources.conf" 2>/dev/null |
while IFS='|' read -r slug url branch mode payload; do
    [[ "$mode" == "pkg" ]] || continue
    for p in $payload; do
        [[ -d "$ROOT/packages/$p" ]] ||
            printf '[校验警告] sources.conf 声明了 %s 但 packages/ 中无此目录\n' "$p" >&2
    done
done

if ((err == 1)); then
    exit 1
fi
log "校验全部通过"
