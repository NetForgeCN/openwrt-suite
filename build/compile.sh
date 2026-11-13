#!/usr/bin/env bash
#
# OpenWrt (x86-64) 一键构建脚本 —— openwrt-suite 单源版
#
# 与旧版的区别: 所有第三方组件（18 个包 + .config）全部来自自有的聚合仓库
# openwrt-suite（https://github.com/NetForgeCN/openwrt-suite），构建时只需
# 拉取这一个源；官方 feed 同名包（nqptp / v2ray-geodata / ddns-go 等）由
# feeds.conf 顺序保证优先使用 suite 版本，不再需要任何特判。
# 不能聚合的部分（官方 feed 补丁 / 内核配置）由仓库内 diy/ 脚本现场处理。
#
# 用法:
#   ./compile.sh              # 完整流程：更新源码 -> 配置 feeds -> 同步 suite -> 编译
#   ./compile.sh --help       # 查看所有可配置项
#
# 常用环境变量（见 --help）:
#   WORKDIR=/path/to/openwrt  JOBS=8  SKIP_UPDATE=1  REFRESH_CONFIG=1 ...
#
# 说明: 主仓库与 suite 仓库均不锁定版本，跟随默认分支最新代码
#       （上游 commit 由 suite 仓库的每日同步锁定，构建可复现）；
#       不使用文件锁（flock），所有准备工作均可重复执行（幂等）。
#

set -Eeuo pipefail

# 统一 locale：既避免 sort/grep 的 locale 差异，也避免 bash 3.2 在 UTF-8 下
# 把全角标点的首字节误判成变量名的一部分（$VAR）+ 中文 会报 unbound variable
export LC_ALL=C LANG=C

# ---------------------------------------------------------------------------
# 可配置项（全部可用环境变量覆盖）
# ---------------------------------------------------------------------------

WORKDIR="${WORKDIR:-${HOME}/openwrt}"
OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
SUITE_REPO="${SUITE_REPO:-https://github.com/NetForgeCN/openwrt-suite.git}"
SUITE_DIR="${SUITE_DIR:-${WORKDIR}/suite}"
CONFIG_URL="${CONFIG_URL:-}"                # 留空 = 用 suite 仓库的 config/dot.config 快照；
                                             # 非空 = 从该 URL 下载 .config（临时覆盖快照）
GO_AMD64_LEVEL="${GO_AMD64_LEVEL:-v3}"     # GOAMD64 微架构级别：v1/v2/v3/v4
RUST_MAKEFILE="${RUST_MAKEFILE:-feeds/packages/lang/rust/Makefile}"
GOLANG_VALUES="${GOLANG_VALUES:-feeds/packages/lang/golang/golang-values.mk}"
TARGET_SUBDIR="${TARGET_SUBDIR:-x86}"
KERNEL_CONFIG="${KERNEL_CONFIG:-}"          # 留空则自动探测 target/linux/<TARGET>/config-<ver>
JOBS="${JOBS:-}"                            # 留空则自动探测 CPU 核心数

SKIP_UPDATE="${SKIP_UPDATE:-0}"             # 1 = 不更新主仓库与 suite 仓库
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"          # 1 = 跳过 make download
SKIP_BUILD="${SKIP_BUILD:-0}"               # 1 = 只做准备工作，不编译
REFRESH_CONFIG="${REFRESH_CONFIG:-0}"       # 1 = 用 suite 仓库的 .config 覆盖本地（旧配置备份）
                                             # 默认 0：本地已有 .config 时保留（make menuconfig 的
                                             # 改动不会被覆盖）；.config 缺失时仍从 suite 快照写入
CLEAN_KERNEL="${CLEAN_KERNEL:-auto}"        # auto|1|0：内核配置变更后是否 make target/linux/clean
CLEAN_GOLANG="${CLEAN_GOLANG:-auto}"        # auto|1|0：GO_AMD64 变更后是否 make golang/clean
MENUCONFIG_ONLY="${MENUCONFIG_ONLY:-0}"     # 1 = 准备完直接打开 make menuconfig（--menuconfig）

