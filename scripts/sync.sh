#!/usr/bin/env bash
#
# openwrt-suite 同步脚本（本地 / GitHub Actions CI 共用）
#
# 按 sources.conf 的映射表，把各上游仓库以「纯快照」方式拷入本仓库：
#   - 每个源先 rm 掉旧目录再全量拷贝，不产生陈旧残留，不保留上游 .git
#   - 每个包目录必须含 Makefile，否则同步失败（CI 报红，绝不静默产出坏快照）
#   - patches/<slug>.sh 存在时同步后自动执行（重打本地定制补丁）
#   - 上游 commit 号记录进 sources.lock，实现版本可追溯 / 可复现
#
# 用法: bash scripts/sync.sh          （在仓库根目录或任意位置执行均可）
# 环境变量:
#   SUITE_SYNC_ONLY="slug ..."  只同步指定的 slug（调试用，逗号或空格分隔）
#

set -Eeuo pipefail
export LC_ALL=C LANG=C

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CONF="$ROOT/sources.conf"
LOCK="$ROOT/sources.lock"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/suite-sync.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
ONLY="${SUITE_SYNC_ONLY:-}"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

command -v git  >/dev/null 2>&1 || die "缺少 git"
command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v tar  >/dev/null 2>&1 || die "缺少 tar"
[[ -f "$CONF" ]] || die "找不到映射表：$CONF"

mkdir -p "$ROOT/packages" "$ROOT/meta"

# 把上游仓库根目录的许可证类文件收集到 meta/<slug>/（许可证随快照保留）
copy_meta() {
    local src="$1" slug="$2" f
    mkdir -p "$ROOT/meta/$slug"
    for f in "$src"/LICENSE "$src"/LICENSE.* "$src"/COPYING* \
             "$src"/THIRD-PARTY-NOTICES* "$src"/NOTICE*; do
        [[ -f "$f" ]] || continue
        cp -f -- "$f" "$ROOT/meta/$slug/" 2>/dev/null || true
    done
    # meta 目录为空则删除，避免仓库里堆积空目录
    rmdir "$ROOT/meta/$slug" 2>/dev/null || true
}

# 拷贝目录树（可移植：不依赖 rsync / GNU cp；排除 .git）
copy_tree() {
    local src="$1" dst="$2"
    rm -rf -- "$dst"
    mkdir -p -- "$dst"
    tar -C "$src" --exclude='./.git' -cf - . | tar -C "$dst" -xf -
}

# 记录 lock 行（上游 commit 未变化时沿用旧记录，避免纯时间戳差异产生提交噪音）
lock_add() {
    local slug="$1" sha="$2" url="$3" old_line
    old_line="$(grep -E "^${slug}\|" "$LOCK" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$old_line" && "$old_line" == "${slug}|${sha}|"* ]]; then
        printf '%s\n' "$old_line" >> "$LOCK.new"
    else
        printf '%s|%s|%s|%s\n' "$slug" "$sha" "$NOW" "$url" >> "$LOCK.new"
    fi
}

FAILED=0
: > "$LOCK.new"

