# openwrt-suite

OpenWrt 第三方组件**单一聚合 feed 仓库**：把 20 个第三方包（22 个包源目录，含
argon 自带的 `compat/luci-app-argon-config` 与 oxidns 自带的 `oxidns-core` 两个
嵌套子包）+ 一份固件 `.config` 统一收进本仓库，每日由 GitHub Actions 从各上游
同步（纯快照方式）。使用时**只需克隆本仓库**，第三方包就会出现在 `make menuconfig` 里。

## 仓库结构

```
openwrt-suite/
├── packages/          20 个包（feed 主体，OpenWrt 递归扫描含 Makefile 的目录）
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

### 方式一：只克隆本仓库 → menuconfig 勾选 → 编译（推荐）

```bash
# 1) 克隆这一个仓库
git clone https://github.com/NetForgeCN/openwrt-suite.git

# 2) 准备到可配置状态（会自动克隆 OpenWrt 主仓库、配置 feeds、安装全部第三方包），
#    然后直接打开 make menuconfig
bash openwrt-suite/build/compile.sh --menuconfig

# 3) 在 menuconfig 里勾选需要的包，保存退出后开始编译
bash openwrt-suite/build/compile.sh
```

第 2 步完成后，20 个第三方包已全部出现在 `make menuconfig` 中，且
`config/dot.config` 里原有的选择会自动勾选好：16 个包 + `v2ray-geoip` /
`v2ray-geosite`（v2ray-geodata 源里的实际数据包，`v2ray-geodata` 本身是虚包）。

这些包在 menuconfig 中的位置：

| 菜单路径 | 包 |
|---|---|
| LuCI → Applications | luci-app-airplay2、luci-app-dae、luci-app-ddns-go、luci-app-diskman、luci-app-honk、luci-app-kixdns、luci-app-oxidns、luci-app-pulse、luci-app-temp-status |
| LuCI → Themes | luci-theme-argon |
| Network | dae、ddns-go、kixdns、kixdns-stats、nqptp、open-nexttrace-core、v2ray-geodata |
| Network → Web Servers/Proxies | honk（eBPF 核心，仅 x86_64 / aarch64_generic） |
| LuCI | luci-app-open_nexttrace（该包 CATEGORY 直接声明为 LuCI） |
| Sound | airplay2 |

> 自己的配置改动只留在本地 `.config`，不会被覆盖；想强制回到仓库快照版本时用
> `REFRESH_CONFIG=1`（旧配置会自动备份）。想临时试另一份配置（比如对比测试），
> 用 `CONFIG_URL=<url>` 指定，仅当次生效、不改变快照。

### 方式一（等价的手工版）

不想用脚本，就是三条命令：

```bash
git clone https://github.com/openwrt/openwrt.git && cd openwrt
echo 'src-git suite https://github.com/NetForgeCN/openwrt-suite.git' | cat - feeds.conf.default > t && mv t feeds.conf.default
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig
```

`src-git suite` 必须在**第一条**（官方 feed 之前），否则官方同名包会抢先。

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

## 原理：克隆之后到底发生了什么

```
git clone 本仓库  ──►  一个标准 OpenWrt feed（顶层 packages/ 里每个目录 = 一个包）
                              │
              feeds.conf 一行 src-git suite <url>
                              │
   ./scripts/feeds update -a  ──►  克隆到 feeds/suite/
   ./scripts/feeds install -a ──►  在 package/feeds/suite/ 下为每个包建符号链接
                              │
        OpenWrt 的包扫描（include/scan.mk）递归查找所有含 Makefile
        且调用 BuildPackage 的目录 ──► 生成包索引 tmp/.packageinfo
                              │
                     make menuconfig 读取索引 ──► 菜单里可勾选
