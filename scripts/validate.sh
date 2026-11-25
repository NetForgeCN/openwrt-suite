#!/usr/bin/env bash
#
# openwrt-suite 结构校验（同步后自动执行，也可单独运行）
#
# 校验项:
#   1. packages/ 下每个目录都必须含 Makefile（feed 可被 OpenWrt 正确扫描）
#   2. 快照内不得残留 .git，符号链接不得逃出 packages/
#   3. sources.conf / sources.lock 格式、pin、HTTPS、一一对应（slug 与源地址都比对）
#   4. config/dot.config 存在、非空、含有效 Kconfig 行
#   5. 包清单健全性：包名不重复、Makefile 结构完整、上游源码带 hash pin
#   6. 许可证/归属信息存在；补丁脚本语法正确且 slug 有对应源
#   7. 本仓库 shell 脚本语法（bash -n / sh -n）
#
# SUITE_ROOT 可指向一个临时 staging 目录，供 scripts/sync.sh 在发布前校验；
# 不设置时默认校验脚本所在的仓库根目录。

set -Eeuo pipefail
export LC_ALL=C LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ROOT="${SUITE_ROOT:-$SCRIPT_DIR}"
err=0
TMP_VALIDATE="$(mktemp -d "${TMPDIR:-/tmp}/suite-validate.XXXXXX")"
trap 'rm -rf -- "$TMP_VALIDATE"' EXIT

log()  { printf '[校验] %s\n' "$*"; }
fail() { printf '[校验失败] %s\n' "$*" >&2; err=1; }
warn() { printf '[校验警告] %s\n' "$*" >&2; }

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
    # 不允许内联凭据、查询串或 fragment（凭据泄漏 / 参数注入）
    [[ "$rest" != *@* && "$rest" != *'?'* && "$rest" != *'#'* ]] || return 1
    [[ -n "$rest" && "$rest" != '/'* ]] || return 1
    return 0
}

# ---------------------------------------------------------------- 1/2. 快照结构
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

    src_dirs="$(find -L "$ROOT/packages" -name Makefile -type f 2>/dev/null |
        xargs grep -lE 'call (BuildPackage|BuildTarget|BuildContainer|BuildCompose|KernelPackage)' 2>/dev/null |
        sed "s#$ROOT/packages/##; s#/Makefile\$##" | sort || true)"
    src_count="$(printf '%s\n' "$src_dirs" | grep -c . || true)"
    log "可被扫描的包源目录 $src_count 个（含嵌套子包）："
    printf '%s\n' "$src_dirs" | sed 's/^/    /' | grep -v '^    $' || true

    ((count > 0)) || fail "packages/ 为空"
else
    fail "缺少 packages/ 目录"
fi

# .git 目录或文件（git worktree / submodule 指针）都不能进入快照
while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    fail "快照内残留 .git：$g"
done < <(find "$ROOT/packages" -name .git -print 2>/dev/null || true)

