# openwrt-suite

OpenWrt 第三方组件**单一聚合 feed 仓库**：把 35 个第三方包（39 个包源目录）与一份固件 `.config` 统一收进本仓库，每日由 GitHub Actions 从各上游同步（纯快照方式）。使用时**只需克隆本仓库**，第三方包就会出现在 `make menuconfig` 里。

## 使用方法

### 方式一：克隆本仓库 → menuconfig 勾选 → 编译

```bash
# 1) 克隆这一个仓库
git clone https://github.com/NetForgeCN/openwrt-suite.git

# 2) 准备到可配置状态（自动克隆 OpenWrt 主仓库、配置 feeds、安装全部第三方包），
#    然后直接打开 make menuconfig
bash openwrt-suite/build/compile.sh --menuconfig

# 3) 在 menuconfig 里勾选需要的包，保存退出后开始编译
bash openwrt-suite/build/compile.sh
```

`config/dot.config` 提供一份初始包选择，保存退出后自动勾选好；其余包按需在 menuconfig 里勾选，实际以 `config/dot.config` 为准。

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

`./scripts/feeds` 只存在于 OpenWrt 源码树里，所以整段要在源码树内执行；三个 `diy/` 脚本用绝对路径调用，第一个参数仍是源码树目录：

```bash
OW=$HOME/openwrt
SUITE=$HOME/openwrt-suite

cd "$OW"
bash "$SUITE/diy/00-feeds-order.sh" "$OW"   # 在 feeds update 之前
./scripts/feeds update -a
./scripts/feeds install -a
bash "$SUITE/diy/01-feed-patches.sh" "$OW"
# .config 直接用 "$SUITE/config/dot.config"
bash "$SUITE/diy/02-kernel-config.sh" "$OW"
```

## 收录的包

以下包在 menuconfig 中的位置按各包 Makefile 的 `CATEGORY` / `SUBMENU` 归类：

| 菜单路径 | 包 |
|---|---|
| LuCI → 3. Applications | luci-app-airplay2、luci-app-argon-config、luci-app-atomdns、luci-app-dae、luci-app-ddns-go、luci-app-diskman、luci-app-honk、luci-app-kixdns、luci-app-lucky、luci-app-mosdns、luci-app-nikki、luci-app-oaf、luci-app-open_nexttrace、luci-app-oxidns、luci-app-photondns、luci-app-photondns-compat、luci-app-pulse、luci-app-temp-status |
| LuCI → 4. Themes | luci-theme-argon |
| Network → IP Addresses and Names | ddns-go、kixdns、mosdns（Go DNS 转发器）、photondns（Rust DNS 转发器）、v2ray-geodata（虚包，实际产出 v2ray-geoip / v2ray-geosite） |
| Network → Web Servers/Proxies | dae、honk（eBPF 核心，仅 x86_64 / aarch64_generic） |
| Network → DNS | oxidns-core、oxidns-rules-baseline（OxiDNS 内置规则订阅基线） |
| Network（无子菜单） | kixdns-stats、lucky（静态核心，编译期内置）、mihomo-alpha、mihomo-meta、nikki、nqptp、open-nexttrace-core |
| Sound | airplay2 |
| Utilities | geo2txt（解包 geosite.dat / geoip.dat 的 C 工具） |
| Base system | appfilter（OAF 服务守护，由 `open-app-filter/` 目录产出） |
| Kernel modules → Netfilter Extensions | kmod-oaf（由 `oaf/` 目录产出的 netfilter 内核模块） |

LuCI 包不写 `CATEGORY` / `SUBMENU` 时由 `luci.mk` 按 `LUCI_TYPE` 归类：`app` → `LuCI / 3. Applications`，`theme` → `LuCI / 4. Themes`。

自己的配置改动只留在本地 `.config`，不会被覆盖；想强制回到仓库快照版本时用 `REFRESH_CONFIG=1`（旧配置会自动备份）。想临时试另一份配置，用 `CONFIG_URL=<url>` 指定，仅当次生效、不改变快照。

<a id="build"></a>

## 编译固件

NetForgeCN 提供三套 OpenWrt x86-64 固件构建仓库，编译入口不同，产物都是固件 Release。三份 `.config` 由使用者自行维护，构建脚本不会改写它。