# honk 核心的宿主机工具链版本：必须与 openwrt-suite README「宿主机依赖」一节、
# 以及 NetForgeCN/OpenWRT 的 OpenWRT.yml 里同名常量保持一致，否则 honk 编译失败
HONK_ZIG_VERSION="${HONK_ZIG_VERSION:-0.14.1}"
HONK_BPF_LINKER_VERSION="${HONK_BPF_LINKER_VERSION:-0.11.0}"
# bpf-linker 按宿主机架构分开打包，两个资产的 sha256 不同；脚本按 uname -m 选
HONK_BPF_LINKER_SHA256_X86_64="${HONK_BPF_LINKER_SHA256_X86_64:-${HONK_BPF_LINKER_SHA256:-10f62ba9ab7e544d538370552660efcb4f1a19153d5752bbf0f6b51f3bada450}}"
HONK_BPF_LINKER_SHA256_AARCH64="${HONK_BPF_LINKER_SHA256_AARCH64:-d09ddd83303e9ab1443f51e0e284680154009646a3ce141c63d838ee61b73eb9}"
# 空 = 自动判断：CI（GITHUB_ACTIONS）或免密 sudo 可用时自动装，否则只提示不装
HONK_TOOLCHAIN_AUTO="${HONK_TOOLCHAIN_AUTO:-}"

# 内部状态标记（先给默认值，避免被管道/子shell 调用时出现未绑定变量）
RUST_CHANGED=0
GOLANG_CHANGED=0
KERNEL_CHANGED=0
DIY_STATE_FILE=""   # 由 prepare_suite 设定为 $WORKDIR/.suite-diy-state.env

TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/openwrt-build.XXXXXX")"
cleanup() { rm -rf -- "$TMP_WORK"; }

on_err() {
    local rc=$?
    printf '\n%s[错误] 脚本在第 %s 行执行失败，退出码：%s%s\n' "$C_RED" "$1" "$rc" "$C_OFF" >&2
    printf '%s[错误] 失败命令：%s%s\n' "$C_RED" "$2" "$C_OFF" >&2
    exit "$rc"
}

trap 'cleanup' EXIT
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi

