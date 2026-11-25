#!/usr/bin/env bash
#
# diy/02-kernel-config.sh — 内核配置补丁（在 .config 就绪后、编译前执行）
#
# 作用: 修改 OpenWrt 主仓库 target/linux/<TARGET>/config-<版本> 中的内核选项。
#       这些文件属于 OpenWrt 主仓库，无法聚合进 suite 仓库，只能构建时现场修改：
#   1. CONFIG_NETKIT=y                      （启用 netkit，airplay2/dae 等需要的虚拟网络设备）
#   2. # CONFIG_X86_NATIVE_CPU is not set   （不用 -march=native，保证 GOAMD64=v3 一致性）
#   3. # CONFIG_X86_SGX is not set          （关闭 SGX，i7-4600U 无此功能）
#
# 用法: bash diy/02-kernel-config.sh <openwrt 源码目录>
# 环境变量:
#   TARGET_SUBDIR   target/linux 下的子目录（默认 x86）
#   KERNEL_CONFIG   手动指定内核配置文件路径（默认自动探测最新版本）
# 说明: KERNEL_OPTIONS 是脚本内置的固定清单（见下方数组），不从环境变量读取 ——
#       这些选项跟内核版本和目标硬件绑定，需要改时直接改数组。
#
# 状态输出: 追加写入 <openwrt>/.suite-diy-state.env（KERNEL_CHANGED）
#

set -Eeuo pipefail
export LC_ALL=C LANG=C

OW="${1:-$PWD}"
[[ -d "$OW" ]] || { echo "[02-kernel-config] 目录不存在：$OW" >&2; exit 1; }
cd "$OW"

TARGET_SUBDIR="${TARGET_SUBDIR:-x86}"
KERNEL_CONFIG="${KERNEL_CONFIG:-}"
STATE_FILE="$OW/.suite-diy-state.env"

# 环境输入必须是构建树内的相对路径，避免读写任意系统文件
safe_rel() {
    case "$1" in ''|/*|*'..'*|*'\'*|*'|'*|*';'*|*'&'*|*'$'*|*'`'*) return 1 ;; esac
    return 0
}
[[ "$TARGET_SUBDIR" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] ||
    { echo "[02-kernel-config] TARGET_SUBDIR 不合法：$TARGET_SUBDIR" >&2; exit 1; }
if [[ -n "$KERNEL_CONFIG" ]]; then
    safe_rel "$KERNEL_CONFIG" ||
        { echo "[02-kernel-config] KERNEL_CONFIG 必须是构建树内的相对路径" >&2; exit 1; }
fi

# 内置清单，不读环境变量（与上方「环境变量」说明一致）
KERNEL_OPTIONS=(
    "NETKIT|CONFIG_NETKIT=y"
    "X86_NATIVE_CPU|# CONFIG_X86_NATIVE_CPU is not set"
    "X86_SGX|# CONFIG_X86_SGX is not set"
)

# 自动探测最新版本的内核配置文件
detect_kernel_config() {
    local dir="target/linux/${TARGET_SUBDIR}" best="" f ver best_ver=0
    [[ -d "$dir" ]] || { echo "[02-kernel-config] 找不到内核配置目录：$dir" >&2; return 1; }
    for f in "$dir"/config-*; do
        [[ -f "$f" ]] || continue
        ver="${f##*config-}"
        [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
        if [[ "$ver" =~ ^([0-9]+)(\.([0-9]+))? ]]; then
            local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[3]:-0}"
            local score=$((major * 1000 + minor))
            if ((score >= best_ver)); then
                best_ver=$score
                best="$f"
            fi
        fi
    done
    [[ -n "$best" ]] || { echo "[02-kernel-config] 在 $dir 下未找到任何 config-<版本> 文件" >&2; return 1; }
    printf '%s\n' "$best"
}

set_kernel_config() {
    local key="$1" value="$2" file="$3" tmp count
    [[ -f "$file" && ! -L "$file" ]] ||
        { echo "[02-kernel-config] 配置文件不存在或为符号链接：$file" >&2; return 1; }
    count="$(grep -cE "^(CONFIG_${key}=|# CONFIG_${key} is not set$)" "$file" || true)"
    if [[ "$count" == "1" ]] && grep -qxF -- "$value" "$file"; then
        echo "[02-kernel-config] 内核配置 ${key} 已是目标值，跳过"
        return 1
    fi
    tmp="$(mktemp "${TMPDIR:-/tmp}/suite-kernel-config.XXXXXX")" || return 1
    if ! awk -v key="$key" '
        $0 ~ "^CONFIG_" key "="                 { next }
        $0 ~ "^# CONFIG_" key " is not set$"    { next }
        { print }
    ' "$file" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
    printf '%s\n' "$value" >> "$tmp"
    if ! cat -- "$tmp" > "$file"; then rm -f -- "$tmp"; return 1; fi
    rm -f -- "$tmp"
    echo "[02-kernel-config] 已写入：${value}"
    return 0
}

KERNEL_CHANGED=0

[[ -n "$KERNEL_CONFIG" ]] || KERNEL_CONFIG="$(detect_kernel_config)"
[[ -f "$KERNEL_CONFIG" ]] || { echo "[02-kernel-config] 找不到内核配置文件：$KERNEL_CONFIG" >&2; exit 1; }
echo "[02-kernel-config] 内核配置文件：$KERNEL_CONFIG"

for item in "${KERNEL_OPTIONS[@]}"; do
    key="${item%%|*}"
    value="${item#*|}"
    if set_kernel_config "$key" "$value" "$KERNEL_CONFIG"; then
        KERNEL_CHANGED=1
    fi
done

# 校验：必须所有目标配置都恰好出现一次，否则直接失败（不再只发警告）
echo "[02-kernel-config] 内核配置校验结果："
for item in "${KERNEL_OPTIONS[@]}"; do
    key="${item%%|*}"
    value="${item#*|}"
    hits="$(grep -cxF -- "$value" "$KERNEL_CONFIG" || true)"
    [[ "$hits" == "1" ]] ||
        { echo "[02-kernel-config] [错误] $key 校验失败（匹配 $hits 次）：$value" >&2; exit 1; }
    grep -nxF -- "$value" "$KERNEL_CONFIG" | sed 's/^/    /'
done

# 追加状态（保留 01 脚本写入的 RUST/GOLANG 状态）
[[ ! -L "$STATE_FILE" ]] ||
    { echo "[02-kernel-config] 状态文件是符号链接，拒绝写入：$STATE_FILE" >&2; exit 1; }
printf 'KERNEL_CHANGED=%s\n' "$KERNEL_CHANGED" >> "$STATE_FILE"
echo "[02-kernel-config] 完成（状态追加至 $STATE_FILE）"
