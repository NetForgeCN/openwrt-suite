#!/usr/bin/env bash
#
# openwrt-suite 同步脚本（本地 / GitHub Actions CI 共用）
#
# 信任模型（审计加固后）:
#   - sources.conf 只声明 URL / 分支 / 模式 / 路径映射；分支名不是信任锚。
#   - sources.lock 中的 40 位 commit SHA 才是唯一信任锚。默认同步只取 lock 中的
#     固定 commit；要跟进上游分支头，必须显式 SUITE_SYNC_UPDATE=1（或逐源指定）。
#   - 所有网络访问强制 HTTPS、无凭据、带超时与重试；git 按 SHA 抓取，不跟子模块、
#     不打 tag；mode=file 用 commit SHA 拼 raw.githubusercontent.com 内容寻址 URL。
#   - 所有输出先写入仓库内的 staging 目录，校验通过后才整体替换 packages/、meta/
#     和 config/dot.config、sources.lock；失败时回滚到上一版，绝不发布半个快照。
#
# 用法: bash scripts/sync.sh
# 环境变量:
#   SUITE_SYNC_ONLY="slug ..."   只同步指定 slug（逗号或空格分隔），其余沿用旧快照
#   SUITE_SYNC_UPDATE=1          显式把 lock 中的 pin 更新为当前上游分支头
#   SUITE_ROOT                   传给 scripts/validate.sh 的 staging 根目录（内部使用）
#

set -Eeuo pipefail
export LC_ALL=C LANG=C
export GIT_TERMINAL_PROMPT=0
export GIT_HTTP_LOW_SPEED_LIMIT=1024
export GIT_HTTP_LOW_SPEED_TIME=30
# 让任何在同步过程中产生的归档都带固定时间戳；不依赖宿主机的 TZ。
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-315532800}"
export GZIP="${GZIP:--n}"

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CONF="$ROOT/sources.conf"
LOCK="$ROOT/sources.lock"
TMP="$(mktemp -d "$ROOT/.sync-tmp.XXXXXX")"
STAGE="$TMP/stage"
BACKUP="$TMP/backup"
PUBLISHED=0

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

cleanup() {
    if ((PUBLISHED == 1)); then
        # publish 已开始但后续校验失败：尽力回滚到上一版
        rollback || warn "自动回滚失败，请从 git 历史恢复 packages/ 与 sources.lock"
    fi
    rm -rf -- "$TMP"
}
trap cleanup EXIT

rollback() {
    local rc=0
    if [[ -d "$BACKUP/packages" ]]; then
        [[ ! -L "$ROOT/packages" ]] || { warn "packages 是符号链接，拒绝自动回滚"; return 1; }
        rm -rf -- "$ROOT/packages" || rc=1
        mv -- "$BACKUP/packages" "$ROOT/packages" || rc=1
    fi
    if [[ -d "$BACKUP/meta" ]]; then
        [[ ! -L "$ROOT/meta" ]] || { warn "meta 是符号链接，拒绝自动回滚"; return 1; }
        rm -rf -- "$ROOT/meta" || rc=1
        mv -- "$BACKUP/meta" "$ROOT/meta" || rc=1
    fi
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        if [[ -f "$BACKUP/$rel" ]]; then
            mv -f -- "$BACKUP/$rel" "$ROOT/$rel" || rc=1
        else
            rm -f -- "$ROOT/$rel" || rc=1
        fi
    done < "$TMP/file_dsts" 2>/dev/null || true
    if [[ -f "$BACKUP/sources.lock" ]]; then
        mv -f -- "$BACKUP/sources.lock" "$LOCK" || rc=1
    else
        rm -f -- "$LOCK" || rc=1
    fi
    PUBLISHED=0
    return "$rc"
}

command -v git  >/dev/null 2>&1 || die "缺少 git"
command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v tar  >/dev/null 2>&1 || die "缺少 tar"
command -v mktemp >/dev/null 2>&1 || die "缺少 mktemp"
[[ -f "$CONF" ]] || die "找不到映射表：$CONF"
[[ -f "$LOCK" ]] || die "找不到 sources.lock（默认模式以 lock 中的 commit pin 为准）"

NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
ONLY="${SUITE_SYNC_ONLY:-}"
UPDATE="${SUITE_SYNC_UPDATE:-0}"
FAILED=0

