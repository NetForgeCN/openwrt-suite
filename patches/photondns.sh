#!/usr/bin/env bash
#
# photondns 同步后补丁：把仓库根的 Cargo 工程 stage 进 photondns 包目录
#
# 为什么不直接改上游 Makefile：
#   上游 openwrt/photondns/Makefile 用 RustBinPackage，编译的是「包目录里的」
#   Cargo 工程（`cargo install --path $(PKG_BUILD_DIR)`，而默认 Build/Prepare 会把
#   包目录下的 ./src/* 拷进构建目录）。可是包里只有 Makefile + root/，真正的
#   Cargo.toml / Cargo.lock / build.rs / src/ 都在仓库根目录 —— 直接构建必然报
#   "could not find `Cargo.toml` in ... or any parent directory"。
#
# 所以这里按 OpenWrt 的 in-tree 惯例把工程摆成：
#   packages/photondns/src/{Cargo.toml,Cargo.lock,build.rs,src/}
# 默认 Prepare 的 `cp ./src/* 构建目录/` 正好把 Cargo.toml 放到构建目录根，
# 其余文件相对结构不变，cargo 就能正常识别工程。
#
# 调用方式（由 scripts/sync.sh 负责）：
#   SUITE_SRC_DIR=<上游克隆> patches/photondns.sh <包目录>    # 每个映射目录各一次
#
set -Eeuo pipefail

dest="${1:?用法: patches/photondns.sh <包目录>}"
src="${SUITE_SRC_DIR:-}"

# 这个源有三个包目录，只有 photondns 需要动
[[ "$(basename "$dest")" == "photondns" ]] || exit 0

[[ -n "$src" && -d "$src" ]] || {
	echo "photondns.sh: 缺少 SUITE_SRC_DIR（应由 scripts/sync.sh 传入）" >&2
	exit 1
}

# 上游结构校验：任何一项缺失都说明仓库布局变了，直接报错让 CI 红
for f in Cargo.toml Cargo.lock build.rs src src/main.rs; do
	[[ -e "$src/$f" ]] || {
		echo "photondns.sh: 上游缺少 $f —— 仓库结构变了，请更新本补丁" >&2
		exit 1
	}
done

mkdir -p "$dest/src"
rm -rf "$dest/src/src"
cp -a "$src/Cargo.toml" "$src/Cargo.lock" "$src/build.rs" "$dest/src/"
cp -a "$src/src" "$dest/src/src"

# 自检：stage 之后的结果必须能被 cargo 直接吃
[[ -f "$dest/src/Cargo.toml" ]] || { echo "photondns.sh: Cargo.toml 未就位" >&2; exit 1; }
[[ -f "$dest/src/src/main.rs" ]] || { echo "photondns.sh: src/main.rs 未就位" >&2; exit 1; }
grep -q '^name = "photondns"' "$dest/src/Cargo.toml" || {
	echo "photondns.sh: Cargo.toml 里的包名不是 photondns" >&2
	exit 1
}

# 说明：Cargo.toml 里除了 photondns 还声明了 4 个 bench 用的 bin，cargo install
# 会一并编译（LTO + codegen-units=1，比较慢），但它们的产物不会进包。如果哪天
# 觉得编译太耗时，可以在上游 Makefile 里改成
#   Build/Compile=$(call Build/Compile/Cargo,,--bin photondns)
# 用本补丁改写也可以，但会偏离上游，先不动。
echo "photondns.sh: Cargo 工程已 stage 到 $(basename "$dest")/src/（$(du -sh "$dest/src" | cut -f1)）"
