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
#   KERNEL_OPTIONS  要设定的内核选项，格式 "KEY|value"，空格分隔多项
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
    count="$(grep -cE "^(CONFIG_${key}=|# CONFIG_${key} is not set$)" "$file" || true)"
    if [[ "$count" == "1" ]] && grep -qxF -- "$value" "$file"; then
        echo "[02-kernel-config] 内核配置 ${key} 已是目标值，跳过"
        return 1
    fi
    tmp="$(mktemp)"
    awk -v key="$key" '
        $0 ~ "^CONFIG_" key "="                 { next }
        $0 ~ "^# CONFIG_" key " is not set$"    { next }
        { print }
    ' "$file" > "$tmp"
    printf '%s\n' "$value" >> "$tmp"
    cat -- "$tmp" > "$file"
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

# 校验
echo "[02-kernel-config] 内核配置校验结果："
grep -nE '^(CONFIG_NETKIT=y|# CONFIG_X86_NATIVE_CPU is not set|# CONFIG_X86_SGX is not set)$' \
    "$KERNEL_CONFIG" ||
    echo "[02-kernel-config] [警告] 未能校验到全部目标配置" >&2

# 追加状态（保留 01 脚本写入的 RUST/GOLANG 状态）
printf 'KERNEL_CHANGED=%s\n' "$KERNEL_CHANGED" >> "$STATE_FILE"
echo "[02-kernel-config] 完成（状态追加至 $STATE_FILE）"