# ---------------------------------------------------------------- 逐源同步
while IFS='|' read -r slug url branch mode payload; do
    # 跳过注释与空行
    case "$slug" in ''|\#*) continue ;; esac
    [[ -n "$url" && -n "$branch" && -n "$mode" ]] ||
        { warn "映射表条目字段不全，跳过：$slug"; FAILED=1; continue; }

    # 调试模式：只同步指定 slug（未选中的源沿用旧 lock 行，保证 lock 与 conf 仍然对齐）
    if [[ -n "$ONLY" && ",${ONLY// /,}," != *",$slug,"* ]]; then
        log "跳过（SUITE_SYNC_ONLY 未包含）：$slug"
        old_line="$(grep -E "^${slug}\|" "$LOCK" 2>/dev/null | head -n 1 || true)"
        [[ -n "$old_line" ]] && printf '%s\n' "$old_line" >> "$LOCK.new"
        continue
    fi

    log "同步 $slug <- $url（分支 $branch，模式 $mode）"

    # 记录并校验上游分支头（源头删库/改分支时立刻发现）
    sha="$(git ls-remote "$url" "refs/heads/$branch" | awk '{print $1}' | head -n 1 || true)"
    if [[ -z "$sha" ]]; then
        warn "上游 $url 不存在分支 $branch（删库？改默认分支？），保留本仓库现有快照"
        FAILED=1
        continue
    fi

    case "$mode" in
    pkg)
        git clone -q --depth 1 -b "$branch" "$url" "$TMP/$slug" ||
            { warn "克隆失败：$slug"; FAILED=1; continue; }
        copy_meta "$TMP/$slug" "$slug"

        local_ok=1
        for p in $payload; do
            [[ -d "$TMP/$slug/$p" ]] ||
                { warn "$slug：上游不存在映射目录 $p（上游已重构？请更新 sources.conf 映射）"; local_ok=0; break; }
            copy_tree "$TMP/$slug/$p" "$ROOT/packages/$p"
            [[ -f "$ROOT/packages/$p/Makefile" ]] ||
                { warn "$p 拷贝后缺少 Makefile（同步结果无效）"; local_ok=0; break; }
        done
        ((local_ok == 1)) || { FAILED=1; continue; }
        lock_add "$slug" "$sha" "$url"
        rm -rf -- "$TMP/$slug"
        ;;

    all)
        dest="$ROOT/packages/$payload"
        git clone -q --depth 1 -b "$branch" "$url" "$TMP/$slug" ||
            { warn "克隆失败：$slug"; FAILED=1; continue; }

        copy_tree "$TMP/$slug" "$dest"
        [[ -f "$dest/Makefile" ]] ||
            { warn "$payload 拷贝后缺少 Makefile（同步结果无效）"; FAILED=1; continue; }

        # 补丁挂钩（本地定制重打）
        if [[ -x "$ROOT/patches/$slug.sh" || -f "$ROOT/patches/$slug.sh" ]]; then
            log "应用补丁：patches/$slug.sh -> $payload"
            bash "$ROOT/patches/$slug.sh" "$dest" ||
                { warn "补丁 $slug.sh 应用失败（上游可能已重构，请检查补丁脚本）"; FAILED=1; continue; }
        fi

        lock_add "$slug" "$sha" "$url"
        rm -rf -- "$TMP/$slug"
        ;;

    file)
        src_path="${payload%% *}"
        dst_path="${payload#* }"
        [[ -n "$src_path" && -n "$dst_path" && "$src_path" != "$dst_path" ]] ||
            { warn "$slug：mode=file 的 payload 应为『源路径 目标路径』"; FAILED=1; continue; }

        raw_url="${url%.git}"
        raw_url="${raw_url#https://github.com/}/$branch/$src_path"
        raw_url="https://raw.githubusercontent.com/$raw_url"

        mkdir -p -- "$(dirname "$ROOT/$dst_path")"
        if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "$raw_url" -o "$ROOT/$dst_path"; then
            warn "下载失败：$raw_url，保留现有文件"
            FAILED=1
            continue
        fi
        [[ -s "$ROOT/$dst_path" ]] ||
            { warn "下载结果为空：$dst_path"; FAILED=1; continue; }

        lock_add "$slug" "$sha" "$url"
        ;;

    *)
        warn "$slug：未知模式 $mode（支持 pkg / all / file）"
        FAILED=1
        ;;
    esac
done < "$CONF"

# ---------------------------------------------------------------- 汇总
if ((FAILED == 1)); then
    rm -f -- "$LOCK.new"
    die "同步过程中有源失败（见上方警告）。本次未更新 sources.lock，请修复后重试"
fi

sort -t'|' -k1,1 "$LOCK.new" > "$LOCK"
rm -f -- "$LOCK.new"
log "sources.lock 已更新（$(wc -l < "$LOCK" | tr -d ' ') 个源）"

bash "$ROOT/scripts/validate.sh" || die "结构校验未通过"

# 在 git 仓库里时，给出变更摘要（提交动作由调用方决定）
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    log "本次同步引起的变更："
    git -C "$ROOT" status --porcelain | sed 's/^/    /' || true
fi

log "同步完成"