# 符号链接不得指向 packages/ 之外（避免 feed 扫描时逃出快照读取任意文件）
while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    target="$(readlink "$l" 2>/dev/null || true)"
    [[ -n "$target" ]] || { fail "符号链接无目标：$l"; continue; }
    case "$target" in
        /*) fail "packages/ 中存在绝对符号链接：$l -> $target"; continue ;;
    esac
    resolved="$(cd "$(dirname "$l")" 2>/dev/null && cd "$target" 2>/dev/null && pwd -P)" || resolved=""
    case "$resolved" in
        "$ROOT/packages"|"$ROOT/packages"/*) : ;;
        *) fail "符号链接逃出 packages/：$l -> $target" ;;
    esac
done < <(find "$ROOT/packages" -type l -print 2>/dev/null || true)

# ---------------------------------------------------------------- 3. conf/lock
conf="$ROOT/sources.conf"
lock="$ROOT/sources.lock"
if [[ -f "$conf" && -f "$lock" ]]; then
    : > "$TMP_VALIDATE/conf.slugs"
    : > "$TMP_VALIDATE/lock.slugs"
    : > "$TMP_VALIDATE/conf.map"
    : > "$TMP_VALIDATE/lock.map"
    : > "$TMP_VALIDATE/targets"
    : > "$TMP_VALIDATE/patch_slugs"

    while IFS='|' read -r slug url branch mode payload extra || [[ -n "${slug:-}" ]]; do
        case "$slug" in ''|\#*) continue ;; esac
        [[ -z "${extra:-}" ]] || fail "sources.conf 字段数不是 5：$slug（$extra）"
        printf '%s\n' "$slug" >> "$TMP_VALIDATE/conf.slugs"
        printf '%s %s\n' "$slug" "$url" >> "$TMP_VALIDATE/conf.map"

        safe_rel_path "$slug" || fail "sources.conf slug 不安全：$slug"
        valid_https_url "$url" || fail "sources.conf URL 必须是无凭据 HTTPS：$slug -> $url"
        [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$branch" != *..* ]] ||
            fail "sources.conf branch 不安全：$slug -> $branch"

        case "$mode" in
            pkg)
                [[ -n "$payload" ]] || { fail "$slug: pkg 模式的 payload 为空"; continue; }
                for p in $payload; do
                    safe_rel_path "$p" || { fail "$slug: payload 路径不安全：$p"; continue; }
                    d="${p##*/}"
                    printf '%s\n' "$d" >> "$TMP_VALIDATE/targets"
                    [[ -f "$ROOT/packages/$d/Makefile" ]] ||
                        warn "sources.conf 声明了 $p（目标目录 $d）但 packages/ 中无此目录"
                done
                ;;
            all)
                safe_rel_path "$payload" || { fail "$slug: payload 路径不安全：$payload"; continue; }
                [[ "$payload" != */* ]] || fail "$slug: all 模式 payload 必须是单个目录名：$payload"
                printf '%s\n' "$payload" >> "$TMP_VALIDATE/targets"
                [[ -f "$ROOT/packages/$payload/Makefile" ]] ||
                    warn "sources.conf 声明了 $payload 但 packages/ 中无此目录"
                ;;
            file)
                read -r src_path dst_path leftover <<< "$payload"
                [[ -n "${src_path:-}" && -n "${dst_path:-}" && -z "${leftover:-}" ]] ||
                    { fail "$slug: file 模式的 payload 必须是『源路径 目标路径』"; continue; }
                safe_rel_path "$src_path" || fail "$slug: file 源路径不安全：$src_path"
                safe_rel_path "$dst_path" || fail "$slug: file 目标路径不安全：$dst_path"
                case "$dst_path" in
                    sources.conf|sources.lock|packages/*|scripts/*|diy/*|patches/*|build/*)
                        fail "$slug: file 模式不允许覆盖控制文件：$dst_path" ;;
                esac
                ;;
            *) fail "$slug: 未知模式 $mode（支持 pkg / all / file）" ;;
        esac
    done < "$conf"

    # 目标目录不得由两个源同时写入（后者会静默覆盖前者）
    dup_targets="$(sort "$TMP_VALIDATE/targets" | uniq -d)"
    [[ -z "$dup_targets" ]] || fail "多个源映射到同一目标包目录：$(printf '%s ' $dup_targets)"

    while IFS='|' read -r slug sha ts url extra || [[ -n "${slug:-}" ]]; do
        [[ -n "$slug" ]] || continue
        printf '%s\n' "$slug" >> "$TMP_VALIDATE/lock.slugs"
        printf '%s %s\n' "$slug" "$url" >> "$TMP_VALIDATE/lock.map"
        is_sha "$sha" || fail "sources.lock commit 不是 40 位小写 SHA：$slug -> ${sha:-<空>}"
        [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
            fail "sources.lock 时间戳格式不是 UTC ISO8601：$slug -> ${ts:-<空>}"
        valid_https_url "$url" || fail "sources.lock URL 必须是无凭据 HTTPS：$slug -> $url"
        [[ -z "${extra:-}" ]] || fail "sources.lock 字段数不是 4：$slug"
    done < "$lock"

    conf_slugs="$(sort -u "$TMP_VALIDATE/conf.slugs")"
    lock_slugs="$(sort -u "$TMP_VALIDATE/lock.slugs")"
    [[ "$(wc -l < "$TMP_VALIDATE/conf.slugs" | tr -d ' ')" == "$(sort -u "$TMP_VALIDATE/conf.slugs" | wc -l | tr -d ' ')" ]] ||
        fail "sources.conf 中有重复 slug"
    [[ "$(wc -l < "$TMP_VALIDATE/lock.slugs" | tr -d ' ')" == "$(sort -u "$TMP_VALIDATE/lock.slugs" | wc -l | tr -d ' ')" ]] ||
        fail "sources.lock 中有重复 slug"
    if [[ "$conf_slugs" != "$lock_slugs" ]]; then
        fail "sources.conf 与 sources.lock 的源列表不一致：
    conf:  $(printf '%s ' $conf_slugs)
    lock:  $(printf '%s ' $lock_slugs)"
    else
        log "sources.lock 覆盖全部 $(printf '%s\n' "$conf_slugs" | grep -c . || true) 个源（全部为 40 位 commit pin）"
    fi

    conf_map="$(sort "$TMP_VALIDATE/conf.map")"
    lock_map="$(sort "$TMP_VALIDATE/lock.map")"
    if [[ "$conf_map" != "$lock_map" ]]; then
        fail "sources.conf 与 sources.lock 的源地址不一致：
    conf:  $(printf '%s ' $(awk '{print $2}' "$TMP_VALIDATE/conf.map" | sort -u))
    lock:  $(printf '%s ' $(awk '{print $2}' "$TMP_VALIDATE/lock.map" | sort -u))"
    else
        log "源地址与 sources.conf 一致（$(printf '%s\n' "$conf_map" | grep -c . || true) 个源）"
    fi
else
    fail "缺少 sources.conf 或 sources.lock"
fi

# ---------------------------------------------------------------- 4. .config
cfg="$ROOT/config/dot.config"
if [[ -s "$cfg" ]] && grep -qE '^(CONFIG_|# CONFIG_)' "$cfg"; then
    log "config/dot.config 有效（$(wc -l < "$cfg" | tr -d ' ') 行）"
else
    fail "config/dot.config 缺失或不含 Kconfig 配置项"
fi

# ---------------------------------------------------------------- 5. 包清单健全性
if [[ -d "$ROOT/packages" ]]; then
    # 5a. 包名重复（Package/ 与 KernelPackage/ 都算；忽略 $(PKG_NAME) 这类动态名）
    find "$ROOT/packages" -type f -name Makefile -print0 2>/dev/null |
        xargs -0 awk '
            /^define (Package|KernelPackage)\// {
                n=$2
                sub(/^(Package|KernelPackage)\//, "", n)
                sub(/\/.*$/, "", n)
                if (n ~ /\$/) next
                d=FILENAME; sub(/\/Makefile$/, "", d)
                if (!seen[n FS d]++) print n FS d
            }
        ' > "$TMP_VALIDATE/pkg-names" || true
    # awk 输出为 "name dir"，取第一列后查重
    dup_pkgs="$(awk '{print $1}' "$TMP_VALIDATE/pkg-names" | sort | uniq -d)"
    [[ -z "$dup_pkgs" ]] || fail "存在重复包名：$(printf '%s ' $dup_pkgs)"

    # 5b. define/endif 配对与空 Makefile
    while IFS= read -r mf; do
        [[ -n "$mf" ]] || continue
        [[ -s "$mf" ]] || { fail "空 Makefile：$mf"; continue; }
        opens="$(grep -cE '^(define|ifdef|ifndef|ifeq|ifneq)[[:space:]]' "$mf" || true)"
        closes="$(grep -cE '^(endef|endif)([[:space:]]|$)' "$mf" || true)"
        [[ "$opens" == "$closes" ]] ||
            fail "Makefile 条件/define 块不配对（$opens 开 / $closes 闭）：$mf"
        # 5c. 声明了源码下载地址就必须有 hash pin（OpenWrt PKG_HASH / PKG_MIRROR_HASH）
        if grep -qE '^PKG_SOURCE_URL[[:space:]]*[:?]?=' "$mf" &&
           grep -qE '^PKG_SOURCE_PROTO[[:space:]]*[:?]?=[[:space:]]*git' "$mf" &&
           ! grep -qE '^PKG_SOURCE_VERSION[[:space:]]*[:?]?=[[:space:]]*[0-9a-f]{40}[[:space:]]*$' "$mf" &&
           ! grep -qE '^PKG_MIRROR_HASH[[:space:]]*[:?]?=' "$mf"; then
            fail "git 源既不是 40 位 commit pin 也没有 PKG_MIRROR_HASH：$mf"
        fi
        if grep -qE '^PKG_SOURCE_URL[[:space:]]*[:?]?=' "$mf" &&
           ! grep -qE '^PKG_SOURCE_PROTO[[:space:]]*[:?]?=[[:space:]]*git' "$mf" &&
           ! grep -qE '(PKG_HASH|PKG_MIRROR_HASH|HASH)' "$mf"; then
            fail "tarball 源缺少 SHA256 pin：$mf"
        fi
    done < <(find "$ROOT/packages" -type f -name Makefile -print 2>/dev/null | sort || true)

    # 5d. 许可证/归属：包内许可证文件、meta/<slug>/ 许可证、或 Makefile 的许可证声明
    if [[ -f "$conf" ]]; then
        while IFS='|' read -r slug url branch mode payload extra || [[ -n "${slug:-}" ]]; do
            case "$slug" in ''|\#*) continue ;; esac
            [[ "$mode" == file ]] && continue
            local_ok=0
            for p in $payload; do
                d="${p##*/}"
                if [[ -d "$ROOT/packages/$d" ]]; then
                    if find "$ROOT/packages/$d" -maxdepth 2 \
                            \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) \
                            -print -quit 2>/dev/null | grep -q .; then
                        local_ok=1
                    fi
                    mf="$ROOT/packages/$d/Makefile"
                    if [[ -f "$mf" ]] && grep -qE '^(PKG_LICENSE|LUCI_LICENSE|PKG_LICENSE_FILES)[[:space:]]*[:?]?=' "$mf"; then
                        local_ok=1
                    fi
                fi
            done
            for f in "$ROOT/meta/$slug"/LICENSE* "$ROOT/meta/$slug"/COPYING* "$ROOT/meta/$slug"/NOTICE*; do
                if [[ -f "$f" ]]; then local_ok=1; fi
            done
            ((local_ok == 1)) || fail "缺少许可证/归属信息（包内 LICENSE、meta/$slug/ 或 Makefile LICENSE 声明均无）：$slug"
        done < "$conf"
    fi