is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

safe_rel_path() {
    local rest="$1" part
    case "$rest" in
        ''|/*|*'\'*|*'|'*|*';'*|*'&'*|*'$'*|*'`'*|*'"'*|*"'"*) return 1 ;;
    esac
    [[ ! "$rest" =~ [[:cntrl:]] ]] || return 1
    while [[ -n "$rest" ]]; do
        part="${rest%%/*}"
        [[ -n "$part" && "$part" != '.' && "$part" != '..' && "$part" != '.git' ]] || return 1
        if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    done
    return 0
}

valid_https_url() {
    local url="$1" rest
    case "$url" in
        https://*) rest="${url#https://}" ;;
        *) return 1 ;;
    esac
    [[ "$rest" != *@* && "$rest" != *'%'* && "$rest" != *'?'* && "$rest" != *'#'* ]] || return 1
    [[ -n "$rest" && "$rest" != '/'* ]] || return 1
    return 0
}

# curl 统一参数：仅 HTTPS、禁止重定向降级、超时、重试。
CURL_OPTS=(--proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL
           --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300)

retry() {
    local n="$1" rc=0 i=1
    shift
    while ((i <= n)); do
        if "$@"; then return 0; fi
        rc=$?
        if ((i < n)); then warn "命令失败，重试 $i/$n：${*}"; fi
        i=$((i + 1))
    done
    return "$rc"
}

# git 无内建总超时；用 timeout(1)（存在时）兜底，并依赖 GIT_HTTP_* 低速超时。
git_net() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 300 git "$@"
    else
        git "$@"
    fi
}

# 复制目录树（不依赖 rsync；排除 .git；拒绝符号链接目标）
copy_tree() {
    local src="$1" dst="$2"
    [[ ! -L "$dst" ]] || { warn "拒绝覆盖符号链接目标：$dst"; return 1; }
    rm -rf -- "$dst"
    mkdir -p -- "$dst"
    tar -C "$src" --exclude='./.git' -cf - . | tar -C "$dst" -xf -
}

# 收集上游仓库根的许可证类文件到 meta/<slug>/（许可证随快照保留）
copy_meta() {
    local src="$1" slug="$2" f dest="$STAGE/meta/$slug"
    mkdir -p -- "$dest"
    for f in "$src"/LICENSE "$src"/LICENSE.* "$src"/COPYING* \
             "$src"/THIRD-PARTY-NOTICES* "$src"/NOTICE*; do
        [[ -f "$f" ]] || continue
        cp -f -- "$f" "$dest/" || return 1
    done
    rmdir "$dest" 2>/dev/null || true
}

# 按 40 位 pin 抓取上游；不拉子模块、不拉 tag、不跟随分支浮动。
clone_pinned() {
    local url="$1" sha="$2" branch="$3" dst="$4" ref
    rm -rf -- "$dst"
    mkdir -p -- "$dst"
    git -C "$dst" init -q || return 1
    git -C "$dst" remote add origin "$url" || return 1
    if ! retry 3 git_net -C "$dst" fetch -q --no-tags --depth 1 origin "$sha"; then
        warn "$sha 浅抓取失败，尝试完整拉取 refs/heads/$branch（结果仍以 pin 为准）"
        retry 3 git_net -C "$dst" fetch -q --no-tags origin "refs/heads/$branch" || return 1
    fi
    git -C "$dst" checkout -q --detach "$sha" || return 1
    ref="$(git -C "$dst" rev-parse HEAD 2>/dev/null || true)"
    [[ "$ref" == "$sha" ]] || { warn "上游 HEAD 与 pin 不一致：$ref != $sha"; return 1; }
    if [[ -e "$dst/.gitmodules" ]]; then
        warn "上游含子模块，快照格式不支持子模块（避免 submodule drift）：$url"
        return 1
    fi
}

# 读取旧 lock 行；不存在时返回空
lock_line() {
    awk -F'|' -v s="$1" '$1 == s { print; exit }' "$LOCK" 2>/dev/null || true
}

# 生成新的 lock 行。pin 与 URL 都没变时沿用旧行（不产生纯时间戳提交噪音）。
lock_add() {
    local slug="$1" sha="$2" url="$3" old_line old_sha old_ts old_url old_extra
    old_line="$(lock_line "$slug")"
    if [[ -n "$old_line" ]]; then
        IFS='|' read -r old_slug old_sha old_ts old_url old_extra <<< "$old_line"
        if [[ "$old_sha" == "$sha" && "$old_url" == "$url" && -z "${old_extra:-}" ]]; then
            printf '%s\n' "$old_line" >> "$STAGE/sources.lock"
            return 0
        fi
    fi
    printf '%s|%s|%s|%s\n' "$slug" "$sha" "$NOW" "$url" >> "$STAGE/sources.lock"
}

# ---------------------------------------------------------------- staging 初始化
mkdir -p -- "$STAGE/packages" "$STAGE/meta" "$STAGE/config" "$BACKUP"
: > "$TMP/file_dsts"
: > "$TMP/targets"

if [[ -d "$ROOT/packages" ]]; then
    copy_tree "$ROOT/packages" "$STAGE/packages" || die "无法准备 staging/packages"
fi
if [[ -d "$ROOT/meta" ]]; then
    copy_tree "$ROOT/meta" "$STAGE/meta" || die "无法准备 staging/meta"
fi
if [[ -f "$ROOT/config/dot.config" ]]; then
    cp -f -- "$ROOT/config/dot.config" "$STAGE/config/dot.config" || die "无法准备 staging/config/dot.config"
fi
cp -f -- "$CONF" "$STAGE/sources.conf" || die "无法准备 staging/sources.conf"
: > "$STAGE/sources.lock"

# ---------------------------------------------------------------- 逐源同步（写入 staging）
while IFS='|' read -r slug url branch mode payload extra || [[ -n "${slug:-}" ]]; do
    case "$slug" in ''|\#*) continue ;; esac
    if [[ -n "$extra" || -z "$url" || -z "$branch" || -z "$mode" ]]; then
        warn "映射表条目格式不合法，跳过：$slug"; FAILED=1; continue
    fi
    safe_rel_path "$slug" || { warn "slug 不安全：$slug"; FAILED=1; continue; }
    valid_https_url "$url" || { warn "URL 必须是无凭据 HTTPS：$slug -> $url"; FAILED=1; continue; }
    [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$branch" != *..* ]] ||
        { warn "branch 不安全：$slug -> $branch"; FAILED=1; continue; }

    old_line="$(lock_line "$slug")"

    # 调试模式：未选中的源沿用旧 lock 行和旧快照，保证 lock 与 conf 仍然对齐
    if [[ -n "$ONLY" && ",${ONLY// /,}," != *",$slug,"* ]]; then
        log "跳过（SUITE_SYNC_ONLY 未包含）：$slug"
        if [[ -n "$old_line" ]]; then
            printf '%s\n' "$old_line" >> "$STAGE/sources.lock"
        fi
        continue
    fi

    # 默认：使用 lock 中已固定的 commit；UPDATE=1 时显式解析分支头（并记录新 pin）
    sha=""
    if [[ "$UPDATE" == "1" ]]; then
        remote_out="$(retry 3 git_net ls-remote --exit-code --heads "$url" "refs/heads/$branch")" ||
            { warn "无法解析上游分支头：$url $branch"; FAILED=1; continue; }
        read -r sha _ref <<< "$remote_out"
        is_sha "$sha" || { warn "ls-remote 返回无效 SHA：$url ${sha:-<空>}"; FAILED=1; continue; }
        log "更新 pin：$slug -> $sha（$branch）"
    else
        IFS='|' read -r _s sha _ts _url _extra <<< "$old_line"
        is_sha "$sha" || {
            warn "$slug 的 sources.lock 中缺少有效 40 位 commit pin（请先用 SUITE_SYNC_UPDATE=1 解析一次）"
            FAILED=1; continue
        }
        [[ "$_url" == "$url" ]] || {
            warn "$slug 的 URL 已变更（conf=$url lock=$_url），请先用 SUITE_SYNC_UPDATE=1 更新 pin"
            FAILED=1; continue
        }
        log "同步 $slug @ $sha（固定 pin，依据 $branch 历史）"
    fi

    case "$mode" in
    pkg)
        clone_pinned "$url" "$sha" "$branch" "$TMP/src/$slug" ||
            { warn "按 pin 克隆失败：$slug @ $sha"; FAILED=1; continue; }
        copy_meta "$TMP/src/$slug" "$slug" || { FAILED=1; continue; }

        local_ok=1
        dests=()
        for p in $payload; do
            safe_rel_path "$p" || { warn "$slug：不安全的 payload 路径：$p"; local_ok=0; break; }
            [[ -d "$TMP/src/$slug/$p" ]] ||
                { warn "$slug：上游不存在映射目录 $p（上游已重构？请更新 sources.conf 映射）"; local_ok=0; break; }
            d="$(basename "$p")"
            safe_rel_path "$d" || { warn "$slug：不安全的包目录名：$d"; local_ok=0; break; }
            grep -qxF "$d" "$TMP/targets" && { warn "$slug：目标目录 $d 已被其他源占用"; local_ok=0; break; }
            printf '%s\n' "$d" >> "$TMP/targets"
            copy_tree "$TMP/src/$slug/$p" "$STAGE/packages/$d" || { local_ok=0; break; }
            [[ -f "$STAGE/packages/$d/Makefile" ]] ||
                { warn "$d（来自 $p）拷贝后缺少 Makefile（同步结果无效）"; local_ok=0; break; }
            dests+=("$STAGE/packages/$d")
        done
        if ((local_ok == 1)) && [[ -f "$ROOT/patches/$slug.sh" ]]; then
            for d in "${dests[@]}"; do
                log "应用补丁：patches/$slug.sh -> $(basename "$d")"
                SUITE_SRC_DIR="$TMP/src/$slug" bash "$ROOT/patches/$slug.sh" "$d" ||
                    { warn "补丁 $slug.sh 应用失败（上游可能已重构，请检查补丁脚本）"; local_ok=0; break; }
            done
        fi
        ((local_ok == 1)) || { FAILED=1; continue; }

        lock_add "$slug" "$sha" "$url"
        rm -rf -- "$TMP/src/$slug"
        ;;

    all)
        safe_rel_path "$payload" || { warn "$slug：不安全的包目录名：$payload"; FAILED=1; continue; }
        [[ "$payload" != */* ]] || { warn "$slug：all 模式 payload 必须是单个目录名"; FAILED=1; continue; }
        grep -qxF "$payload" "$TMP/targets" && { warn "$slug：目标目录 $payload 已被其他源占用"; FAILED=1; continue; }
        printf '%s\n' "$payload" >> "$TMP/targets"

        clone_pinned "$url" "$sha" "$branch" "$TMP/src/$slug" ||
            { warn "按 pin 克隆失败：$slug @ $sha"; FAILED=1; continue; }
        copy_meta "$TMP/src/$slug" "$slug" || { FAILED=1; continue; }
        copy_tree "$TMP/src/$slug" "$STAGE/packages/$payload" || { FAILED=1; continue; }
        [[ -f "$STAGE/packages/$payload/Makefile" ]] ||
            { warn "$payload 拷贝后缺少 Makefile（同步结果无效）"; FAILED=1; continue; }

        if [[ -f "$ROOT/patches/$slug.sh" ]]; then
            log "应用补丁：patches/$slug.sh -> $payload"
            SUITE_SRC_DIR="$TMP/src/$slug" bash "$ROOT/patches/$slug.sh" "$STAGE/packages/$payload" ||
                { warn "补丁 $slug.sh 应用失败（上游可能已重构，请检查补丁脚本）"; FAILED=1; continue; }
        fi

        lock_add "$slug" "$sha" "$url"
        rm -rf -- "$TMP/src/$slug"
        ;;

    file)
        read -r src_path dst_path leftover <<< "$payload"
        if [[ -z "${src_path:-}" || -z "${dst_path:-}" || -n "${leftover:-}" ]] ||
           ! safe_rel_path "$src_path" || ! safe_rel_path "$dst_path"; then
            warn "$slug：mode=file 的 payload 应为安全的『源路径 目标路径』"
            FAILED=1; continue
        fi
        case "$dst_path" in
            sources.conf|sources.lock|packages/*|scripts/*|diy/*|patches/*|build/*)
                warn "$slug：file 模式不允许覆盖控制文件：$dst_path"; FAILED=1; continue ;;
        esac
        case "$url" in
            https://github.com/*/*.git)
                repo_path="${url#https://github.com/}"
                repo_path="${repo_path%.git}"
                ;;
            *) warn "$slug：file 模式仅支持 https://github.com/<owner>/<repo>.git"; FAILED=1; continue ;;
        esac
        raw_url="https://raw.githubusercontent.com/$repo_path/$sha/$src_path"
        mkdir -p -- "$(dirname "$STAGE/$dst_path")"
        tmp_out="$(mktemp "$STAGE/$dst_path.XXXXXX")"
        if ! retry 3 curl "${CURL_OPTS[@]}" "$raw_url" -o "$tmp_out"; then
            warn "下载失败：$raw_url，保留现有文件"
            rm -f -- "$tmp_out"; FAILED=1; continue
        fi
        [[ -s "$tmp_out" ]] ||
            { warn "下载结果为空：$dst_path"; rm -f -- "$tmp_out"; FAILED=1; continue; }
        mv -f -- "$tmp_out" "$STAGE/$dst_path" || { FAILED=1; continue; }
        printf '%s\n' "$dst_path" >> "$TMP/file_dsts"
        lock_add "$slug" "$sha" "$url"
        ;;

    *)
        warn "$slug：未知模式 $mode（支持 pkg / all / file）"
        FAILED=1
        ;;
    esac
