# openwrt-suite

OpenWrt 第三方组件**单一聚合 feed 仓库**：把 36 个第三方包（40 个包源目录）与一份固件 `.config` 统一收进本仓库，每日由 GitHub Actions 按 `sources.lock` 中固定的 commit 同步（纯快照方式，变更先暂存、校验通过才整体发布）。使用时把本仓库挂成一个 feed，第三方包就会出现在 `make menuconfig` 里；`build/compile.sh` 克隆后直接运行即可完成从准备到编译的全过程，本地修改原样生效。

## 使用方法

本仓库同时提供三样东西：一个标准 OpenWrt feed（`packages/`）、一份固件配置快照（`config/dot.config`）、一套一键构建脚本（`build/compile.sh`），三者由同一提交保证一致。

**克隆即用**：`build/compile.sh` 会自动把 `SUITE_DIR` 指向脚本所在的这份检出，因此对 `packages/`、`config/dot.config`、`diy/` 乃至脚本本身的本地修改都会原样参与构建，无需设置任何变量；这份检出也不会被脚本 `git pull`，要跟进远端最新快照请自行 `git pull`。通常唯一需要按需指定的是 `WORKDIR`（OpenWrt 源码树，默认 `~/openwrt`）。显式设置 `SUITE_DIR` 仍然优先（CI 用它指向本次 checkout）；只有把脚本单独复制到别处、识别不到仓库结构时，才回退到 `$WORKDIR/suite` 自行克隆。

### 方式一：全新环境，一键构建（推荐）

```bash
git clone https://github.com/NetForgeCN/openwrt-suite.git
cd openwrt-suite

# 第一步：准备到可配置状态（克隆 OpenWrt、挂 feed、装包、写 .config、打三处现场补丁），
#         然后打开 menuconfig
bash build/compile.sh --menuconfig

# 第二步：menuconfig 里勾选并保存退出后，按这份 .config 编译
bash build/compile.sh
```

`--menuconfig` 只做准备、不编译；第二次运行才会 `make download` 与 `make`。`.config` 落在 `$WORKDIR/.config`（默认 `~/openwrt/.config`）：首次由 `config/dot.config` 写入，之后 menuconfig 的改动留在本地、**不回写**仓库快照，重跑脚本默认保留。想强制回到快照用 `REFRESH_CONFIG=1`（旧配置自动备份），临时试另一份配置用 `CONFIG_URL=<url>`，跳过 OpenWrt 主仓库更新用 `SKIP_UPDATE=1`（本仓库检出本来就不会被脚本更新）。

### 方式二：接入已有 OpenWrt 构建树

只需把 `WORKDIR` 指向已有源码树，其余与方式一相同 —— 仍然由 `compile.sh` 完成全部现场修改：

```bash
export WORKDIR="$HOME/openwrt"   # 已有的 OpenWrt 源码树
cd "$HOME/openwrt-suite"         # 本仓库的本地 clone

bash build/compile.sh --menuconfig
# menuconfig 保存退出后
bash build/compile.sh
```

脚本会更新 `$OW`；该树有未提交修改时自动跳过更新以保留改动，也可显式 `SKIP_UPDATE=1`。这是接入已有构建时唯一能拿到完整行为的路径：三处 `diy/` 现场补丁、同名包来源校正、构建缓存清理、honk 宿主机工具链都由脚本包办。

### 方式三：纯手工接入

只想把 suite 当 feed 挂进自己的构建流程、不跑 `compile.sh` 时，按下面顺序执行。`diy/00-feeds-order.sh` 会自动识别自身所在的 suite 仓库，用 `src-link` 挂本地 `packages/`（与本次检出同提交）；也可用 `SUITE_DIR` 显式指定另一份检出，识别不到时才回退 `src-git`（每次 `feeds update -a` 拉远端 main）。

