# openwrt-suite

OpenWrt 第三方组件**单一聚合 feed 仓库**：把 18 个常用第三方包 + 一份固件 `.config`
统一收进本仓库，每日由 GitHub Actions 从各上游同步（纯快照方式），构建时只需拉取
这一个源。

## 仓库结构

```
openwrt-suite/
├── packages/          18 个包（feed 主体，OpenWrt 递归扫描含 Makefile 的目录）
├── config/
│   └── dot.config     固件 .config 快照（跟随 NetForgeCN/OpenWRT main 分支）
├── sources.conf       上游同步映射表（源地址、分支、路径映射模式）
├── sources.lock       最近一次同步对应的上游 commit（版本可追溯 / 构建可复现）
├── meta/              多包上游的许可证文件副本（许可证随快照保留）
├── patches/
│   └── geodata.sh     v2ray-geodata 同步后补丁（GEOIP_URL 改用全量 geoip.dat）
├── diy/               构建期现场脚本（聚合不进 feed 的部分）
│   ├── 00-feeds-order.sh    feeds.conf 顺序：suite 置于官方 feeds 之前
│   ├── 01-feed-patches.sh   官方 packages feed 补丁（Rust LLVM / Golang GOAMD64）
│   └── 02-kernel-config.sh  内核配置补丁（NETKIT / X86_NATIVE_CPU / X86_SGX）
├── build/
│   └── compile.sh     一键构建脚本（单源版）
└── scripts/
    ├── sync.sh        同步脚本（本地 / CI 共用）
    └── validate.sh    结构校验（每个包目录必须有 Makefile、无 .git 残留等）
```

## 使用方法

### 方式一：一键构建（推荐）

```bash
git clone https://github.com/NetForgeCN/openwrt-suite.git
bash openwrt-suite/build/compile.sh
```

脚本自动完成：克隆/更新 OpenWrt → 克隆 suite → 配置 feeds → `feeds update/install` →
打官方 feed 补丁 → 写入 `.config` → 打内核补丁 → 下载 → 编译。
常用变量：`WORKDIR`（默认 `~/openwrt`）、`JOBS`、`SKIP_BUILD=1`（只准备不编译）。

### 方式二：接入已有构建

在 `./scripts/feeds update -a` 之前执行：

```bash
bash openwrt-suite/diy/00-feeds-order.sh <你的 openwrt 目录>
./scripts/feeds update -a
./scripts/feeds install -a
bash openwrt-suite/diy/01-feed-patches.sh <你的 openwrt 目录>
# .config 直接用 config/dot.config
bash openwrt-suite/diy/02-kernel-config.sh <你的 openwrt 目录>
```

## 关键设计

### feeds 顺序与包名冲突

OpenWrt 的 `feeds install -a` 对同名包按 feeds.conf 中的**出现顺序**取先到者。
官方 packages feed 也有 `nqptp`、`v2ray-geodata`、`ddns-go` 等同名包，
`diy/00-feeds-order.sh` 把 `src-git suite ...` 插到所有官方 feed 之前，
因此 nqptp（luci-app-airplay2 依赖）、v2ray-geodata 始终使用本仓库版本，
无需任何卸载/删除特判。

### 纯快照同步

`scripts/sync.sh` 每次对每个源**先删后拷**（不 rsync 增量、不带 .git），
路径映射由 `sources.conf` 显式声明三种模式：

| 模式 | 适用 | 例子 |
|---|---|---|
| `pkg`  | 一个上游仓库含多个包目录 | sirpdboy/luci-app-ddns-go → `luci-app-ddns-go/` + `ddns-go/` |
| `all`  | Makefile 在仓库根目录 | jerrykuku/luci-theme-argon → `luci-theme-argon/` |
| `file` | 大仓库里的单个文件 | NetForgeCN/OpenWRT 的 `.config` → `config/dot.config` |

每个源同步后强制校验 `Makefile` 存在，任何失配（上游重构、删库、改默认分支）
都会让同步失败报红，绝不静默产出坏快照。每次同步把上游 commit 记入 `sources.lock`。

### v2ray-geodata 的处理

同步源用 [NetForgeCN/Loyalsoldier](https://github.com/NetForgeCN/Loyalsoldier) 这个
fork 的源头 [sbwml/v2ray-geodata](https://github.com/sbwml/v2ray-geodata)，同步后由
`patches/geodata.sh` 重打 fork 中的定制（`GEOIP_URL` 改用全量 `geoip.dat`）。
上游 Makefile 结构变化导致补丁失配时同步会报红，提示人工更新补丁。

### 版本锁定与可复现

构建用的所有第三方代码严格等于本仓库快照；每个快照对应的上游 commit 记录在
`sources.lock`，可追溯、可回滚（git 历史），上游删库 / force-push / 投毒
均不影响已发布的快照。

## 手动触发同步

- GitHub 仓库页 → Actions → daily-sync → Run workflow；或
- 本地执行：`bash scripts/sync.sh`（之后自行 commit / push）

调试单个源：`SUITE_SYNC_ONLY=geodata bash scripts/sync.sh`

## 许可证

各包许可证**原样保留**：`mode=all` 的包 LICENSE 在包目录内；`mode=pkg` 的多包上游
其 LICENSE / THIRD-PARTY-NOTICES 副本收于 `meta/<slug>/`。本仓库不对任何上游代码
做修改，唯一的例外是 `patches/geodata.sh` 声明的 GEOIP_URL 一行定制。
