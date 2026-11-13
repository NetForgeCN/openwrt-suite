# openwrt-suite

OpenWrt 第三方组件**单一聚合 feed 仓库**：把 27 个第三方包（29 个包源目录，含
argon 自带的 `compat/luci-app-argon-config` 与 oxidns 自带的 `oxidns-core` 两个
嵌套子包）+ 一份固件 `.config` 统一收进本仓库，每日由 GitHub Actions 从各上游
同步（纯快照方式）。使用时**只需克隆本仓库**，第三方包就会出现在 `make menuconfig` 里。

## 仓库结构

```
openwrt-suite/
├── packages/          27 个包（feed 主体，OpenWrt 递归扫描含 Makefile 的目录）
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

第 2 步完成后，27 个第三方包已全部出现在 `make menuconfig` 中，且
`config/dot.config` 里原有的选择会自动勾选好：16 个包 + `v2ray-geoip` /
`v2ray-geosite`（v2ray-geodata 源里的实际数据包，`v2ray-geodata` 本身是虚包）。

这些包在 menuconfig 中的位置：

| 菜单路径 | 包 |
|---|---|
| LuCI → Applications | luci-app-airplay2、luci-app-dae、luci-app-ddns-go、luci-app-diskman、luci-app-honk、luci-app-kixdns、luci-app-oxidns、luci-app-nikki、luci-app-photondns、luci-app-photondns-compat、luci-app-pulse、luci-app-temp-status |
| LuCI → Themes | luci-theme-argon |
| Network | dae、ddns-go、kixdns、kixdns-stats、mihomo-alpha、mihomo-meta、nikki、nqptp、open-nexttrace-core、v2ray-geodata |
| Network → IP Addresses and Names | photondns（Rust DNS 转发器） |
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

### 每日固件构建（GitHub Actions）

`.github/workflows/build.yml` 每天**北京时间 02:45**（18:45 UTC，紧跟 02:30 的
daily-sync，留 15 分钟给它收尾）用 `build/compile.sh` 出一版 x86-64 固件，并发布
Release（保留最近 7 个，artifact 保留 3 天）。触发方式是独立 cron：同步失败不阻塞
出固件，只是当晚沿用前一天的快照。

构建直接使用 workflow 所在提交的 suite（脚本、`packages/`、`config/dot.config`
同源），缓存策略与其他构建仓库一致 —— dl（key 绑 dot.config / compile.sh）、
staging_dir 工具链（含 photondns 需要的 rust/host）、ccache（key 带 run_id）。
参考其他两个构建仓库的真实数据：热构建约 3~3.5 小时，正常 **06:00 前后完成**；
**首次冷构建会超 5 小时**，启用本 workflow 后应先手动 Run workflow 预热一次缓存。
honk 的宿主机工具链由 `compile.sh` 里的 `ensure_honk_toolchain` 按 `.config`
自动准备（不选 honk 则整段跳过）。

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

`pkg` 的 payload 可以写上游内的**子路径**，目标目录取它的 basename，用来对付
「包目录藏在子目录里」的上游（如 c2h2/luci-app-photondns 的 `openwrt/photondns`）。
顶层目录写法的行为与以前完全一致。

每个源同步后强制校验 `Makefile` 存在，任何失配（上游重构、删库、改默认分支）
都会让同步失败报红，绝不静默产出坏快照。每次同步把上游 commit 记入 `sources.lock`。

> **`packages/` 下的一切都由上游决定，不要在这里直接改。** 典型例子：argon 快照里
> 自带的 `.github/workflows/*`（上游自己的 CI）会被 Renovate 当成仓库依赖来提 PR，
> 但合并后下一次同步就 `rm -rf` 冲掉，而且这些 workflow 在子目录里 GitHub 根本不会执行。
> 所以 `renovate.json` 里已经 `ignorePaths: ["packages/**"]`，Renovate 只升级本仓库
> 自身的 `.github/workflows/sync.yml`。真需要在快照上做定制，用 `patches/<slug>.sh`。

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

1. 宿主机装好工具链后编译（需能访问 crates.io、ziglang.org、aya-rs releases）；
2. 想跳过编译：把已生成的 `honk-core.bin` 放进 `package/feeds/suite/honk/files/`，
   构建脚本带 `--if-needed`，无 `.stamp` 时视为预编译产物直接复用。

#### 宿主机依赖（honk 核心专用）

⚠️ **这一节和 OpenWrt 的交叉编译工具链无关。** `honk-core` 是**在宿主机上**用
Rust + Zig 编译后再塞进 ipk 的，所以每台构建机（含 GitHub Actions runner）都要
先备好这套工具；只装 OpenWrt 的依赖不够，缺了会在 `honk` 包编译阶段直接失败。

版本必须与上游 pin **完全一致**（`honk/build_honk_core.sh` 会用 `zig version`
严格比对，不等就 `exit 1`）。当前 pin 由 `honk/Makefile` 的 `HONK_SRC_VERSION`
所指的那次提交决定，本快照对应的值如下：

| 组件 | 版本 | 说明 |
|---|---|---|
| Zig | `0.14.1` | 必须精确匹配，脚本不比较范围 |
| bpf-linker | `0.11.0` | musl 静态包，按 sha256 校验；`--version` 报 0.0.0 是正常的 |
| Rust | 任意 rustup 稳定版 | eBPF 部分脚本会自动 `rustup toolchain install nightly --component rust-src,llvm-tools` |

Debian / Ubuntu 宿主机可直接粘这一段：

```bash
# 1) 编译 honk-core 需要的系统依赖（bindgen / eBPF / 解压用）
sudo apt-get update
sudo apt-get install -y clang llvm libbpf-dev cmake libclang-dev zstd \
  make perl file binutils git curl xz-utils pkg-config ca-certificates

# 2) rustup（honk 构建脚本位于 ~/.cargo/bin 的前提）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
. "$HOME/.cargo/env"

# 3) bpf-linker 0.11.0（务必保留 sha256 校验）
curl -fsSL -o /tmp/bpf-linker.tar.zst \
  https://github.com/aya-rs/bpf-linker/releases/download/v0.11.0/bpf-linker-x86_64-unknown-linux-musl.tar.zst
echo "10f62ba9ab7e544d538370552660efcb4f1a19153d5752bbf0f6b51f3bada450  /tmp/bpf-linker.tar.zst" | sha256sum -c -
sudo tar --zstd -xf /tmp/bpf-linker.tar.zst -C /usr/local/bin

# 4) Zig 0.14.1（版本必须一模一样）
curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz
sudo tar -xJf /tmp/zig.tar.xz -C /usr/local
sudo ln -sf /usr/local/zig-x86_64-linux-0.14.1/zig /usr/local/bin/zig

# 5) 自检
zig version && bpf-linker --version && cargo --version
```

几点说明：

- **脚本只检查、不自动装**：`build_honk_core.sh` 里是 `command -v zig` 之类的
  断言，缺失就报错退出，不会替你 `apt install`；这一步必须人来做（或交给 CI）。
- **不要用发行版包管理器装 Zig**：Debian/Ubuntu 源里的 zig 是旧版本，`zig version`
  对不上 pin 一样会失败；bpf-linker 同理，必须用 aya-rs 的 release 资产。
- **换机器/换 CI 都要重做**：这套工具在宿主机全局，不随 OpenWrt 构建树或
  `staging_dir` 缓存走。
- **CI 里怎么用**：`NetForgeCN/OpenWrt-ScriptBuild` 的 `compile.sh`（`ensure_honk_toolchain`）
  与 `NetForgeCN/OpenWRT` 的 `OpenWRT.yml`（"Install honk toolchain" 步骤）都内置了
  同一套安装逻辑，且**只在 `.config` 里选中 `honk` 时才触发**；不选 honk 的构建
  不会多花这几分钟。
- 版本升级：上游改 pin 时，`honk/Makefile` 的 `HONK_SRC_VERSION` 会变，
  这时要同步更新本节的 Zig / bpf-linker 版本号，以及上面两处 CI 里的同名常量
  （`HONK_ZIG_VERSION` / `HONK_BPF_LINKER_VERSION`）。三处对不上就会编译失败。

架构只支持 `x86_64` 与 `aarch64_generic`（Makefile 里的 `HONK_RUST_ARCH_DEPENDS` 限定）。

### photondns 的处理

上游 [c2h2/luci-app-photondns](https://github.com/c2h2/luci-app-photondns) 的目录结构和别人的不一样：
**仓库根是 Rust 工程**（`Cargo.toml`、`Cargo.lock`、`build.rs`、`src/`），三个 OpenWrt 包则躺在
`openwrt/` 子目录里，而且根目录**没有 Makefile**：

| 上游路径 | 包 | 说明 |
|---|---|---|
| `openwrt/photondns/` | photondns | Rust 守护进程 + uci 配置 + init.d + 列表更新脚本 |
| `openwrt/luci-app-photondns/` | luci-app-photondns | 新版 LuCI（JS 视图 + ucode rpcd 后端） |
| `openwrt/luci-app-photondns-compat/` | luci-app-photondns-compat | 旧 LuCI 的 Lua/CBI 版（依赖 `luci-compat`） |

所以 `sources.conf` 里 payload 直接写子路径，目标目录取 basename —— 这是 `mode=pkg` 支持的
写法（`openwrt/photondns` → `packages/photondns`），顶层目录的上游（ddnsgo、kixdns 等）
行为完全不变。

**还有一个坑**：上游 `openwrt/photondns/Makefile` 用 `RustBinPackage`，编译的是「包目录里的」
Cargo 工程（`cargo install --path $(PKG_BUILD_DIR)`，默认 `Build/Prepare` 只把包目录的
`./src/*` 拷进构建目录）。可包里只有 `Makefile` 和 `root/`，工程本体在仓库根 ——
照原样构建必然报 `could not find Cargo.toml`。`patches/photondns.sh` 在同步后把
`Cargo.toml` / `Cargo.lock` / `build.rs` / `src/` 从上游克隆 stage 到
`packages/photondns/src/`，这样默认 `Prepare` 正好把 `Cargo.toml` 摆到构建目录根，
`cargo` 就能正常识别（stage 内容与上游逐字节一致，不做任何修改）。上游哪天自己把工程
放进包目录，这个补丁的结构校验会报错，届时删掉即可。

构建注意：

- `PKG_BUILD_DEPENDS:=rust/host` —— 第一次编译要先把 Rust 宿主工具链建起来，很耗时；
- `CARGO_HOME` 在 `dl/cargo`，**首次编译需要联网**拉 crates（Cargo.lock 已锁定版本）；
- `Cargo.toml` 里除了 `photondns` 还声明了 4 个 bench 用的 bin，`cargo install` 会一并编译
  （LTO），但产物只装 `photondns`。嫌慢可以在上游 Makefile 里加
  `Build/Compile=$(call Build/Compile/Cargo,,--bin photondns)`。

### nikki 的处理

上游 [nikkinikki-org/OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki) 是
mihomo（Clash.Meta）的整套 OpenWrt 方案，**一个仓库四个包**，四个目录都在顶层、
各自带 Makefile：

| 目录 | 包 | 说明 |
|---|---|---|
| `nikki/` | nikki | 主包：nftables 脚本、ucode 模板、init.d、UCI 默认配置 |
| `mihomo-meta/` | mihomo-meta | 稳定版内核（`VARIANT:=meta` + `DEFAULT_VARIANT:=1`） |
| `mihomo-alpha/` | mihomo-alpha | alpha 内核，与 meta 互斥（双方 `PROVIDES:=mihomo` / `CONFLICTS` 互指） |
| `luci-app-nikki/` | luci-app-nikki | LuCI 界面（JS 视图 + ucode rpcd 后端 + 三种语言 po） |

根目录的 `install.sh` / `uninstall.sh` / `feed.sh` 是上游的一键安装脚本，不参与构建，
所以按 `mode=pkg` 只拷这四个目录。

选择关系：`nikki` 的 DEPENDS 写的是**虚拟包** `+mihomo`，由两个内核包之一 `PROVIDES`；
因为 `mihomo-meta` 带 `DEFAULT_VARIANT:=1`，勾 `nikki` 时默认拉的是稳定版内核。
需要 alpha 时在 menuconfig 里换成 `mihomo-alpha`（同时选会冲突，两者 `CONFLICTS` 互相声明）。

构建注意：两个内核包走 `golang-package.mk`，`PKG_SOURCE_PROTO:=git` 指向
`MetaCubeX/mihomo`，`golang/host` 由 buildroot 自动准备 —— **不需要额外的宿主机工具**
（与 honk 的 Zig/bpf-linker 不同，和 photondns 一样省心）。`make download` 阶段会把
mihomo 源码克隆进 `dl/`，之后编译只是 `go build`。

### 版本锁定与可复现

构建用的所有第三方代码严格等于本仓库快照；每个快照对应的上游 commit 记录在
`sources.lock`，可追溯、可回滚（git 历史），上游删库 / force-push / 投毒
均不影响已发布的快照。

## 手动触发同步

- GitHub 仓库页 → Actions → daily-sync → Run workflow；或
- 本地执行：`bash scripts/sync.sh`（之后自行 commit / push）

调试单个源：`SUITE_SYNC_ONLY=geodata bash scripts/sync.sh`

## 许可证

**本仓库自身**（`scripts/`、`diy/`、`build/`、文档）以 **MIT** 授权，见 [LICENSE](LICENSE)。

**聚合进来的第三方包**许可证**原样保留**：`mode=all` 的包 LICENSE 在包目录内；
`mode=pkg` 的多包上游其 LICENSE / THIRD-PARTY-NOTICES 副本收于 `meta/<slug>/`。
本仓库不对任何上游代码做修改，唯一的例外是 `patches/geodata.sh` 声明的
GEOIP_URL 一行定制。

> 换句话说：MIT 只覆盖本仓库自己的脚本与文档；每个 `packages/<name>/` 下的代码
> 仍按它自己的许可证（GPL-3.0、Apache-2.0 等）分发，装机时以包内 LICENSE 为准。