```bash
OW=$HOME/openwrt
SUITE=$HOME/openwrt-suite
cd "$OW"

# 1) feeds update 之前：把 suite 放到 feeds 配置第一条
bash "$SUITE/diy/00-feeds-order.sh" "$OW"

# 2) 更新并安装 feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 3) feeds install 之后：官方 packages feed 现场补丁（Rust LLVM / Golang GOAMD64）
bash "$SUITE/diy/01-feed-patches.sh" "$OW"

# 4) 首次接入时写入配置快照并展开（已有 .config 请跳过 cp，避免覆盖）
cp -f "$SUITE/config/dot.config" .config
make defconfig

# 5) .config 就绪之后：内核配置补丁（NETKIT / X86_NATIVE_CPU / X86_SGX）
bash "$SUITE/diy/02-kernel-config.sh" "$OW"

# 6) 按需勾选，然后下载、编译
make menuconfig
make download
make -j"$(nproc)"
```

这条路径不含 `compile.sh` 的下列环节，需要自行处理：

| `compile.sh` 的环节 | 纯手工时的后果 |
|---|---|
| `verify_feed_priority()` | 旧构建树里已装过的官方同名包（nqptp、v2ray-geodata、ddns-go、dae）会被 `feeds install -a` 跳过，仍指向官方版本 |
| `clean_stale_artifacts()` | 改了 Rust LLVM / GOAMD64 / 内核配置后，已有 `build_dir` 缓存不清理，新设置可能不生效 |
| `ensure_honk_toolchain()` | `.config` 选中 honk 时，宿主机缺 Zig / bpf-linker 会在编译阶段失败，安装步骤见「宿主机依赖」 |
| `CONFIG_URL` / `REFRESH_CONFIG` / `SKIP_*` | 没有对应开关，配置来源与跳过项要自己控制 |

### 仅挂载 feed 的最小示例

验证 feed 能否被 OpenWrt 扫描到，几行命令即可（**不含** `.config` 快照、三处现场补丁与编译）：

```bash
git clone https://github.com/openwrt/openwrt.git && cd openwrt
echo 'src-git suite https://github.com/NetForgeCN/openwrt-suite.git' | cat - feeds.conf.default > t && mv t feeds.conf.default
./scripts/feeds update -a && ./scripts/feeds install -a
make defconfig && make menuconfig
```

`src-git` 拉的是远端 main 而非本地快照；包会出现在菜单里但默认未选中。要真正编译固件请用方式一或方式二。

## 收录的包

以下包在 menuconfig 中的位置按各包 Makefile 的 `CATEGORY` / `SUBMENU` 归类：

| 菜单路径 | 包 |
|---|---|
| LuCI → 3. Applications | luci-app-airplay2、luci-app-argon-config、luci-app-atomdns、luci-app-daeuniverse、luci-app-ddns-go、luci-app-diskman、luci-app-hevsocks5、luci-app-kixdns、luci-app-lucky、luci-app-mosdns、luci-app-nikki、luci-app-oaf、luci-app-open_nexttrace、luci-app-oxidns、luci-app-photondns、luci-app-photondns-compat、luci-app-pulse、luci-app-temp-status |
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

<a id="build"></a>

## 编译固件

NetForgeCN 提供三套 OpenWrt x86-64 固件构建仓库，编译入口不同，产物都是固件 Release。三份 `.config` 由使用者自行维护；构建脚本不会改写仓库里的 `config/dot.config` 快照，只在本地构建树生成并展开 `.config`。