done < "$CONF"

# 未选中 slug 的 lock 行必须存在（校验会强制 conf/lock 一一对应）
if ((FAILED == 1)); then
    die "同步过程中有源失败（见上方警告）。本次未发布任何快照，sources.lock 保持不变"
fi

sort -t'|' -k1,1 "$STAGE/sources.lock" > "$STAGE/sources.lock.sorted" ||
    die "sources.lock 排序失败"
mv -f -- "$STAGE/sources.lock.sorted" "$STAGE/sources.lock"

# 发布前对 staging 做完整结构校验；不通过就不碰工作树
SUITE_ROOT="$STAGE" bash "$ROOT/scripts/validate.sh" ||
    die "staging 结构校验未通过，本次未发布任何快照"

# ---------------------------------------------------------------- 原子发布
swap_dir() {
    local live="$1" staged="$2" bak="$3"
    [[ ! -L "$live" ]] || { warn "拒绝替换符号链接目录：$live"; return 1; }
    if [[ -e "$live" ]]; then
        mv -- "$live" "$bak" || return 1
    fi
    mv -- "$staged" "$live" || return 1
}

publish_file() {
    local rel="$1" live="$ROOT/$1" staged="$STAGE/$1" bak="$BACKUP/$1"
    [[ -f "$staged" ]] || { warn "待发布文件不存在：$staged"; return 1; }
    [[ ! -L "$live" ]] || { warn "拒绝替换符号链接文件：$live"; return 1; }
    mkdir -p -- "$(dirname "$bak")" "$(dirname "$live")"
    if [[ -f "$live" ]]; then
        cp -p -- "$live" "$bak" || return 1
    fi
    mv -f -- "$staged" "$live" || return 1
}

