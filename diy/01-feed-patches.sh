#!/usr/bin/env bash
#
# diy/01-feed-patches.sh — 官方 packages feed 补丁（在 feeds install -a 之后执行）
#
# 作用: 修改官方 packages feed 里的两个文件（这部分内容在官方 feed 仓库中，
#       无法聚合进 suite 仓库，只能在构建树上现场打补丁）：
#   1. Rust: --set=llvm.download-ci-llvm 改为 true（下载 CI 构建的 LLVM，大幅缩短 Rust 编译）
#   2. Golang: GO_AMD64 微架构级别（默认 v3，可用 GO_AMD64_LEVEL 覆盖为 v1/v2/v3/v4）
#
# 用法: bash diy/01-feed-patches.sh <openwrt 源码目录>
# 环境变量:
#   RUST_MAKEFILE    Rust Makefile 相对路径（默认 feeds/packages/lang/rust/Makefile）
#   GOLANG_VALUES    golang-values.mk 相对路径（默认 feeds/packages/lang/golang/golang-values.mk）
#   GO_AMD64_LEVEL   目标微架构级别（默认 v3）
#
# 状态输出: 写入 <openwrt>/.suite-diy-state.env（RUST_CHANGED / GOLANG_CHANGED），
#           供 compile.sh 决定是否清理对应构建缓存。
#

set -Eeuo pipefail
export LC_ALL=C LANG=C

OW="${1:-$PWD}"
[[ -d "$OW" ]] || { echo "[01-feed-patches] 目录不存在：$OW" >&2; exit 1; }
cd "$OW"

RUST_MAKEFILE="${RUST_MAKEFILE:-feeds/packages/lang/rust/Makefile}"
GOLANG_VALUES="${GOLANG_VALUES:-feeds/packages/lang/golang/golang-values.mk}"
GO_AMD64_LEVEL="${GO_AMD64_LEVEL:-v3}"
STATE_FILE="$OW/.suite-diy-state.env"

RUST_CHANGED=0
GOLANG_CHANGED=0

# 可移植原地修改（BSD/GNU 通用，不用 sed -i）
sed_inplace() {
    local expr="$1" file="$2" tmp
    [[ -f "$file" ]] || { echo "[01-feed-patches] 文件不存在：$file" >&2; return 1; }
    tmp="$(mktemp)"
    sed -E "$expr" "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    cat -- "$tmp" > "$file"
    rm -f -- "$tmp"
}

# ---------------------------------------------------------------- Rust LLVM
echo "[01-feed-patches] 检查 Rust LLVM 下载配置"
if [[ -f "$RUST_MAKEFILE" ]]; then
    if grep -qF -- '--set=llvm.download-ci-llvm=true' "$RUST_MAKEFILE"; then
        echo "[01-feed-patches] Rust LLVM 下载参数已经是 true"
    elif grep -qE -- '--set=llvm\.download-ci-llvm=(falst|false)' "$RUST_MAKEFILE"; then
        # 上游曾出现过 falst 拼写错误，一并兼容
        sed_inplace \
            's/--set=llvm\.download-ci-llvm=(falst|false)/--set=llvm.download-ci-llvm=true/g' \
            "$RUST_MAKEFILE"
        echo "[01-feed-patches] 已将 Rust LLVM 下载参数修改为 true"
        RUST_CHANGED=1
    else
        echo "[01-feed-patches] [警告] 没有找到预期的 Rust LLVM 参数，请检查：$RUST_MAKEFILE" >&2
    fi
else
    echo "[01-feed-patches] [警告] 找不到 Rust Makefile：$RUST_MAKEFILE，跳过" >&2
fi

# ---------------------------------------------------------------- Golang GO_AMD64
echo "[01-feed-patches] 检查 Golang GO_AMD64 设置（目标值：${GO_AMD64_LEVEL}）"
if [[ -f "$GOLANG_VALUES" ]]; then
    lines="$(grep -nE '^[[:space:]]*GO_AMD64[[:space:]]*[:?]?=' "$GOLANG_VALUES" || true)"
    if [[ -n "$lines" ]]; then
        echo "$lines" | sed 's/^/    /'
        if grep -qE "^[[:space:]]*GO_AMD64[[:space:]]*[:?]?=[[:space:]]*${GO_AMD64_LEVEL}[[:space:]]*$" \
            "$GOLANG_VALUES"; then
            echo "[01-feed-patches] GO_AMD64 已经是 ${GO_AMD64_LEVEL}，无需修改"
        else
            # 保留原有缩进，覆盖任意赋值符（:= / ?= / =）
            sed_inplace \
                "s/^([[:space:]]*GO_AMD64)[[:space:]]*[:?]?=.*\$/\1:=${GO_AMD64_LEVEL}/" \
                "$GOLANG_VALUES"
            after="$(grep -nE "^[[:space:]]*GO_AMD64[[:space:]]*:=[[:space:]]*${GO_AMD64_LEVEL}[[:space:]]*\$" \
                "$GOLANG_VALUES" || true)"
            [[ -n "$after" ]] ||
                { echo "[01-feed-patches] [错误] GO_AMD64 修改失败，请检查 $GOLANG_VALUES" >&2; exit 1; }
            echo "$after" | sed 's/^/    /'
            echo "[01-feed-patches] GO_AMD64 已设置为 ${GO_AMD64_LEVEL}"
            GOLANG_CHANGED=1
        fi
    else
        echo "[01-feed-patches] [警告] 在 $GOLANG_VALUES 中未找到 GO_AMD64 赋值行，请手动确认" >&2
    fi
else
    echo "[01-feed-patches] [警告] 找不到 golang-values.mk：$GOLANG_VALUES，跳过" >&2
fi

# ---------------------------------------------------------------- 状态输出
printf 'RUST_CHANGED=%s\nGOLANG_CHANGED=%s\n' "$RUST_CHANGED" "$GOLANG_CHANGED" > "$STATE_FILE"
echo "[01-feed-patches] 完成（状态写入 $STATE_FILE）"