log()  { printf '\n%s[%s] %s%s\n' "$C_GREEN"  "$(date '+%F %T')" "$*" "$C_OFF"; }
warn() { printf '\n%s[警告] %s%s\n' "$C_YELLOW" "$*" "$C_OFF" >&2; }
die()  { printf '\n%s[错误] %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

detect_jobs() {
    local n=""
    if command -v nproc >/dev/null 2>&1; then n="$(nproc 2>/dev/null || true)"; fi
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=1
    printf '%s\n' "$n"
}

# 消除 "detected dubious ownership" 导致的 git 操作失败
git_safe() {
    local dir="$1"
    git config --global --get-all safe.directory 2>/dev/null |
        grep -qxF "$dir" || git config --global --add safe.directory "$dir" 2>/dev/null || true
}

repo_is_dirty() {
    ! git -C "$1" diff --quiet --ignore-submodules -- 2>/dev/null ||
        ! git -C "$1" diff --cached --quiet --ignore-submodules -- 2>/dev/null
}

# 克隆或更新一个 Git 仓库（不锁定版本，跟随默认分支）
ensure_repo() {
    local url="$1" dir="$2" parent

    parent="$(dirname "$dir")"
    [[ -d "$parent" ]] || mkdir -p -- "$parent"

    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        log "首次克隆：$dir"
        git clone "$url" "$dir"
        return 0
    fi

    if [[ ! -d "$dir/.git" ]]; then
        die "目标已存在但不是 Git 仓库：$dir"
    fi

    git_safe "$(cd "$dir" && pwd -P)"

    if [[ "$SKIP_UPDATE" == "1" ]]; then
        log "跳过更新（SKIP_UPDATE=1）：$dir"
        return 0
    fi

    if repo_is_dirty "$dir"; then
        warn "$dir 存在未提交的本地修改，跳过更新以便保留你的改动"
        return 0
    fi

    if ! git -C "$dir" symbolic-ref -q HEAD >/dev/null; then
        warn "$dir 处于 detached HEAD 状态，跳过更新"
        return 0
    fi

    log "更新仓库：$dir"
    if ! git -C "$dir" pull --ff-only; then
        warn "$dir 无法快进更新（本地分支可能已分叉），继续使用当前代码；"
        warn "如需强制同步，请手动执行：git -C \"$dir\" reset --hard origin/\$(git -C \"$dir\" branch --show-current)"
    fi
}

# 读取 diy 脚本写入的状态（决定是否清理对应构建缓存）
load_diy_state() {
    RUST_CHANGED=0
    GOLANG_CHANGED=0
    KERNEL_CHANGED=0
    [[ -f "$DIY_STATE_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$DIY_STATE_FILE"
}

# ---------------------------------------------------------------------------
# 步骤 1：环境检查
# ---------------------------------------------------------------------------

check_env() {
    log "检查运行环境"

    local required=(git make curl sed awk grep find tar)
    local optional=(gcc g++ cc patch perl python3 unzip xz gzip bzip2 flex bison gawk rsync file)
    local cmd missing=() missing_opt=()

    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    for cmd in "${optional[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_opt+=("$cmd")
    done

    ((${#missing[@]} == 0)) || die "缺少必需命令：${missing[*]}"
    ((${#missing_opt[@]} == 0)) ||
        warn "建议安装的构建依赖缺失：${missing_opt[*]}（Debian/Ubuntu 可参考 docs 的 buildsystem 依赖列表）"

    case "$(uname -s)" in
        Linux) : ;;
        *)
            warn "当前系统为 $(uname -s)。OpenWrt 官方仅支持在 Linux（含 WSL/容器）上编译，"
            warn "在非 Linux 上大概率会在文件系统大小写/工具链环节失败。"
            ;;
    esac

    JOBS="${JOBS:-$(detect_jobs)}"
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "无法获取有效的 CPU 并行任务数（JOBS=${JOBS}）"

    # 统一 locale，避免 sort/grep/编译期出现 locale 相关差异
    export LC_ALL=C LANG=C
    unset -v GREP_OPTIONS || true
}

# ---------------------------------------------------------------------------
# 步骤 2：主仓库 + suite 仓库
# ---------------------------------------------------------------------------

prepare_source() {
    log "检查 OpenWrt 主仓库"

    if [[ ! -e "$WORKDIR" && ! -L "$WORKDIR" ]]; then
        mkdir -p -- "$(dirname "$WORKDIR")"
        log "首次运行：克隆 OpenWrt 主仓库 -> $WORKDIR"
        git clone "$OPENWRT_REPO" "$WORKDIR"
    else
        ensure_repo "$OPENWRT_REPO" "$WORKDIR"
    fi

    [[ -d "$WORKDIR/.git" ]] || die "$WORKDIR 不是有效的 Git 仓库"

    cd "$WORKDIR"
    git_safe "$WORKDIR"

    local branch
    branch="$(git branch --show-current 2>/dev/null || echo '(detached HEAD)')"
    log "OpenWrt 分支：${branch}"
    log "OpenWrt 提交：$(git rev-parse --short HEAD)"
}

prepare_suite() {
    log "检查 openwrt-suite 聚合仓库"

    ensure_repo "$SUITE_REPO" "$SUITE_DIR"
    [[ -d "$SUITE_DIR/.git" ]] || die "$SUITE_DIR 不是有效的 Git 仓库"
    [[ -d "$SUITE_DIR/packages" ]] || die "$SUITE_DIR 缺少 packages/ 目录（仓库结构异常）"

    git_safe "$SUITE_DIR"

    log "suite 提交：$(git -C "$SUITE_DIR" rev-parse --short HEAD)"

    # 上游版本记录（sources.lock 摘要）
    if [[ -f "$SUITE_DIR/sources.lock" ]]; then
        log "suite 快照对应的上游版本（sources.lock 摘要）："
        awk -F'|' '{ printf "    %-14s %s\n", $1, substr($2, 1, 10) }' "$SUITE_DIR/sources.lock" | head -n 15
    fi

    DIY_STATE_FILE="$WORKDIR/.suite-diy-state.env"
}

# ---------------------------------------------------------------------------
# 步骤 3：feeds 配置与更新
# ---------------------------------------------------------------------------

configure_feeds() {
    log "配置 suite feed（置于官方 feeds 之前）"
    bash "$SUITE_DIR/diy/00-feeds-order.sh" "$WORKDIR" ||
        die "feeds 顺序配置失败"
}

update_feeds() {
    log "更新所有 feeds"
    ./scripts/feeds update -a

    log "安装所有 feeds 软件包（suite 排在最前，同名包优先用 suite 版本）"
    ./scripts/feeds install -a
}

# 解析符号链接的真实绝对路径（macOS 无 readlink -f）。
# 注意：必须先取 readlink 再 cd，且子 shell 内关闭 ERR trap 避免刷错误日志。
resolve_link() {
    local link="$1" target
    target="$(readlink "$link" 2>/dev/null || true)"
    [[ -n "$target" ]] || return 0
    ( trap - ERR; cd "$(dirname "$link")" 2>/dev/null && cd "$target" 2>/dev/null && pwd -P ) 2>/dev/null || true
}

# 校验同名包来源：feeds install -a 会跳过「已安装」的源包名，
# 因此旧构建树里残留的官方 nqptp / v2ray-geodata 等链接不会被自动纠正，
# 这里逐个检查、强制改用 suite 版本，然后二次复核。
verify_feed_priority() {
    log "校验第三方包来源（防止被官方同名包抢占）"

    local suite_feeds_dir pkg link real fixed=0 total=0 bad=""
    suite_feeds_dir="$(cd "$WORKDIR/feeds/suite" 2>/dev/null && pwd -P || true)"
    [[ -n "$suite_feeds_dir" ]] || die "找不到 $WORKDIR/feeds/suite（feeds update 未成功？）"

    shopt -s nullglob

    # 第一遍：纠正
    for d in "$WORKDIR"/feeds/suite/packages/*/; do
        [[ -d "$d" ]] || continue
        pkg="$(basename "$d")"
        total=$((total + 1))

        for link in package/feeds/*/"$pkg"; do
            [[ -e "$link" || -L "$link" ]] || continue
            real="$(resolve_link "$link")"

            [[ -n "$real" && "$real" == "$suite_feeds_dir"/* ]] && continue   # 已指向 feeds/suite

            warn "包 $pkg 当前指向 $(basename "$(dirname "$link")") feed，改用 suite 版本"
            rm -f -- package/feeds/*/"$pkg"                        # 清掉错误/悬空链接
            rm -f -- tmp/.packageinfo 2>/dev/null || true          # 让 feeds 重新扫描索引
            ./scripts/feeds install -p suite "$pkg" ||
                die "从 suite feed 重新安装 $pkg 失败"
            fixed=1
        done
    done

    # 第二遍：复核
    for d in "$WORKDIR"/feeds/suite/packages/*/; do
        [[ -d "$d" ]] || continue
        pkg="$(basename "$d")"
        for link in package/feeds/*/"$pkg"; do
            [[ -e "$link" || -L "$link" ]] || continue
            real="$(resolve_link "$link")"
            [[ -n "$real" && "$real" == "$suite_feeds_dir"/* ]] || bad="$bad $pkg"
        done
    done

    shopt -u nullglob

    [[ -z "$bad" ]] || die "以下包仍未来自 suite feed：$bad"
    if ((fixed == 1)); then
        log "已纠正同名包来源（共检查 ${total} 个包目录）"
    else
        log "同名包来源正确（共检查 ${total} 个包目录，全部指向 feeds/suite）"
    fi
}

# ---------------------------------------------------------------------------
# 步骤 4：官方 feed 补丁（Rust LLVM / Golang GOAMD64）
# ---------------------------------------------------------------------------

feed_patches() {
    log "应用官方 packages feed 补丁（Rust LLVM / Golang GO_AMD64）"
    GO_AMD64_LEVEL="$GO_AMD64_LEVEL" \
        RUST_MAKEFILE="$RUST_MAKEFILE" \
        GOLANG_VALUES="$GOLANG_VALUES" \
        bash "$SUITE_DIR/diy/01-feed-patches.sh" "$WORKDIR" ||
        die "feed 补丁应用失败"
}

# ---------------------------------------------------------------------------
# 步骤 5：.config（来自 suite 仓库快照）
# ---------------------------------------------------------------------------

prepare_config() {
    local suite_cfg="$SUITE_DIR/config/dot.config" dl_dir=""

    if [[ -n "$CONFIG_URL" ]]; then
        log "CONFIG_URL 已指定，从网络获取 .config：${CONFIG_URL}"
        dl_dir="$(mktemp -d "${TMPDIR:-/tmp}/openwrt-config.XXXXXX")"
        if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
            "$CONFIG_URL" -o "$dl_dir/config"; then
            rm -rf -- "$dl_dir"
            die "下载远程 .config 失败：$CONFIG_URL"
        fi
        suite_cfg="$dl_dir/config"
        [[ -s "$suite_cfg" ]] || { rm -rf -- "$dl_dir"; die "下载的 .config 为空"; }
    else
        log "准备固件配置文件 .config（来自 suite 仓库：${suite_cfg}）"
        [[ -s "$suite_cfg" ]] || die "suite 仓库缺少 config/dot.config（可用 CONFIG_URL 指定远程配置）"
    fi

    grep -qE '^(CONFIG_|# CONFIG_)' "$suite_cfg" ||
        { rm -rf -- "$dl_dir"; die "待写入的 .config 未检测到有效的 Kconfig 配置项"; }

    if [[ -f .config && "$REFRESH_CONFIG" != "1" ]]; then
        log "检测到已有 .config，保留现有配置（如需用快照覆盖请设置 REFRESH_CONFIG=1）"
    else
        if [[ -f .config && "$REFRESH_CONFIG" == "1" ]]; then
            local backup=".config.bak.$(date '+%Y%m%d-%H%M%S')"
            cp -f -- .config "$backup"
            warn "REFRESH_CONFIG=1，旧配置已备份为 $backup"
        fi

        cp -f -- "$suite_cfg" .config
        log "已写入 .config（$(wc -l < .config | tr -d ' ') 行，来源：$([[ -n "$CONFIG_URL" ]] && echo "$CONFIG_URL" || echo "suite 快照")）"
    fi
    rm -rf -- "$dl_dir"

    log "执行 make defconfig"
    make defconfig
    [[ -f .config ]] || die "make defconfig 之后 .config 丢失"
}

# ---------------------------------------------------------------------------
# 步骤 6：内核配置补丁
# ---------------------------------------------------------------------------

kernel_patches() {
    log "应用内核配置补丁（NETKIT / X86_NATIVE_CPU / X86_SGX）"
    TARGET_SUBDIR="$TARGET_SUBDIR" KERNEL_CONFIG="$KERNEL_CONFIG" \
        bash "$SUITE_DIR/diy/02-kernel-config.sh" "$WORKDIR" ||
        die "内核配置补丁失败"
}

# ---------------------------------------------------------------------------
# 步骤 7：缓存清理
# ---------------------------------------------------------------------------

clean_stale_artifacts() {
    load_diy_state

    local do_clean="$CLEAN_KERNEL"

    if [[ "$do_clean" == "auto" ]]; then
        if [[ "$KERNEL_CHANGED" == "1" ]]; then do_clean=1; else do_clean=0; fi
    fi

    if [[ "$do_clean" == "1" && "$KERNEL_CHANGED" == "1" ]]; then
        log "内核配置已变更，清理内核构建目录以确保配置生效"
        make target/linux/clean || warn "make target/linux/clean 失败，可忽略（首次构建时无缓存可清）"
    fi

    if [[ "$RUST_CHANGED" == "1" ]] && compgen -G 'build_dir/*/rust*' >/dev/null; then
        log "Rust 构建参数已变更，清理 Rust 构建缓存"
        make package/feeds/packages/rust/clean 2>/dev/null ||
            warn "Rust 缓存清理失败，如编译异常请手动执行 make package/feeds/packages/rust/clean"
    fi

    if [[ "$GOLANG_CHANGED" == "1" && "$CLEAN_GOLANG" != "0" ]] &&
        compgen -G 'build_dir/*/golang*' >/dev/null; then
        log "GO_AMD64 已变更，清理 Golang 构建缓存"
        if ! make package/feeds/packages/golang/clean 2>/dev/null; then
            warn "Golang 缓存清理失败；已编译过的 Go 包（dae / ddns-go 等）需重新编译才会生效"
            warn "必要时请手动执行：make package/feeds/packages/golang/clean"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 步骤 8：下载与编译
# ---------------------------------------------------------------------------

honk_enabled() {
    [[ -f .config ]] || return 1
    grep -qE '^CONFIG_PACKAGE_honk=[ym]' .config
}

install_honk_toolchain() {
    log "安装 honk 宿主机工具链（Rust / Zig ${HONK_ZIG_VERSION} / bpf-linker ${HONK_BPF_LINKER_VERSION}）"

    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get -qq update
        sudo apt-get -qq install -y libbpf-dev cmake libclang-dev zstd \
            xz-utils pkg-config ca-certificates curl
    else
        warn "非 apt 系系统，跳过系统包安装；请自行保证 libbpf / clang / zstd / xz 已就绪"
    fi

    if ! command -v rustup >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
            sh -s -- -y --profile minimal
    fi

    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        . "$HOME/.cargo/env"
    fi

    local tmp="${TMP_WORK}/honk-toolchain"
    mkdir -p -- "$tmp"

    # zig / bpf-linker 的资产名和 sha256 都随「宿主机」架构变（不是目标架构）。
    # 之前这里硬编码 x86_64，在 aarch64 机器上会装进 x86_64 的二进制 —— 表现为
    # "zig 版本不符：" 或直接 "cannot execute binary file"。按 uname -m 选择。
    local host_arch host_bpf_sha
    case "$(uname -m)" in
        x86_64|amd64)
            host_arch=x86_64
            host_bpf_sha="$HONK_BPF_LINKER_SHA256_X86_64"
            ;;
        aarch64|arm64)
            host_arch=aarch64
            host_bpf_sha="$HONK_BPF_LINKER_SHA256_AARCH64"
            ;;
        *)
            die "honk 工具链：暂不支持宿主机架构 $(uname -m)（只适配 x86_64 / aarch64；可手动装好 zig + bpf-linker 后设 HONK_TOOLCHAIN_AUTO=0）"
            ;;
    esac
    log "honk 工具链：宿主机架构 ${host_arch}（uname -m = $(uname -m)）"

    # bpf-linker：已装且「能跑」才跳过 —— 只看 command -v 会漏掉架构装错的情况
    if ! command -v bpf-linker >/dev/null 2>&1 ||
        ! bpf-linker --version >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$tmp/bpf-linker.tar.zst" \
            "https://github.com/aya-rs/bpf-linker/releases/download/v${HONK_BPF_LINKER_VERSION}/bpf-linker-${host_arch}-unknown-linux-musl.tar.zst" ||
            die "下载 bpf-linker 失败（宿主机 ${host_arch}）"
        printf '%s  %s\n' "$host_bpf_sha" "$tmp/bpf-linker.tar.zst" | sha256sum -c - ||
            die "bpf-linker sha256 校验失败（宿主机 ${host_arch}）"
        sudo tar --zstd -xf "$tmp/bpf-linker.tar.zst" -C /usr/local/bin ||
            die "解压 bpf-linker 失败"
    fi

    if ! command -v zig >/dev/null 2>&1 ||
        [[ "$(zig version 2>/dev/null)" != "$HONK_ZIG_VERSION" ]]; then
        curl -fsSL --retry 3 -o "$tmp/zig.tar.xz" \
            "https://ziglang.org/download/${HONK_ZIG_VERSION}/zig-${host_arch}-linux-${HONK_ZIG_VERSION}.tar.xz" ||
            die "下载 zig 失败（宿主机 ${host_arch}）"
        sudo tar -xJf "$tmp/zig.tar.xz" -C /usr/local || die "解压 zig 失败"
        sudo ln -sf "/usr/local/zig-${host_arch}-linux-${HONK_ZIG_VERSION}/zig" /usr/local/bin/zig
    fi

    # 收尾自检：两个工具都必须「能执行」，zig 版本还要精确匹配。
    # 架构装错时这里给出可读的错误，而不是等 honk 编译到一半才炸。
    local zig_ver
    zig_ver="$(zig version 2>/dev/null || true)"
    [[ -n "$zig_ver" ]] ||
        die "zig 无法执行（架构不匹配？宿主机 $(uname -m)，/usr/local/bin/zig -> $(readlink -f /usr/local/bin/zig 2>/dev/null || echo '?')）"
    [[ "$zig_ver" == "$HONK_ZIG_VERSION" ]] ||
        die "zig 版本不符：${zig_ver} != ${HONK_ZIG_VERSION}"
    bpf-linker --version >/dev/null 2>&1 ||
        die "bpf-linker 无法执行（架构不匹配？宿主机 $(uname -m)）"

    log "honk 工具链就绪：zig $(zig version) / bpf-linker $(bpf-linker --version 2>/dev/null | head -n 1) / $(cargo --version)"
}

ensure_honk_toolchain() {
    if ! honk_enabled; then
        log "未选中 honk（.config 里没有 CONFIG_PACKAGE_honk=y），跳过 honk 工具链"
        return 0
    fi

    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        . "$HOME/.cargo/env"
    fi

    # 逐项检查并记下具体原因：只说「缺少工具链」在 ARM 机器上根本定位不了问题
    # （装了错架构、rustup 没 source、PATH 里没有……表现都长一样）
    local why="" zig_ver=""

    if ! command -v cargo >/dev/null 2>&1; then
        why="${why}  - cargo 不在 PATH（rustup 已装但当前环境没 source ~/.cargo/env？）
"
    fi

    local bpf_out="" bpf_ver=""
    if ! command -v bpf-linker >/dev/null 2>&1; then
        why="${why}  - bpf-linker 未安装（PATH 里没有）
"
    elif ! bpf_out="$(bpf-linker --version 2>&1)"; then
        why="${why}  - bpf-linker 无法执行：$(command -v bpf-linker)
    原始回显：${bpf_out:-（无输出）}（架构装错？宿主机 $(uname -m)）
"
    else
        bpf_ver="$(printf '%s' "$bpf_out" | head -n 1)"
    fi

    local zig_out=""
    if ! command -v zig >/dev/null 2>&1; then
        why="${why}  - zig 未安装（PATH 里没有）
"
    elif ! zig_out="$(zig version 2>&1)"; then
        why="${why}  - zig 无法执行：$(command -v zig)
    原始回显：${zig_out:-（无输出）}（架构装错？宿主机 $(uname -m)）
"
    elif [[ "$zig_out" != "$HONK_ZIG_VERSION" ]]; then
        why="${why}  - zig 版本不符：${zig_out}（需要 ${HONK_ZIG_VERSION}，路径 $(command -v zig)）
"
    fi

    if [[ -z "$why" ]]; then
        zig_ver="$zig_out"
        log "honk 工具链已就绪：zig ${zig_ver} / ${bpf_ver} / $(cargo --version 2>/dev/null)"
        return 0
    fi

    local auto="$HONK_TOOLCHAIN_AUTO"
    if [[ -z "$auto" ]]; then
        if [[ -n "${GITHUB_ACTIONS:-}" ]] || sudo -n true 2>/dev/null; then
            auto=1
        else
            auto=0
        fi
    fi

    if [[ "$auto" != "1" ]]; then
        warn "选中了 honk，但宿主机工具链不完整："
        printf '%s' "$why" >&2
        if [[ -z "$HONK_TOOLCHAIN_AUTO" ]]; then
            printf '  （自动安装已跳过：非 CI 环境，且 sudo 需要密码；\n' >&2
            printf '   加 HONK_TOOLCHAIN_AUTO=1 让脚本自己装，或先 sudo -v 刷新凭据后重跑）\n' >&2
        else
            printf '  （HONK_TOOLCHAIN_AUTO=%s，已按设置跳过自动安装；设为 1 可让脚本自己装）\n' "$HONK_TOOLCHAIN_AUTO" >&2
        fi
        cat >&2 <<'EOF'
请手动安装（详见 openwrt-suite README「宿主机依赖（honk 核心专用）」）：
  # 按宿主机架构选资产（x86_64 / aarch64 都支持）
  ARCH=$(uname -m); case "$ARCH" in amd64) ARCH=x86_64 ;; arm64) ARCH=aarch64 ;; esac
  case "$ARCH" in x86_64) SHA=10f62ba9ab7e544d538370552660efcb4f1a19153d5752bbf0f6b51f3bada450 ;;
                  aarch64) SHA=d09ddd83303e9ab1443f51e0e284680154009646a3ce141c63d838ee61b73eb9 ;;
                  *) echo "unsupported arch: $ARCH"; return 1 ;; esac
  sudo apt-get install -y libbpf-dev cmake libclang-dev zstd xz-utils pkg-config
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  curl -fsSL -o /tmp/bpf-linker.tar.zst "https://github.com/aya-rs/bpf-linker/releases/download/v0.11.0/bpf-linker-${ARCH}-unknown-linux-musl.tar.zst"
  echo "$SHA  /tmp/bpf-linker.tar.zst" | sha256sum -c -
  sudo tar --zstd -xf /tmp/bpf-linker.tar.zst -C /usr/local/bin
  curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/0.14.1/zig-${ARCH}-linux-0.14.1.tar.xz"
  sudo tar -xJf /tmp/zig.tar.xz -C /usr/local
  sudo ln -sf "/usr/local/zig-${ARCH}-linux-0.14.1/zig" /usr/local/bin/zig
或设 HONK_TOOLCHAIN_AUTO=1 让本脚本自动安装（需要 sudo）。
EOF
        die "缺少 honk 构建工具链"
    fi

    install_honk_toolchain
}

download_sources() {
    log "下载编译所需源码（并行任务数：${JOBS}）"

    if ! make download -j"$JOBS"; then
        warn "并行下载失败，改为单线程重试以便定位问题"
        make download -j1 V=s || die "make download 失败，请检查网络或 dl/ 目录权限"
    fi

    # 体积异常小通常是下载失败/反代返回错误页
    local small
    small="$(find dl -type f -size -1024c -print 2>/dev/null | head -n 20 || true)"
    [[ -z "$small" ]] || warn "dl/ 中存在体积异常小的文件，建议检查：\n${small}"

    log "源码下载完成"
}

build() {
    log "开始编译 OpenWrt"
    log "并行任务数：$JOBS"
    log "编译目录：$(pwd)"

    if ! time make -j"$JOBS"; then
        warn "并行编译失败，改用单线程 + 详细日志重试以定位首个错误"
        warn "（这一步会复用已完成的产物，只继续失败的部分）"
        make -j1 V=s || die "编译失败，请根据上方单线程日志排查报错的包"
    fi

    log "OpenWrt 编译完成"
}

show_result() {
    log "固件输出目录：$(pwd)/bin/targets/"
    if [[ -d bin/targets ]]; then
        find bin/targets -maxdepth 3 -type f \
            \( -name '*.img*' -o -name '*.bin' -o -name '*.gz' -o -name '*.xz' -o -name '*.iso' \) \
            -print 2>/dev/null | sed 's/^/  /' || true
    else
        warn "未找到 bin/targets 目录，请确认编译是否真正产出固件"
    fi
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
OpenWrt 一键构建脚本（openwrt-suite 单源版）

用法：
  ./compile.sh [选项]

选项：
  -h, --help        显示本帮助
  -j, --jobs N      指定并行编译任务数（默认自动探测 CPU 核心数）
  -m, --menuconfig  只准备到可配置状态并打开 make menuconfig（更新源码/feeds、
                    安装第三方包、写入 .config），退出后可直接再运行本脚本编译

环境变量：
  WORKDIR           OpenWrt 源码目录（默认 $HOME/openwrt）
  OPENWRT_REPO      OpenWrt 主仓库地址
  SUITE_REPO        openwrt-suite 聚合仓库地址（第三方包 + .config 的唯一来源）
  SUITE_DIR         suite 本地克隆位置（默认 $WORKDIR/suite）
  CONFIG_URL        非空则从该 URL 下载 .config（临时覆盖 suite 快照，如试配置用）
  TARGET_SUBDIR     target/linux 下的子目录（默认 x86）
  KERNEL_CONFIG     手动指定内核配置文件路径（默认自动探测最新版本）
  GO_AMD64_LEVEL    GOAMD64 微架构级别（默认 v3，可选 v1/v2/v3/v4）
  HONK_TOOLCHAIN_AUTO / HONK_ZIG_VERSION / HONK_BPF_LINKER_VERSION
                    honk 核心的宿主机工具链（.config 选中 honk 才会用到；详见
                    suite README「宿主机依赖」一节）
  RUST_MAKEFILE     Rust Makefile 路径（默认 feeds/packages/lang/rust/Makefile）
  GOLANG_VALUES     golang-values.mk 路径（默认 feeds/packages/lang/golang/golang-values.mk）
  JOBS              并行任务数
  SKIP_UPDATE=1     跳过主仓库与 suite 仓库更新
  SKIP_DOWNLOAD=1   跳过 make download
  SKIP_BUILD=1       只做准备工作，不编译
  REFRESH_CONFIG=1  用 suite 快照覆盖本地 .config（默认 0 保留本地，含 menuconfig 改动）
  CLEAN_KERNEL=auto|1|0   内核配置变更后是否执行 make target/linux/clean
  CLEAN_GOLANG=auto|1|0   GO_AMD64 变更后是否执行 make package/feeds/packages/golang/clean

说明：第三方组件全部来自 openwrt-suite 聚合仓库（每日自动同步上游，快照版本
      记录在其 sources.lock 中）；官方 feed 同名包由 feeds.conf 顺序保证使用
      suite 版本；Rust/Golang/内核三处现场补丁由 suite 仓库 diy/ 脚本处理。
EOF
}

main() {
    while (($# > 0)); do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -j|--jobs)
                [[ $# -ge 2 ]] || die "--jobs 需要一个数字参数"
                JOBS="$2"
                shift 2
                ;;
            -m|--menuconfig) MENUCONFIG_ONLY=1; shift ;;
            *) die "未知参数：$1（使用 --help 查看用法）" ;;
        esac
    done

    check_env
    prepare_source
    prepare_suite
    configure_feeds
    update_feeds
    verify_feed_priority
    feed_patches
    prepare_config
    ensure_honk_toolchain
    kernel_patches
    clean_stale_artifacts

    # --menuconfig: 准备完就打开配置界面，供手工勾选第三方包
    if [[ "$MENUCONFIG_ONLY" == "1" ]]; then
        log "第三方包已全部安装到 package/feeds/，打开 make menuconfig"
        log "提示：在 LuCI / Network / Utilities 等菜单下可找到 suite 提供的包"
        log "选完保存退出后，直接重新运行本脚本（不加 --menuconfig）即可按新配置编译"
        make menuconfig
        log "menuconfig 已退出，构建准备完成"
        exit 0
    fi

    if [[ "$SKIP_DOWNLOAD" == "1" ]]; then
        log "SKIP_DOWNLOAD=1，跳过源码下载"
    else
        download_sources
    fi

    if [[ "$SKIP_BUILD" == "1" ]]; then
        log "SKIP_BUILD=1，跳过编译"
    else
        build
        show_result
    fi

    log "脚本执行结束"
}

# 仅在直接执行时进入主流程（被 source 时可单独调用其中的函数做测试）
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