PUBLISHED=1
swap_dir "$ROOT/packages" "$STAGE/packages" "$BACKUP/packages" || { rollback; die "发布 packages/ 失败"; }
swap_dir "$ROOT/meta" "$STAGE/meta" "$BACKUP/meta" || { rollback; die "发布 meta/ 失败"; }
while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    publish_file "$rel" || { rollback; die "发布 $rel 失败"; }
done < "$TMP/file_dsts"
if [[ -f "$LOCK" ]]; then
    cp -p -- "$LOCK" "$BACKUP/sources.lock" || { rollback; die "备份 sources.lock 失败"; }
fi
mv -f -- "$STAGE/sources.lock" "$LOCK" || { rollback; die "发布 sources.lock 失败"; }

# 发布后再校验一次；失败则整体回滚
if ! bash "$ROOT/scripts/validate.sh"; then
    rollback || warn "自动回滚失败，请从 git 历史恢复"
    die "发布后校验失败，已尝试回滚"
fi
PUBLISHED=0

log "sources.lock 已更新（$(wc -l < "$LOCK" | tr -d ' ') 个源，全部为固定 commit）"

# 在 git 仓库里时，给出变更摘要（提交动作由调用方决定）
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    log "本次同步引起的变更："
    git -C "$ROOT" status --porcelain | sed 's/^/    /' || true
fi

log "同步完成"