```

四个关键事实（均已对本仓库实测/源码核对）：

1. **扫描是递归的**：`scan.mk` 用 `find -L $(SCAN_DIR) -name Makefile`，没有
   `maxdepth` 限制，所以 `feeds/suite/packages/<包名>/` 这种多一层嵌套完全没问题
   （官方 packages feed 本身就是 `lang/`、`net/` 这种嵌套结构）。
2. **包路径无关紧要**：本仓库所有 Makefile 都用 `$(TOPDIR)` / `$(INCLUDE_DIR)`
   绝对引用，没有一处相对路径 `include`，因此放在哪一层都能正常解析。
3. **同名包由 feeds 顺序决定**：`scripts/feeds` 的 `install -a` 按 feeds.conf
   顺序遍历，已安装过的源包名直接跳过 —— 谁排在前面谁生效。把 suite 放第一条，
   nqptp / v2ray-geodata / ddns-go / dae 就用本仓库版本。
   *（不要用 `git clone 到 package/suite` 的方式接入：`scan.awk` 会让 feed 版本
   覆盖 `package/` 下的同名包，反而变成官方版赢。）*
4. **`.config` 只是初始建议值**：首次准备时从 `config/dot.config` 写入，之后
   menuconfig 的改动保留在本地，不会每次被覆盖。

### 一键构建

```bash
bash openwrt-suite/build/compile.sh
```

脚本自动完成：克隆/更新 OpenWrt → 克隆 suite → 配置 feeds → `feeds update/install` →
打官方 feed 补丁 → 写入 `.config` → 打内核补丁 → 下载 → 编译。
常用变量：`WORKDIR`（默认 `~/openwrt`）、`JOBS`、`SKIP_BUILD=1`（只准备不编译）。

## 关键设计

### feeds 顺序与包名冲突

OpenWrt 的 `feeds install -a` 对同名包按 feeds.conf 中的**出现顺序**取先到者。
官方 packages feed 也有 `nqptp`、`v2ray-geodata`、`ddns-go`、`dae` 等同名包，
`diy/00-feeds-order.sh` 把 `src-git suite ...` 插到所有官方 feed 之前，
因此这些包始终使用本仓库版本，无需任何卸载/删除特判。

**外加一道保险**：`scripts/feeds` 的 `install -a` 会跳过「已安装」的源包名，
所以旧构建树里残留的官方版本链接**不会被自动纠正**。`compile.sh` 在每个包安装后
会逐包解析 `package/feeds/*/` 链接的真实指向：凡是指向非 `feeds/suite` 的（包括
悬空的旧链接），一律清掉并从 suite 重装，最后再复核一遍，不一致直接报错退出。

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

### honk 的处理

上游 [QiuSimons/luci-app-honk](https://github.com/QiuSimons/luci-app-honk) 是**一个仓库两个包**：

| 目录 | 包 | 内容 |
|---|---|---|
| `honk/` | honk | 从 `daeuniverse/honk` 指定 commit 编译出的 `honk-core`、init.d、默认配置 |
| `luci-app-honk/` | luci-app-honk | LuCI 页面、rpcd ucode 后端、Doona 静态资源（`root/etc/honk/doona`） |

仓库根目录还有 `scripts/`（维护者刷新版本号用）、`PIC/`（README 截图）、`.github/`，
这些不参与构建；**根目录没有 Makefile**，所以只能按 `mode=pkg` 只拷这两个目录 ——
`mode=all` 会因为「拷贝后缺少 Makefile」直接被同步脚本判失败。这两个目录内部
没有任何 `../` 跨目录引用，单独拷出来可以独立编译。

`honk-core` 不是在 OpenWrt 里交叉编译的：`honk/build_honk_core.sh` 调用宿主机上的
**Rust / cargo / Zig / bpf-linker**（版本由上游 `.github/ci/pins.env` 与 release.yml
钉住），产物写到 `honk/files/honk-core.bin`；该文件被上游 `.gitignore` 忽略，
所以**新同步下来的快照里没有它**。两条路：

1. 宿主机装好工具链后编译（需能访问 crates.io、ziglang.org、aya-rs releases），
   版本用 `eval $(./package/feeds/suite/honk/honk_toolchain.sh)` 现查；
2. 想跳过编译：把已生成的 `honk-core.bin` 放进 `package/feeds/suite/honk/files/`，
   构建脚本带 `--if-needed`，无 `.stamp` 时视为预编译产物直接复用。

架构只支持 `x86_64` 与 `aarch64_generic`（Makefile 里的 `HONK_RUST_ARCH_DEPENDS` 限定）。

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