fi

# ---------------------------------------------------------------- 6. 补丁挂钩
if [[ -d "$SCRIPT_DIR/patches" ]]; then
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        bash -n "$p" || fail "补丁脚本语法错误：$p"
        grep -qE '^[[:space:]]*set[[:space:]]' "$p" || fail "补丁脚本未启用严格模式（set -e）：$p"
        slug="${p##*/}"; slug="${slug%.sh}"
        printf '%s\n' "$slug" >> "$TMP_VALIDATE/patch_slugs"
    done < <(find "$SCRIPT_DIR/patches" -maxdepth 1 -type f -name '*.sh' -print | sort || true)
    # 补丁挂钩按设计是可选的（sources.conf 已注明），因此不为每个没有补丁的
    # 源产生警告；只反向检查“补丁存在但源不存在”这种真正的配置错误。
    while IFS= read -r slug; do
        [[ -n "$slug" ]] || continue
        if [[ -f "$conf" ]] && ! grep -qE "^${slug}\|" "$conf"; then
            fail "补丁脚本没有对应的 sources.conf 源：$slug.sh"
        fi
    done < "$TMP_VALIDATE/patch_slugs"
fi

# ---------------------------------------------------------------- 7. 脚本语法
while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    case "$s" in
        */sh-functions) continue ;;
    esac
    bash -n "$s" || fail "shell 脚本语法错误：$s"
done < <(find "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/diy" "$SCRIPT_DIR/build" "$SCRIPT_DIR/patches" \
            -maxdepth 2 -type f -name '*.sh' -print 2>/dev/null | sort || true)
while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    head -n 1 "$s" | grep -q '^#!.*\(/bin/sh\|/usr/bin/env sh\)' || continue
    sh -n "$s" || fail "POSIX sh 脚本语法错误：$s"
done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -type f -name '*.sh' -print 2>/dev/null | sort || true)

if ((err == 1)); then
    exit 1
fi
log "校验全部通过"