| 仓库 | 编译方式 | 编译入口 |
|---|---|---|
| [openwrt-suite](https://github.com/NetForgeCN/openwrt-suite#build) | 聚合 feed + 一键脚本 | `build/compile.sh`、`build.yml` |
| [OpenWRT](https://github.com/NetForgeCN/OpenWRT#build) | GitHub Actions 分步编排 | `OpenWRT.yml` + `diy-part1.sh` / `diy-part2.sh` |
| [OpenWrt-ScriptBuild](https://github.com/NetForgeCN/OpenWrt-ScriptBuild#build) | 单脚本全流程 | `compile.sh`、`build.yml` |

三个仓库的完整编译说明见各自 README 的「编译固件」章节（上表链接）。

### 本仓库：一键构建

```bash
cd openwrt-suite
bash build/compile.sh
```

脚本自动完成：克隆/更新 OpenWrt → 配置 feeds → `feeds update/install` → 打官方 feed 补丁 → 写入 `.config` → 打内核补丁 → 下载 → 编译。脚本自动识别自身所在的 suite 仓库，本次 clone 的本地修改直接生效；显式设置 `SUITE_DIR` 可改用另一份检出。

`--help` 查看全部可配置项，`--jobs N` 指定并行任务数，`--menuconfig` 只准备到可配置状态并打开 menuconfig。常用环境变量：`WORKDIR`（OpenWrt 源码树，默认 `~/openwrt`）、`SUITE_DIR`（默认脚本所在的本仓库，通常无需设置）、`CONFIG_URL`、`JOBS`、`SKIP_UPDATE=1`、`SKIP_DOWNLOAD=1`、`SKIP_BUILD=1`（只准备不编译）、`REFRESH_CONFIG=1`、`GO_AMD64_LEVEL`、`HONK_TOOLCHAIN_AUTO`。

### 本仓库：每日固件构建（GitHub Actions）

`.github/workflows/build.yml` 每天**北京时间 02:45** 用 `build/compile.sh` 出一版 x86-64 固件并发布 Release（保留最近 7 个，artifact 保留 3 天），支持手动 `Run workflow`。构建使用独立 cron：同步失败不阻塞出固件，当晚沿用前一天的快照。`.github/workflows/sync.yml` 每天 02:30 以 `SUITE_SYNC_UPDATE=1` 解析上游分支头、更新 pin 后同步快照。两个 workflow 都设了 `timeout-minutes`，第三方 Action 全部钉到 commit SHA，`build` 作业只读、`release` 作业才有写权限，`sync` 作业只有 `contents: write`；构建与清理都禁止并发取消，且清理会跳过 `backup-pre-audit-*` 备份发布。

构建直接使用 workflow 所在提交的 suite（脚本、`packages/`、`config/dot.config` 同源）：`SUITE_DIR` 指向本次 checkout，`00-feeds-order.sh` 检测到它是本地 suite 仓库就写 `src-link suite <构建树/feeds/.suite-local>`，该目录里只有一个 `packages` 软链指向 checkout 的 `packages/`。`feeds update -a` 把它挂成 feed，包快照与配置严格同属一个提交。只暴露 `packages/` 一层：`scan.mk` 用 `find -L` 递归扫整个 feed 目录，只挂一个干净的 `packages` 软链可以让扫描范围精确可控。本地手动跑 `compile.sh` 时脚本会自动识别自身所在检出，行为一致。

缓存分三类：dl（key 绑 `dot.config` / `compile.sh`）、staging_dir 工具链（含 photondns 需要的 rust/host）、ccache（key 带 run_id）。热构建约 3~3.5 小时；首次冷构建耗时更长，可先手动触发一次预热缓存。`honk` 的宿主机工具链由 `compile.sh` 里的 `ensure_honk_toolchain` 按 `.config` 自动准备：版本与 hash 按当前 `HONK_SRC_VERSION` 动态解析，网络失败时回退本地 pin，不选 honk 则整段跳过（详见「宿主机依赖（honk 核心专用）」）。

## 工作原理

```
git clone 本仓库  ──►  一个标准 OpenWrt feed（顶层 packages/ 里每个目录 = 一个包）
                              │
              feeds.conf 首行 src-link suite <本地检出>（回退时 src-git <url>）
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

OpenWrt 的 `feeds install -a` 对同名包按 feeds.conf 中的**出现顺序**取先到者。官方 packages feed 也有 `nqptp`、`v2ray-geodata`、`ddns-go`、`dae` 等同名包，`diy/00-feeds-order.sh` 把 suite 行插到所有官方 feed 之前，因此这些包始终使用本仓库版本。脚本会自动识别自身所在的 suite 仓库并写入 `src-link suite <构建树/feeds/.suite-local>`；也可用 `SUITE_DIR` 显式指定另一份检出。只有识别不到仓库结构（例如把脚本单独复制到别处执行）时才回退 `src-git suite <URL>`。`src-link` 指向的是一个只含 `packages` 软链的干净目录（链到 `SUITE_DIR/packages`），`feeds update -a` 会 `ln -s` 该目录并照常生成 index。`compile.sh` 的同名包校验以 `feeds/suite/packages` 的真实路径为基准，两种接入方式行为一致。

`compile.sh` 在每个包安装后还会逐包解析 `package/feeds/*/` 链接的真实指向：凡是指向非 `feeds/suite` 的（包括悬空链接），一律清掉并从 suite 重装，最后复核一遍，不一致直接报错退出。

### 纯快照同步

`scripts/sync.sh` 每次对每个源**先删后拷**（不 rsync 增量、不带 .git），路径映射由 `sources.conf` 显式声明三种模式：

| 模式 | 适用 | 例子 |
|---|---|---|
| `pkg`  | 包目录在仓库的一层或多层子目录下（根目录无 Makefile） | sirpdboy/luci-app-ddns-go → `luci-app-ddns-go/` + `ddns-go/`；NetForgeCN/luci-app-atomdns → `luci-app-atomdns/` |
| `all`  | Makefile 在仓库根目录 | jerrykuku/luci-theme-argon → `luci-theme-argon/` |
| `file` | 大仓库里的单个文件 | NetForgeCN/OpenWRT 的 `.config` → `config/dot.config` |

`pkg` 的 payload 可以写上游内的**子路径**，目标目录取它的 basename，用来对付「包目录藏在子目录里」的上游（如 c2h2/luci-app-photondns 的 `openwrt/photondns`）。只含一个包目录的上游（如 atomdns）同样走 `pkg`，payload 只写一个目录，仓库根的 README / LICENSE 不会被当成包；许可证放在包目录内的随快照拷入，放在仓库根的另由 `copy_meta` 收进 `meta/<slug>/`。每个源同步后强制校验 `Makefile` 存在，任何失配（上游重构、删库、改默认分支）都会让同步失败报红。每次同步把上游 commit 记入 `sources.lock`。

`packages/` 下的内容由上游决定，快照定制用 `patches/<slug>.sh`（当前有 `photondns.sh`、`geodata.sh`）。`renovate.json` 忽略 `packages/!(v2ray-geodata)/**` / `meta/**` / `config/**` / `sources.conf` / `sources.lock`：其余快照仍由同步流程管理，`v2ray-geodata` 不再被忽略（将来该包内出现 Actions / 依赖也能由 Renovate 更新）。

### 版本锁定与可复现

`sources.conf` 只描述「从哪里取、取什么」；**`sources.lock` 中 40 位 commit SHA 才是唯一信任锚**。默认 `bash scripts/sync.sh` 只按 lock 中的 pin 抓取（`git fetch --depth 1 origin <sha>` 并核对 HEAD），显式 `SUITE_SYNC_UPDATE=1` 才会 `ls-remote` 解析分支头、写入新 pin 后同步。所有网络访问强制无凭据 HTTPS、带超时与重试；`mode=file` 用 commit SHA 拼 `raw.githubusercontent.com` 内容寻址 URL，不再跟分支头漂移。

同步结果先写入仓库内 staging 目录，对 `packages/`、`meta/`、文件映射和新 lock 跑完整 `scripts/validate.sh`，通过后才替换工作树；发布后校验失败会整体回滚，绝不留下半个快照。`sources.lock` 的字段布局未变（`slug|40位SHA|UTC时间戳|URL`）。

构建用的所有第三方代码严格等于本仓库快照；可追溯、可回滚（git 历史），上游删库 / force-push / 投毒均不影响已发布的快照。`compile.sh` 默认用 suite 提交的提交时间设置 `SOURCE_DATE_EPOCH`，并用 `gzip -n` 去掉归档时间戳；`mihomo-*` 的 `PKG_BUILD_TIME` 与 `v2ray-geodata` 的 `PKG_VERSION` 也遵循该变量。`v2ray-geodata` 的规则数据与 SHA256 由仓库根 `geodata.pin` 唯一真源决定，同步时注入 Makefile，不再使用 `releases/latest`。

## 各包构建说明

### v2ray-geodata

同步源是自建仓库 [NetForgeCN/Loyalsoldier](https://github.com/NetForgeCN/Loyalsoldier)（仓库内只有一份 Makefile）。规则数据来自自建规则仓库 [NetForgeCN/v2ray-rules-dat](https://github.com/NetForgeCN/v2ray-rules-dat) 的**固定 release**（当前 tag 见仓库根 `geodata.pin`，全量 `geoip.dat` + `geosite.dat`，另加反广告 / Cats-Team AdRules / neodevhost 列表）。

**`geodata.pin` 是 tag 与两个 SHA256 的唯一真源**，格式只有 `TAG` / `GEOIP_SHA256` / `GEOSITE_SHA256` 三项。`.github/workflows/bump-geodata.yml` 每天 UTC 18:15（北京 02:15，早于 daily-sync 18:30）查询 `releases/latest`，从 `geoip.dat.sha256sum` / `geosite.dat.sha256sum` 读取哈希；四个资产必须齐全、哈希必须是 64 位小写 hex，否则直接失败且不改旧值。校验通过后只更新 `geodata.pin` 并用 `patches/geodata.sh` 把新值幂等注入 `packages/v2ray-geodata/Makefile` 后提交推送。`scripts/sync.sh` 在每次同步时同样从 `geodata.pin` 重打 Makefile，已打补丁的 Makefile 会被刷新到当前 pin；重复执行不会改变结果。

`Build/Compile` 强制 HTTPS、超时并用内置哈希校验；下载 URL 始终是 `releases/download/<tag>/...` 的固定 tag 形式，不用 `releases/latest`（该标签可能指向只含备份资产的 release 而 404），也不再从同源现取 `.sha256sum`。**不需要也不应该手动同时改多处 tag / 哈希**：日常升级只需自动 bump，人工干预只改 `geodata.pin`（随后跑一次 `bash patches/geodata.sh packages/v2ray-geodata`）。

该包目录只有 Makefile（头部为 GPL-3.0 声明），`PKG_LICENSE_FILES:=LICENSE` 是上游写法。`PKG_VERSION` 跟随 `SOURCE_DATE_EPOCH`（UTC），同一 suite 提交得到同一版本。

### daeuniverse（原 honk）

上游 [QiuSimons/luci-app-daeuniverse](https://github.com/QiuSimons/luci-app-daeuniverse) 是**一个仓库三个包**（2026-11-27 由 `luci-app-honk` 原地改名并整合 dae 而来，feed slug 仍叫 `honk` 以保持工具链路径不变）：

| 目录 | 包 | 内容 |
|---|---|---|
| `honk/` | honk | 从 `daeuniverse/honk` 指定 commit 编译出的 `honk-core` |
| `dae/` | dae | 从 `olicesx/dae` 的 kdae 分支指定 commit 编译（不再用 AF_XDP） |
| `luci-app-daeuniverse/` | luci-app-daeuniverse | 共享的 `init.d/daeuniverse`、UCI `/etc/config/daeuniverse`、LuCI 页面、rpcd ucode 后端、Doona 面板 |

两个核心共用一套 UCI 与服务脚本，由 `option core honk|dae` 选择启动哪个；menuconfig 的 `DAEU_WITH_HONK` / `DAEU_WITH_DAE` 决定编译期打包哪些核心（默认都开）。旧的 `luci-app-honk` 与独立的 `luci-app-dae`（kix 分支，仓库已归档）均已移除，避免同名 `dae` 包冲突。

仓库根目录还有 `scripts/`、`PIC/`、`.github/`，这些不参与构建；**根目录没有 Makefile**，所以按 `mode=pkg` 只拷这三个目录。三个目录内部没有任何 `../` 跨目录引用，可以独立编译。

> 升级提示：新包不再读取 `/etc/config/honk` 与 `/etc/dae/`。旧配置需手工迁移——UCI section `honk`/`dae` 合并为 `daeuniverse` 并设 `option core`，配置文件分别搬到 `/etc/daeuniverse/honk/` 与 `/etc/daeuniverse/dae/config.d/`（新版 dae 是 6+1 文件结构，与旧 kix 的 3 文件不同，不能直接照搬）。

`honk-core` 不是在 OpenWrt 里交叉编译的：`honk/build_honk_core.sh` 调用宿主机上的 **Rust / cargo / Zig / bpf-linker**（版本由上游 `.github/ci/pins.env` 与 release.yml 钉住），产物写到 `honk/files/honk-core.bin`；该文件被上游 `.gitignore` 忽略，快照里不带它。两条路：

1. 宿主机装好工具链后编译（需能访问 crates.io、ziglang.org、aya-rs releases）；
2. 把已生成的 `honk-core.bin` 放进 `package/feeds/suite/honk/files/`。`honk/Makefile` 的 `Build/Compile` 内置 `build_honk_core.sh --if-needed`，没有 `.stamp` 时会把现成的 `.bin` 当作预编译产物直接复用。`--if-needed` 由 Makefile 传入；`build/compile.sh` 接受 `--help` / `--jobs` / `--menuconfig`。

#### 宿主机依赖（honk 核心专用）

`honk-core` 是**在宿主机上**用 Rust + Zig 编译后再塞进 ipk 的，所以每台构建机（含 GitHub Actions runner）都要备好这套工具。`build_honk_core.sh` 用 `zig version` 严格比对版本（不等就 `exit 1`），所有资产下载后仍强制 `sha256sum -c`。

##### 动态解析（默认）

权威解析器是仓库本地的 `scripts/honk_toolchain.sh`（**不要放到 `packages/honk/`**：daily-sync 会用上游文件覆盖该目录）。它按当前 `HONK_SRC_VERSION`（取自 `packages/honk/Makefile` 的 `HONK_SRC_URL` / `HONK_SRC_VERSION`）从该 commit 的 `.github/ci/pins.env` 读取 `BPF_LINKER_VERSION` / `BPF_LINKER_SHA256`，并从该 commit 的 `.github/workflows/release.yml` 读取 setup-zig 的 `version`；zig 资产 hash 再按版本从 `https://ziglang.org/download/index.json` 的 `x86_64-linux` / `aarch64-linux` 条目读取。上游自 2026-11 起把 zig 改为 latest（release.yml 里已无 setup-zig pin），此时 bpf-linker 仍从上游 `pins.env` 取、zig 版本回落到本仓库的本地 pin（0.14.1）；日志会明确提示。`build/compile.sh` 调用的就是这份本地脚本，**上游升级 honk commit 后不需要手改本仓库的版本常量或 4 个 hash**，daily-sync 覆盖 `packages/honk/honk_toolchain.sh` 也不影响。解析成功时日志会打印来源（`upstream` / `zig-index`）和版本。

优先级：**显式环境变量 > 上游动态解析 > 本地回退 pin**。显式设置时以下变量直接生效：

| 变量 | 作用 |
|---|---|
| `HONK_ZIG_VERSION` / `HONK_BPF_LINKER_VERSION` | 强制版本（覆盖上游 pin） |
| `HONK_ZIG_SHA256_X86_64` / `HONK_ZIG_SHA256_AARCH64` | 强制 zig 资产 hash |
| `HONK_BPF_LINKER_SHA256_X86_64` / `HONK_BPF_LINKER_SHA256_AARCH64` | 强制 bpf-linker 资产 hash（`HONK_BPF_LINKER_SHA256` 是 x86_64 的旧别名） |
| `HONK_SRC_URL` / `HONK_SRC_VERSION` / `HONK_MAKEFILE` | 指定解析所用的上游源 / Makefile（一般无需设置） |
| `HONK_ZIG_INDEX_URL` | 指定 zig 官方索引地址（离线测试用） |
| `HONK_TOOLCHAIN_AUTO` | `1` = 让脚本自动安装工具链（需要 sudo） |

##### 离线回退（本地保存的 pin）

网络不可达、上游解析失败或 Makefile 缺失时自动回退到下面这份本地 pin（对应当前 `HONK_SRC_VERSION`），离线 VM 仍能正常本地编译；回退时日志明确写出 `local-fallback` / `local-default`。

| 组件 | 回退版本 | sha256（按宿主机架构选） |
|---|---|---|
| Zig | `0.14.1` | x86_64 `24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c`；aarch64 `f7a654acc967864f7a050ddacfaa778c7504a0eca8d2b678839c21eea47c992b` |
| bpf-linker | `0.11.0` | x86_64 `10f62ba9ab7e544d538370552660efcb4f1a19153d5752bbf0f6b51f3bada450`（与上游 pins.env 同值）；aarch64 `d09ddd83303e9ab1443f51e0e284680154009646a3ce141c63d838ee61b73eb9`（本地保存） |
| Rust | 任意 rustup 稳定版 | eBPF 部分脚本会自动 `rustup toolchain install nightly --component rust-src,llvm-tools` |

**guard**：版本升级但对应 hash 仍是上表旧默认值时直接报错，绝不拿旧 hash 校验新资产。上游 `pins.env` 只发布 x86_64 的 bpf-linker hash，所以 aarch64 宿主机升级 bpf-linker 版本时必须显式设置 `HONK_BPF_LINKER_SHA256_AARCH64`；zig 两个架构的 hash 升级后由官方 index.json 自动提供。

##### 手工安装（可选）

先在有网机器上看当前解析结果（输出可直接搬到离线机器用）：

```bash
bash scripts/honk_toolchain.sh packages/honk/Makefile
```

Debian / Ubuntu 宿主机可用下面这段一次装好（把版本/hash 换成上面命令的输出）：

```bash
# ARCH 按 uname -m 选 x86_64 / aarch64；ZIG_VERSION / BPF_VERSION / ZIG_SHA / BPF_SHA
# 来自 honk_toolchain.sh 的 ZIG_VERSION / BPF_LINKER_VERSION / HONK_ZIG_SHA256_* / HONK_BPF_LINKER_SHA256_*
sudo apt-get install -y clang llvm libbpf-dev cmake libclang-dev zstd \
  make perl file binutils git curl xz-utils pkg-config ca-certificates
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
. "$HOME/.cargo/env"
curl --proto '=https' --tlsv1.2 -fsSL -o /tmp/bpf-linker.tar.zst \
  "https://github.com/aya-rs/bpf-linker/releases/download/v\${BPF_VERSION}/bpf-linker-\${ARCH}-unknown-linux-musl.tar.zst"
echo "\$BPF_SHA  /tmp/bpf-linker.tar.zst" | sha256sum -c -
sudo tar --zstd -xf /tmp/bpf-linker.tar.zst -C /usr/local/bin
curl --proto '=https' --tlsv1.2 -fsSL -o /tmp/zig.tar.xz \
  "https://ziglang.org/download/\${ZIG_VERSION}/zig-\${ARCH}-linux-\${ZIG_VERSION}.tar.xz"
echo "\$ZIG_SHA  /tmp/zig.tar.xz" | sha256sum -c -
sudo tar -xJf /tmp/zig.tar.xz -C /usr/local
sudo ln -sf "/usr/local/zig-\${ARCH}-linux-\${ZIG_VERSION}/zig" /usr/local/bin/zig
zig version && bpf-linker --version && cargo --version
```

`build_honk_core.sh` 会检查工具是否在 PATH、`zig version` 是否等于解析出的版本；Zig / bpf-linker 必须用对应 release 资产（发行版包管理器里的 Zig 通常太旧）。这套工具装在宿主机全局，不随 OpenWrt 构建树或 `staging_dir` 缓存走，换机器需重新准备。

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

### hevsocks5

`hevsocks5` 源指向自有仓库 [NetForgeCN/luci-app-hevsocks5](https://github.com/NetForgeCN/luci-app-hevsocks5)，给官方 `hev-socks5-server` 补一个 LuCI 控制页。仓库根就是包目录（`Makefile` 在根），因此 `mode=all` 整仓拷成 `packages/luci-app-hevsocks5/`，MIT 许可证随快照留在包目录内。

| 项目 | 说明 |
|---|---|
| 依赖不重复 | `LUCI_DEPENDS:=+hev-socks5-server +luci-base`，服务端本体由官方 packages feed 的 `net/hev-socks5-server` 提供；三份 `.config` 已有 `CONFIG_PACKAGE_hev-socks5-server=y`，suite 不再聚合一份同名包 |
| 配置链路 | LuCI 写 UCI `hev-socks5-server.config` → ucitrack 触发 `/etc/init.d/hevsocks5-sync` → `/usr/bin/hevsocks5-ctl generate` 以临时文件 + `mv` 原子替换 `/etc/hev-socks5-server/main.yml`（0600）→ procd 重启服务 |
| 与上游不冲突 | 自带 `hevsocks5-sync` 钩子脚本，不覆盖官方的 `/etc/init.d/hev-socks5-server`，opkg 文件互不占用 |
| 菜单与语言 | LuCI → 3. Applications → `luci-app-hevsocks5`；`po/zh_Hans/` 产出 `luci-i18n-hevsocks5-zh-cn` |

`LUCI_PKGARCH:=all`，界面与 UCI→YAML 渲染脚本与架构无关；首次安装由 `root/etc/uci-defaults/luci-hevsocks5` 写默认值并生成一组随机凭据。是否编进固件由 `.config` 里的 `CONFIG_PACKAGE_luci-app-hevsocks5`（及可选的中文语言包 `luci-i18n-hevsocks5-zh-cn`）决定，配置由使用者自行维护。

## 手动触发同步

- GitHub 仓库页 → Actions → daily-sync → Run workflow（workflow 已设置 `SUITE_SYNC_UPDATE=1`）；或
- 本地执行：`SUITE_SYNC_UPDATE=1 bash scripts/sync.sh`（之后自行 commit / push）

不带 `SUITE_SYNC_UPDATE=1` 的本地执行只会按 `sources.lock` 的固定 pin 重取快照，用于验证/恢复。调试单个源：`SUITE_SYNC_ONLY=geodata SUITE_SYNC_UPDATE=1 bash scripts/sync.sh`（geodata 的 Makefile 会按仓库根 `geodata.pin` 的当前值重打）。规则数据 pin 的自动升级在 GitHub Actions → bump-geodata（每日 UTC 18:15）或手动 Run workflow；备份 release/tag 不受影响。

`scripts/validate.sh` 可单独运行，检查：包目录/Makefile、锁文件 SHA 与时间戳格式、conf/lock 一一对应、目标目录冲突、payload 路径安全、重复包名、define/endif 配对、源码 hash pin、许可证归属、补丁脚本语法与 shell 语法。它也是同步发布前的强制门禁。

## 许可证

**本仓库自身**（`scripts/`、`diy/`、`build/`、文档）以 **MIT** 授权，见 [LICENSE](LICENSE)。

**聚合进来的第三方包**许可证**原样保留**：LICENSE 随快照走——`mode=all` 的包、以及把 LICENSE 放在包目录里的 `mode=pkg` 上游，文件就在 `packages/<name>/LICENSE`；仓库根另外提供 LICENSE / THIRD-PARTY-NOTICES / NOTICE 的 `mode=pkg` 上游（如 `atomdns`）再由 `sync.sh` 额外收进 `meta/<slug>/`。`scripts/validate.sh` 会检查每个源至少有一处许可证/归属（包内 LICENSE/COPYING/NOTICE、`meta/<slug>/` 或 Makefile 的 `PKG_LICENSE` 声明），缺失会让同步失败而不是静默遗漏。快照内容按上游原样分发，`patches/photondns.sh` 把上游仓库根的 Cargo 工程**原样补齐**到包目录（新增文件、不改动任何已有内容），`patches/geodata.sh` 从仓库根 `geodata.pin` 注入规则数据 release 与哈希。MIT 只覆盖本仓库自己的脚本与文档；每个 `packages/<name>/` 下的代码按它自己的许可证分发，装机时以包内 LICENSE 或 `meta/<slug>/LICENSE` 为准。