| 仓库 | 编译方式 | 编译入口 |
|---|---|---|
| [openwrt-suite](https://github.com/NetForgeCN/openwrt-suite#build) | 聚合 feed + 一键脚本 | `build/compile.sh`、`build.yml` |
| [OpenWRT](https://github.com/NetForgeCN/OpenWRT#build) | GitHub Actions 分步编排 | `OpenWRT.yml` + `diy-part1.sh` / `diy-part2.sh` |
| [OpenWrt-ScriptBuild](https://github.com/NetForgeCN/OpenWrt-ScriptBuild#build) | 单脚本全流程 | `compile.sh`、`build.yml` |

三个仓库的完整编译说明见各自 README 的「编译固件」章节（上表链接）。

### 本仓库：一键构建

```bash
bash openwrt-suite/build/compile.sh
```

脚本自动完成：克隆/更新 OpenWrt → 克隆 suite → 配置 feeds → `feeds update/install` → 打官方 feed 补丁 → 写入 `.config` → 打内核补丁 → 下载 → 编译。

`--help` 查看全部可配置项，`--jobs N` 指定并行任务数，`--menuconfig` 只准备到可配置状态并打开 menuconfig。常用环境变量：`WORKDIR`（默认 `~/openwrt`）、`SUITE_DIR`、`CONFIG_URL`、`JOBS`、`SKIP_UPDATE=1`、`SKIP_DOWNLOAD=1`、`SKIP_BUILD=1`（只准备不编译）、`REFRESH_CONFIG=1`、`GO_AMD64_LEVEL`、`HONK_TOOLCHAIN_AUTO`。

### 本仓库：每日固件构建（GitHub Actions）

`.github/workflows/build.yml` 每天**北京时间 02:45** 用 `build/compile.sh` 出一版 x86-64 固件并发布 Release（保留最近 7 个，artifact 保留 3 天），支持手动 `Run workflow`。构建使用独立 cron：同步失败不阻塞出固件，当晚沿用前一天的快照。`.github/workflows/sync.yml` 每天 02:30 同步上游快照。

构建直接使用 workflow 所在提交的 suite（脚本、`packages/`、`config/dot.config` 同源）：`SUITE_DIR` 指向本次 checkout，`00-feeds-order.sh` 检测到它是本地 suite 仓库就写 `src-link suite <构建树/feeds/.suite-local>`，该目录里只有一个 `packages` 软链指向 checkout 的 `packages/`。`feeds update -a` 把它挂成 feed，包快照与配置严格同属一个提交。只暴露 `packages/` 一层：`scan.mk` 用 `find -L` 递归扫整个 feed 目录，只挂一个干净的 `packages` 软链可以让扫描范围精确可控。本地手动跑 `compile.sh` 时同理。

缓存分三类：dl（key 绑 `dot.config` / `compile.sh`）、staging_dir 工具链（含 photondns 需要的 rust/host）、ccache（key 带 run_id）。热构建约 3~3.5 小时；首次冷构建耗时更长，可先手动触发一次预热缓存。`honk` 的宿主机工具链由 `compile.sh` 里的 `ensure_honk_toolchain` 按 `.config` 自动准备，不选 honk 则整段跳过。

## 工作原理

```
git clone 本仓库  ──►  一个标准 OpenWrt feed（顶层 packages/ 里每个目录 = 一个包）
                              │
              feeds.conf 首行 src-git suite <url>（本地 checkout 时为 src-link）
                              │
   ./scripts/feeds update -a  ──►  克隆 / 软链到 feeds/suite/
   ./scripts/feeds install -a ──►  在 package/feeds/suite/ 下为每个包建符号链接
                              │
        OpenWrt 的包扫描（include/scan.mk）递归查找所有含 Makefile
        且调用 BuildPackage 的目录 ──► 生成包索引 tmp/.packageinfo
                              │
                     make menuconfig 读取索引 ──► 菜单里可勾选
```

几个关键事实：

1. **扫描是递归的，有深度上限**：`scripts/feeds` 给 `update_index` 传的是 `SCAN_DEPTH=5`，`include/scan.mk` 因此执行 `find -L $(SCAN_DIR) -mindepth 1 -maxdepth 5 -name Makefile`。`feeds/suite/packages/<包名>/Makefile` 这类多一层嵌套可以正常识别；最深的 `luci-theme-argon/compat/luci-app-argon-config/Makefile` 正好落在第 5 层，更深的嵌套包会被静默跳过。
2. **包路径无关紧要**：本仓库所有 Makefile 都用 `$(TOPDIR)` / `$(INCLUDE_DIR)` 绝对引用，没有一处相对路径 `include`，放在哪一层都能正常解析。
3. **同名包由 feeds 顺序决定**：`scripts/feeds` 的 `install -a` 按 feeds.conf 顺序遍历，已安装过的源包名直接跳过 —— 谁排在前面谁生效。把 suite 放第一条，nqptp / v2ray-geodata / ddns-go / dae 就用本仓库版本。包通过 feeds 接入；直接 clone 到 `package/suite` 时，`scan.awk` 会让 feed 版本覆盖 `package/` 下的同名包。
4. **`.config` 只是初始建议值**：首次准备时从 `config/dot.config` 写入，之后 menuconfig 的改动保留在本地，不会每次被覆盖。

## 关键设计

### feeds 顺序与包名冲突

OpenWrt 的 `feeds install -a` 对同名包按 feeds.conf 中的**出现顺序**取先到者。官方 packages feed 也有 `nqptp`、`v2ray-geodata`、`ddns-go`、`dae` 等同名包，`diy/00-feeds-order.sh` 把 suite 行插到所有官方 feed 之前，因此这些包始终使用本仓库版本。手工接入已有构建（没设置 `SUITE_DIR`）时写入的是 `src-git suite <URL>`；由 `compile.sh` 调用时 `SUITE_DIR` 指向本地仓库，会改写为 `src-link suite <构建树/feeds/.suite-local>`：脚本建一个只含 `packages` 软链的干净目录（指向 `SUITE_DIR/packages`），`feeds update -a` 会 `ln -s` 该目录并照常生成 index。`compile.sh` 的同名包校验以 `feeds/suite/packages` 的真实路径为基准，两种接入方式行为一致。

`compile.sh` 在每个包安装后还会逐包解析 `package/feeds/*/` 链接的真实指向：凡是指向非 `feeds/suite` 的（包括悬空链接），一律清掉并从 suite 重装，最后复核一遍，不一致直接报错退出。

### 纯快照同步

`scripts/sync.sh` 每次对每个源**先删后拷**（不 rsync 增量、不带 .git），路径映射由 `sources.conf` 显式声明三种模式：

| 模式 | 适用 | 例子 |
|---|---|---|
| `pkg`  | 包目录在仓库的一层或多层子目录下（根目录无 Makefile） | sirpdboy/luci-app-ddns-go → `luci-app-ddns-go/` + `ddns-go/`；NetForgeCN/luci-app-atomdns → `luci-app-atomdns/` |
| `all`  | Makefile 在仓库根目录 | jerrykuku/luci-theme-argon → `luci-theme-argon/` |
| `file` | 大仓库里的单个文件 | NetForgeCN/OpenWRT 的 `.config` → `config/dot.config` |

`pkg` 的 payload 可以写上游内的**子路径**，目标目录取它的 basename，用来对付「包目录藏在子目录里」的上游（如 c2h2/luci-app-photondns 的 `openwrt/photondns`）。只含一个包目录的上游（如 atomdns）同样走 `pkg`，payload 只写一个目录，仓库根的 README / LICENSE 不会被当成包，许可证另由 `copy_meta` 收进 `meta/<slug>/`。每个源同步后强制校验 `Makefile` 存在，任何失配（上游重构、删库、改默认分支）都会让同步失败报红。每次同步把上游 commit 记入 `sources.lock`。

`packages/` 下的内容由上游决定，快照定制用 `patches/<slug>.sh`。`renovate.json` 里 `ignorePaths: ["packages/**"]`，Renovate 只升级本仓库自身的 workflow 依赖。

### 版本锁定与可复现

构建用的所有第三方代码严格等于本仓库快照；每个快照对应的上游 commit 记录在 `sources.lock`，可追溯、可回滚（git 历史），上游删库 / force-push / 投毒均不影响已发布的快照。

## 各包构建说明

### v2ray-geodata

同步源是自建仓库 [NetForgeCN/Loyalsoldier](https://github.com/NetForgeCN/Loyalsoldier)（仓库内只有一份 Makefile）。它的 `GEOIP_URL` 与 `GEOSITE_URL` 都指向自建规则仓库 [NetForgeCN/v2ray-rules-dat](https://github.com/NetForgeCN/v2ray-rules-dat) 的 latest release：全量 `geoip.dat` + `geosite.dat`（Loyalsoldier 全量集，另加反广告 / Cats-Team AdRules / neodevhost 列表），release 里同时提供两个 `.sha256sum` 供 Makefile 的 `Build/Compile` 校验。快照与源仓库逐字节一致，换数据源只改那个仓库，suite 次日 02:30 自动同步到位。

该包目录只有 Makefile（头部为 GPL-3.0 声明），`PKG_LICENSE_FILES:=LICENSE` 是上游写法。

### honk

上游 [QiuSimons/luci-app-honk](https://github.com/QiuSimons/luci-app-honk) 是**一个仓库两个包**：

| 目录 | 包 | 内容 |
|---|---|---|
| `honk/` | honk | 从 `daeuniverse/honk` 指定 commit 编译出的 `honk-core`、init.d、默认配置 |
| `luci-app-honk/` | luci-app-honk | LuCI 页面、rpcd ucode 后端、Doona 静态资源（`root/etc/honk/doona`） |

仓库根目录还有 `scripts/`、`PIC/`、`.github/`，这些不参与构建；**根目录没有 Makefile**，所以按 `mode=pkg` 只拷这两个目录。两个目录内部没有任何 `../` 跨目录引用，可以独立编译。

`honk-core` 不是在 OpenWrt 里交叉编译的：`honk/build_honk_core.sh` 调用宿主机上的 **Rust / cargo / Zig / bpf-linker**（版本由上游 `.github/ci/pins.env` 与 release.yml 钉住），产物写到 `honk/files/honk-core.bin`；该文件被上游 `.gitignore` 忽略，快照里不带它。两条路：

1. 宿主机装好工具链后编译（需能访问 crates.io、ziglang.org、aya-rs releases）；
2. 把已生成的 `honk-core.bin` 放进 `package/feeds/suite/honk/files/`。`honk/Makefile` 的 `Build/Compile` 内置 `build_honk_core.sh --if-needed`，没有 `.stamp` 时会把现成的 `.bin` 当作预编译产物直接复用。`--if-needed` 由 Makefile 传入；`build/compile.sh` 接受 `--help` / `--jobs` / `--menuconfig`。

#### 宿主机依赖（honk 核心专用）

`honk-core` 是**在宿主机上**用 Rust + Zig 编译后再塞进 ipk 的，所以每台构建机（含 GitHub Actions runner）都要备好这套工具。版本必须与上游 pin **完全一致**（`honk/build_honk_core.sh` 会用 `zig version` 严格比对，不等就 `exit 1`）。当前 pin 由 `honk/Makefile` 的 `HONK_SRC_VERSION` 所指的提交决定：

| 组件 | 版本 | 说明 |
|---|---|---|
| Zig | `0.14.1` | 必须精确匹配，脚本不比较范围 |
| bpf-linker | `0.11.0` | musl 静态包，按 sha256 校验；`--version` 报 0.0.0 是正常的 |
| Rust | 任意 rustup 稳定版 | eBPF 部分脚本会自动 `rustup toolchain install nightly --component rust-src,llvm-tools` |

Zig 与 bpf-linker 都按**构建机架构**发布，两个架构的资产名和 sha256 各不相同。`build/compile.sh` 里的 `ensure_honk_toolchain` 已按 `uname -m` 自动选择；手工安装时按下面表格替换 `ARCH`：

| 宿主机 `uname -m` | 资产里的 ARCH | bpf-linker sha256 |
|---|---|---|
| `x86_64` / `amd64` | `x86_64` | `10f62ba9ab7e544d538370552660efcb4f1a19153d5752bbf0f6b51f3bada450` |
| `aarch64` / `arm64` | `aarch64` | `d09ddd83303e9ab1443f51e0e284680154009646a3ce141c63d838ee61b73eb9` |

Zig 下载地址：`https://ziglang.org/download/0.14.1/zig-<ARCH>-linux-0.14.1.tar.xz`。

Debian / Ubuntu 宿主机可直接粘这一段：

```bash
# 0) 先确定宿主机架构（x86_64 / aarch64 都支持）
ARCH=$(uname -m); case "$ARCH" in amd64) ARCH=x86_64 ;; arm64) ARCH=aarch64 ;; esac
case "$ARCH" in
  x86_64)  SHA=10f62ba9ab7e544d538370552660efcb4f1a19153d5752bbf0f6b51f3bada450 ;;
  aarch64) SHA=d09ddd83303e9ab1443f51e0e284680154009646a3ce141c63d838ee61b73eb9 ;;
  *) echo "unsupported arch: $ARCH"; return 1 ;;
esac

# 1) 编译 honk-core 需要的系统依赖（bindgen / eBPF / 解压用）
sudo apt-get update
sudo apt-get install -y clang llvm libbpf-dev cmake libclang-dev zstd \
  make perl file binutils git curl xz-utils pkg-config ca-certificates

# 2) rustup（honk 构建脚本位于 ~/.cargo/bin 的前提）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
. "$HOME/.cargo/env"

# 3) bpf-linker 0.11.0（按宿主机架构下，务必保留 sha256 校验）
curl -fsSL -o /tmp/bpf-linker.tar.zst \
  "https://github.com/aya-rs/bpf-linker/releases/download/v0.11.0/bpf-linker-${ARCH}-unknown-linux-musl.tar.zst"
echo "$SHA  /tmp/bpf-linker.tar.zst" | sha256sum -c -
sudo tar --zstd -xf /tmp/bpf-linker.tar.zst -C /usr/local/bin

# 4) Zig 0.14.1（版本必须一模一样，架构也要对）
curl -fsSL -o /tmp/zig.tar.xz \
  "https://ziglang.org/download/0.14.1/zig-${ARCH}-linux-0.14.1.tar.xz"
sudo tar -xJf /tmp/zig.tar.xz -C /usr/local
sudo ln -sf "/usr/local/zig-${ARCH}-linux-0.14.1/zig" /usr/local/bin/zig

# 5) 自检
zig version && bpf-linker --version && cargo --version
```

`build_honk_core.sh` 只检查工具是否存在（`command -v zig` 之类的断言），缺失就报错退出。Zig 与 bpf-linker 必须用上游 pin 对应的 release 资产：发行版包管理器里的 Zig 版本较旧，`zig version` 对不上 pin 会失败。这套工具装在宿主机全局，不随 OpenWrt 构建树或 `staging_dir` 缓存走，换机器需重新准备。

需要自动安装时先 `sudo -v` 刷新凭据，再 `HONK_TOOLCHAIN_AUTO=1 bash build/compile.sh`（脚本会按 `uname -m` 选对架构）。手动体检：

```bash
uname -m
command -v cargo && cargo --version
command -v zig && zig version
command -v bpf-linker && bpf-linker --version
file -L "$(command -v zig)" 2>/dev/null; file -L "$(command -v bpf-linker)" 2>/dev/null
```

`file` 那两行显示的可执行文件架构应与宿主机一致。架构只支持 `x86_64` 与 `aarch64_generic`（Makefile 里的 `HONK_RUST_ARCH_DEPENDS` 限定）。

### photondns

上游 [c2h2/luci-app-photondns](https://github.com/c2h2/luci-app-photondns) 的**仓库根是 Rust 工程**（`Cargo.toml`、`Cargo.lock`、`build.rs`、`src/`），三个 OpenWrt 包在 `openwrt/` 子目录里，根目录没有 Makefile：

| 上游路径 | 包 | 说明 |
|---|---|---|
| `openwrt/photondns/` | photondns | Rust 守护进程 + uci 配置 + init.d + 列表更新脚本 |
| `openwrt/luci-app-photondns/` | luci-app-photondns | 新版 LuCI（JS 视图 + ucode rpcd 后端） |
| `openwrt/luci-app-photondns-compat/` | luci-app-photondns-compat | 旧 LuCI 的 Lua/CBI 版（依赖 `luci-compat`） |

`sources.conf` 里 payload 直接写子路径，目标目录取 basename（`mode=pkg` 支持的写法）。

上游 `openwrt/photondns/Makefile` 用 `RustBinPackage`，编译的是「包目录里的」Cargo 工程（`cargo install --path $(PKG_BUILD_DIR)`，默认 `Build/Prepare` 只把包目录的 `./src/*` 拷进构建目录）。包里只有 `Makefile` 和 `root/`，工程本体在仓库根。`patches/photondns.sh` 在同步后把 `Cargo.toml` / `Cargo.lock` / `build.rs` / `src/` 从上游克隆 stage 到 `packages/photondns/src/`，这样默认 `Prepare` 正好把 `Cargo.toml` 摆到构建目录根，`cargo` 就能正常识别（stage 内容与上游逐字节一致）。该补丁带结构校验，上游目录结构变化时同步会报红。

构建注意：

- `PKG_BUILD_DEPENDS:=rust/host` —— 第一次编译要先把 Rust 宿主工具链建起来，很耗时；
- `CARGO_HOME` 在 `dl/cargo`，**首次编译需要联网**拉 crates（Cargo.lock 已锁定版本）；
- `Cargo.toml` 里除了 `photondns` 还声明了 4 个 bench 用的 bin，`cargo install` 会一并编译（LTO），但产物只装 `photondns`。只需主程序时可在上游 Makefile 里加 `Build/Compile=$(call Build/Compile/Cargo,,--bin photondns)`。

### nikki

上游 [nikkinikki-org/OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki) 是 mihomo（Clash.Meta）的整套 OpenWrt 方案，**一个仓库四个包**，四个目录都在顶层、各自带 Makefile：

| 目录 | 包 | 说明 |
|---|---|---|
| `nikki/` | nikki | 主包：nftables 脚本、ucode 模板、init.d、UCI 默认配置 |
| `mihomo-meta/` | mihomo-meta | 稳定版内核（`VARIANT:=meta` + `DEFAULT_VARIANT:=1`） |
| `mihomo-alpha/` | mihomo-alpha | alpha 内核，与 meta 互斥（双方 `PROVIDES:=mihomo` / `CONFLICTS` 互指） |
| `luci-app-nikki/` | luci-app-nikki | LuCI 界面（JS 视图 + ucode rpcd 后端 + 三种语言 po） |

根目录的 `install.sh` / `uninstall.sh` / `feed.sh` 是上游的一键安装脚本，不参与构建，按 `mode=pkg` 只拷这四个目录。

选择关系：`nikki` 的 DEPENDS 写的是**虚拟包** `+mihomo`，由两个内核包之一 `PROVIDES`；`mihomo-meta` 带 `DEFAULT_VARIANT:=1`，勾 `nikki` 时默认拉稳定版内核。需要 alpha 时在 menuconfig 里换成 `mihomo-alpha`（同时选会冲突）。两个内核包走 `golang-package.mk`，`PKG_SOURCE_PROTO:=git` 指向 `MetaCubeX/mihomo`，`golang/host` 由 buildroot 自动准备，不需要额外的宿主机工具。`make download` 阶段会把 mihomo 源码克隆进 `dl/`，之后编译只是 `go build`。

### mosdns

上游 [sbwml/luci-app-mosdns](https://github.com/sbwml/luci-app-mosdns) 的默认分支是 **`v5`**（`sources.conf` 里写死），一个仓库三个包，目录都在顶层、各自带 Makefile：

| 目录 | 包 | 说明 |
|---|---|---|
| `mosdns/` | mosdns | Go 主程序：`GoBinPackage` 从 `IrineSistiana/mosdns` v5.3.4 源码编译，带 30 个上游补丁（`patches/` 整目录随快照拷入） |
| `luci-app-mosdns/` | luci-app-mosdns | LuCI 界面：`htdocs/` 下 5 个 JS 视图 + CodeMirror、`ucode` rpcd 后端、ACL、中文 po |
| `geo2txt/` | geo2txt | 解包 `geosite.dat` / `geoip.dat` 的 C 小工具，是 luci-app 的硬依赖 |

根目录的 `install.sh` 是给终端用户装预编译 ipk 的，不参与构建，按 `mode=pkg` 只拷这三个目录。上游 LICENSE（GPL-3.0）由 `sync.sh` 自动收进 `meta/mosdns/`。`mosdns/Makefile` 只用官方 `$(TOPDIR)/feeds/packages/lang/golang/golang-package.mk`，`golang/host` 由 buildroot 自动准备，构建库已处理 golang 版本与 `GO_AMD64`。`luci-app-mosdns` 的 `LUCI_DEPENDS` 是 `+v2ray-geoip +v2ray-geosite +geo2txt +ucode +mosdns`，前两个由本仓库的 `geodata` 源提供。

官方 `golang-package.mk` 默认 `CGO_ENABLED=1`，产物动态链接 musl libc，打包时依赖自动解析，不影响固件。需要纯静态二进制时可用同步后补丁注入 `GO_PKG_DEFAULT_LDFLAGS:=-w -s -extldflags "-static"`。

### lucky

`lucky` 源指向自有仓库 [NetForgeCN/luci-app-lucky](https://github.com/NetForgeCN/luci-app-lucky)：`mode=all` 整仓拷成 `packages/luci-app-lucky/`，根 Makefile 是 `luci-app-lucky`，内部 `lucky/Makefile` 是核心子包，由 OpenWrt 递归扫描识别。

| 约定 | 做法 |
|---|---|
| 核心进固件 | `lucky/Makefile` 用标准 `PKG_SOURCE` + 逐架构 sha256 在 `make download` 阶段下载官方静态二进制，`Package/install` 装到 `/usr/bin/lucky`，随 rootfs 打包 |
| 开机零联网 | `init.d`/`uci-defaults`/`postinst`/LuCI JS 中无任何下载核心的语句；找不到二进制只写日志并 `return 1` |
| 依赖不脱钩 | `LUCI_DEPENDS` 含 `+lucky`，选界面必然带上核心 |
| 自动跟进最新版 | 源仓库的 `bump.yml` 每天 01:30（北京）检查官网 `release.66666.host`，重算 13 个 Linux 资产 sha256 并改写 pin；**编译期不探测最新版**，本仓库次日 02:30 同步到新 pin |

当前钉在 3.8.1，x86_64 核心 17.08 MiB 静态 ELF。快照会连 `.github/`、`scripts/`、`lucky/assets.json` 一起拷入，这些没有 Makefile，不参与 feed 扫描。许可证见包目录内 `LICENSE`（GPL-3.0 全文）与 `NOTICE`（核心 MIT / 界面 GPL-3.0 归属）。

### openappfilter

上游 [destan19/OpenAppFilter](https://github.com/destan19/OpenAppFilter) 默认分支是 **`master`**。一个仓库三个包目录，都在顶层，但**目录名和包名不一致**：

| 目录 | 包名 | 说明 |
|---|---|---|
| `luci-app-oaf/` | luci-app-oaf | Lua/CBI 界面（`luasrc/` + `htdocs/` 静态资源 + 中文 po），`LUCI_DEPENDS:=+appfilter +kmod-oaf +luci-compat +luci-lib-jsonc` |
| `open-app-filter/` | appfilter | 用户态守护 `oafd`、特征库 `feature.bin`、`rule_manager.lua`、init.d 与 ACL；`CATEGORY:=Base system` |
| `oaf/` | kmod-oaf | netfilter 内核模块（`src/` 下 C 源码），`SUBMENU:=Netfilter Extensions`，`DEPENDS:=+kmod-nf-conntrack +kmod-nf-reject` |

`sources.conf` 用 `mode=pkg` 只拷这三个目录，勾选 `luci-app-oaf` 会自动带齐另外两个。上游根 `LICENSE`（GPL-2.0 全文）由 `sync.sh` 收进 `meta/openappfilter/`。三个目录都在 `packages/` 第一层，离 `SCAN_DEPTH=5` 的上限很远；`oaf/src/Makefile` 和 `open-app-filter/src/Makefile` 是子工程的构建文件、不含 `BuildPackage`，扫描时不会产生包条目。

三点需要留意：

1. **是 Lua LuCI，不是 JS LuCI**：`luci-app-oaf` 靠 `luci-compat`（→ `luci-lua-runtime`）和 `luci-lib-jsonc` 提供 Lua 运行时，`appfilter` 还依赖 `libuci-lua` 来跑 `rule_manager.lua`。`.config` 若显式裁掉 Lua 运行时，界面会打不开。
2. **内核模块要和内核同批编译**：`kmod-oaf` 用 `$(LINUX_DIR)` + `M=$(PKG_BUILD_DIR)` 编译，不能只装 ipk 了事。上游源码里有 `LINUX_VERSION_CODE` 分支覆盖到 6.16 / 6.15 / 6.12，内核 API 变动仍可能让新内核编译失败，以实际编译结果为准。
3. **许可证附加声明**：上游 README 写「个人免费、衍生开发须遵守 GPL 2.0、公司使用需联系作者授权」，与仓库里 GPL-2.0 全文的条款并不完全一致（GPLv2 不允许按使用者身份附加限制）。本仓库只做快照、保留原文，商用场景请自行评估。

### atomdns

`atomdns` 源指向自有仓库 [NetForgeCN/luci-app-atomdns](https://github.com/NetForgeCN/luci-app-atomdns)。仓库根只有 README / LICENSE，包目录是 `luci-app-atomdns/`（根目录没有 Makefile），因此 `mode=pkg` 只拷这一个目录。一个包即全功能：主程序二进制、官方配置包、内置 WebUI 与 LuCI 控制面板都在同一个 ipk 里。

| 项目 | 说明 |
|---|---|
| 核心进固件 | `Makefile` 用两条 `Download/` 规则在编译期从 `jasonxtt/atomdns` v0.6.6 release 取 musl 静态二进制与 `config_rust.zip`，逐架构 SHA256 校验；`Build/Prepare` 钩子把二进制装到 `/usr/bin/atomdns`、配置包装到 `/usr/share/atomdns`，随 rootfs 打包 |
| 运行期不联网 | 首次启动由 init.d 从 `/usr/share/atomdns` 初始化 `/etc/atomdns`，没有开机下载逻辑；内置 WebUI 的在线更新由用户主动触发 |
| 架构范围 | 官方只提供 x86_64 / aarch64 / armv7 的 musl 静态二进制，其他架构在编译阶段报错终止，不会静默打入不兼容的二进制。官方 `amd64-v3` 是 glibc 动态链接，与 OpenWrt 的 musl 环境不兼容，故不采用 |
| 菜单 | LuCI → 3. Applications → `luci-app-atomdns`，页面在 服务 → AtomDNS |

`LUCI_DEPENDS` 只有 `+ca-certificates`（DoH / 订阅需要证书），`LUCI_PKGARCH` 留空走目标架构。编译宿主机需要 `unzip` 解压 `config_rust.zip`，三套构建库的 CI 依赖清单都已包含。包内 `root/lib/upgrade/keep.d/luci-app-atomdns` 把运行时数据目录 `/etc/atomdns` 列入 sysupgrade 保留清单，与 conffiles 的 `/etc/config/atomdns` 互补。上游根 `LICENSE`（GPL-3.0 全文）由 `sync.sh` 收进 `meta/atomdns/`。

## 手动触发同步

- GitHub 仓库页 → Actions → daily-sync → Run workflow；或
- 本地执行：`bash scripts/sync.sh`（之后自行 commit / push）

调试单个源：`SUITE_SYNC_ONLY=geodata bash scripts/sync.sh`

## 许可证

**本仓库自身**（`scripts/`、`diy/`、`build/`、文档）以 **MIT** 授权，见 [LICENSE](LICENSE)。

**聚合进来的第三方包**许可证**原样保留**：`mode=all` 的包 LICENSE 在包目录内；`mode=pkg` 的上游其 LICENSE / THIRD-PARTY-NOTICES 副本收于 `meta/<slug>/`（`atomdns` 即为此类）。快照内容按上游原样分发，`patches/photondns.sh` 把上游仓库根的 Cargo 工程**原样补齐**到包目录（新增文件、不改动任何已有内容）。MIT 只覆盖本仓库自己的脚本与文档；每个 `packages/<name>/` 下的代码按它自己的许可证分发，装机时以包内 LICENSE 或 `meta/<slug>/LICENSE` 为准。
