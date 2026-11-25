#!/usr/bin/env bash
#
# diy/00-feeds-order.sh — feeds 顺序（在 ./scripts/feeds update 之前执行）
#
# 作用: 把 suite feed 插到 feeds 配置的【最前面】。
#       OpenWrt 的 feeds install -a 对同名包按 feeds.conf 中的出现顺序取先到者，
#       官方 packages feed 里也有 nqptp / v2ray-geodata / ddns-go 等同名包，
#       suite 排在最前即可保证全部用本仓库的版本 —— 原 compile.sh 里
#       「卸载官方 nqptp 再 -p 强装」「删除官方 v2ray-geodata 源」两个特判
#       因此不再需要。
#
# 用法: bash diy/00-feeds-order.sh <openwrt 源码目录>
# 环境变量:
#   SUITE_REPO   本仓库地址（默认 NetForgeCN/openwrt-suite）
#   SUITE_DIR    本仓库的本地 checkout 目录。指向有效 suite 仓库时改用 src-link
#                挂载其 packages/（同提交构建，不再联网克隆远端 main）；
#                未设置时自动识别脚本所在的 suite 仓库，识别不到才回退 src-git。
#                显式指定 SUITE_DIR 始终优先。
#   FEED_NAME    feed 名（默认 suite，勿与官方 packages/luci/routing/telephony 重名）
#

set -Eeuo pipefail
export LC_ALL=C LANG=C

OW="${1:-$PWD}"
SUITE_REPO="${SUITE_REPO:-https://github.com/NetForgeCN/openwrt-suite.git}"
FEED_NAME="${FEED_NAME:-suite}"

die() { echo "[00-feeds-order] $*" >&2; exit 1; }

# 环境变量来自调用方：先做白名单校验，禁止把 shell/make 元字符注入 feeds.conf
[[ "$FEED_NAME" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || die "FEED_NAME 不合法：$FEED_NAME"
case "$SUITE_REPO" in
    https://*) case "$SUITE_REPO" in *@*|*'?'*|*'#'*) die "SUITE_REPO 不得含凭据/查询串" ;; esac ;;
    *) die "SUITE_REPO 必须是 HTTPS URL：$SUITE_REPO" ;;
esac

# 从本仓库里直接调用（手工接入的常见用法）时，自动识别脚本所在的 suite 仓库，
# 不必额外设 SUITE_DIR 就能用 src-link 挂本地 packages/。把脚本单独复制到别处
# 执行时识别失败，回退 src-git，行为与旧版一致。
SUITE_DIR="${SUITE_DIR:-}"
if [[ -z "$SUITE_DIR" ]]; then
    SUITE_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
    if [[ -d "$SUITE_SELF_DIR/packages" && -f "$SUITE_SELF_DIR/sources.conf" ]]; then
        SUITE_DIR="$SUITE_SELF_DIR"
    fi
fi

[[ -d "$OW" ]] || { echo "[00-feeds-order] 目录不存在：$OW" >&2; exit 1; }

# feeds.conf 存在则优先（OpenWrt 用它覆盖 feeds.conf.default）
conf="feeds.conf"
[[ -f "$OW/$conf" ]] || conf="feeds.conf.default"
file="$OW/$conf"
[[ -f "$file" ]] || { echo "[00-feeds-order] 找不到 $file" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 决定 feed 类型：能用本地 checkout 就绝不去克隆远端
#
# 若这里一律写 src-git <URL>，feeds update -a 会重新克隆远端默认分支。CI 里
# workflow 已经 checkout 了本次提交（脚本 / packages/ 快照 / config/dot.config
# 都来自它），但 feed 里的包却可能来自另一个提交 —— 尤其 daily-sync 刚推过
# 新快照时。用 src-link 指向本地目录可保证「构建用的就是本次检出」。
#
# OpenWrt scripts/feeds 对 src-link 的支持：update -a 会执行
#   rm -rf feeds/<name>; ln -s <src> feeds/<name>
# 并照常生成 feeds/<name>.index；scan.mk 用 find -L 跟随符号链接，
# feeds install -a 的建链与索引行为与 src-git 完全一致。
#
# 注意：不能把整个 SUITE_DIR 直接挂成 feed。scan.mk 是 find -L 递归扫整个
# feed 目录，而 SUITE_DIR 往往就在构建树里/旁边（CI 里 WORKDIR 是它的子目录），
# 那样会把构建树上万个 Makefile 一起扫成「suite 的包」，还会经
# openwrt/feeds/suite 自引用形成符号链接环。这里只暴露 packages/ 一层：
# 建一个干净目录，里面放一个指向 SUITE_DIR/packages 的软链。
# ---------------------------------------------------------------------------
feed_type="src-git"
feed_src="$SUITE_REPO"
if [[ -n "${SUITE_DIR:-}" && -d "$SUITE_DIR/packages" && -f "$SUITE_DIR/sources.conf" ]]; then
    feed_type="src-link"
    suite_packages="$(cd "$SUITE_DIR/packages" && pwd -P)" || die "无法解析 SUITE_DIR/packages"
    [[ -n "$suite_packages" ]] || die "SUITE_DIR/packages 路径无效"
    link_root="$OW/feeds/.suite-local"
    mkdir -p "$link_root"
    ln -sfn "$suite_packages" "$link_root/packages"
    feed_src="$(cd "$link_root" && pwd -P)"
    echo "[00-feeds-order] 检测到本地 suite 仓库：$SUITE_DIR"
    echo "[00-feeds-order] 使用 src-link 挂载（与本次检出同提交，不克隆远端 main）"
    echo "[00-feeds-order] feed 根目录：$feed_src（仅暴露 packages/ -> $suite_packages）"
fi

# 幂等：先删除任何已存在的 suite 行（旧位置/重复行/另一种 feed 类型一并清掉）
tmp="$(mktemp "${TMPDIR:-/tmp}/suite-feeds.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT
awk -v feed="$FEED_NAME" '
    $0 ~ ("^[[:space:]]*src-(git|link)[[:space:]]+" feed "[[:space:]]") { next }
    { print }
' "$file" > "$tmp"

# 插入为第一条 feed（注释行沉到后面没关系，feeds 解析跳过注释）
printf '%s %s %s\n' "$feed_type" "$FEED_NAME" "$feed_src" | cat - "$tmp" > "$file"
rm -f -- "$tmp"

# 校验：suite 必须是文件中第一条 src-* 行（用 awk 而非 grep|head，
# 避免 pipefail 下 grep 被 head 截断时触发 SIGPIPE 让脚本误判失败）
first="$(awk '/^[[:space:]]*src-[a-z-]+[[:space:]]/ { print; exit }' "$file")"
grep -qE "^[[:space:]]*src-(git|link)[[:space:]]+${FEED_NAME}[[:space:]]" <<<"$first" ||
    { echo "[00-feeds-order] 插入后校验失败：$file" >&2; exit 1; }

echo "[00-feeds-order] $FEED_NAME 已置于 $conf 首位（同名包优先用本仓库版本）："
echo "    $first"
