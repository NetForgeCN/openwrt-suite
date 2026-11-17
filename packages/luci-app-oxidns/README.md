# luci-app-oxidns

语言：中文 | [English](./README.en.md)

`luci-app-oxidns` 是 OxiDNS 的 OpenWrt / LuCI 管理插件。安装后，LuCI 会出现 `Services -> OxiDNS` 页面，用来安装 OxiDNS 内核二进制、管理 OpenWrt 服务、编辑配置和查看日志。

本仓库在 [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns) 的基础上重新实现，并补齐了三块原版缺失的能力。遵循 GPL-3.0-or-later 开源。

## 与原版的区别

| 能力 | 原版 | 本仓库 |
|---|---|---|
| 内核二进制存放 | `/usr/bin/oxidns`，固件升级即丢 | `/etc/oxidns/core/oxidns`（持久区），运行路径为符号链接 |
| 配置文件 | 升级固件后默认丢失 | 写入 `/etc/sysupgrade.conf`，勾选"保留配置"升级不丢 |
| 升级固件后恢复 | 重新下载内核 + 重新粘贴配置 | 自动重建符号链接，重装一次插件包即恢复 |
| 内核升级 | LuCI 无入口，需去内核自带 WebUI/API | `Core` 页 `Check Update` 一键检查并升级 |
| 日志 | 只能整页翻看 | 支持关键词 + `plugin` / `qtype` / `rcode` 字段过滤 |
| 低闪存设备 | — | `Settings` 可关闭持久化，退回原版行为 |
| 规则订阅（国内表 / 广告表） | 首启必须联网下载 6 份列表，缺一份服务起不来 | `oxidns-rules-baseline` 包内置基线，启动前本地补齐；`Rules` 页从仓库 release 检查并更新 |

## 从源码构建

### 方式一：OpenWrt buildroot / SDK 编译（推荐，可集成进固件）

```sh
# 1. 准备 OpenWrt 构建环境（版本需与目标固件匹配）
git clone https://github.com/openwrt/openwrt.git
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a

# 2. 把本仓库克隆为 package（自带 oxidns-core 子包）
git clone https://github.com/NetForgeCN/luci-app-oxidns.git package/luci-app-oxidns

# 3. menuconfig 中选中（LuCI -> Applications -> luci-app-oxidns；oxidns-core 与
#    oxidns-rules-baseline 是硬依赖，会随它自动选中）
make menuconfig

# 4. 编译
make package/luci-app-oxidns/compile V=s
```

**自带核心**：本仓库包含 `oxidns-core` 子包，`luci-app-oxidns` 在 buildroot 中默认依赖它。编译时会根据目标架构自动下载对应的官方 OxiDNS release（下载地址与 SHA256 固化在 `oxidns-core/Makefile`），把内核二进制、WebUI 和默认配置直接打进固件/ipk。装好的系统**开箱即有核心**，第一次使用不需要手动下载，直接到 `Overview` 启动服务即可；之后仍可在 `Core` 页用 `Check Update` 升级到任意新版本（运行时升级不受编译期固定版本的限制）。

**自带规则**：本仓库同时包含 `oxidns-rules-baseline` 子包（规则基线，同样编译期从本仓库 release 下载并固化 `PKG_HASH`），`luci-app-oxidns` 对它也是硬依赖。刷完固件 `/usr/share/oxidns/rules-baseline` 就有 7 份完整列表，包安装时和每次启动前都会把缺失的文件补到 `/etc/oxidns/rules`，因此**首启完全不联网**；要更新再到 `Services -> OxiDNS -> Rules` 页检查/更新。

- 支持架构：x86_64、aarch64、i386（i686 二进制）、ARM hard-float（cortex 系列映射 armv7，其余映射 armv6）。
- 不支持架构（如 MIPS）：buildroot 中不勾选 `oxidns-core` 也可以单独编译 `luci-app-oxidns`，再用页面里的 `Install Core` 手动安装。
- 升级核心版本：改 `oxidns-core/Makefile` 里的 `PKG_VERSION` 和对应 `PKG_HASH` 后重新编译。

编译产物在 `bin/packages/<架构>/` 下：`oxidns-core_*.ipk`、`oxidns-rules-baseline_*.ipk`、`luci-app-oxidns_*.ipk` 和 `luci-i18n-oxidns-zh-cn_*.ipk`。在 menuconfig 里直接勾选 `<*>` 也可以把插件、核心和规则基线**一起编进固件镜像**，这样升级固件后连插件重装这一步都省了。

### 方式二：无 SDK 快速打包（只出安装包）

适合不想拉整套 OpenWrt 源码、只想快速拿到 ipk/apk 的场景，需要 `node`、`tar`、`gzip`、`sha256sum`：

```sh
git clone https://github.com/NetForgeCN/luci-app-oxidns.git
cd luci-app-oxidns

# 普通包（安装后需在 LuCI 页面下载核心）
./scripts/build-luci-package.sh 0.2.0 dist

# 内嵌核心包（把官方 release tar.gz 打进 ipk，安装时自动解包到持久区，开箱即用）
curl -LO https://github.com/svenshi/oxidns/releases/download/v1.6.1/oxidns-x86_64-unknown-linux-musl.tar.gz
./scripts/build-luci-package.sh 0.2.0 dist-embedded oxidns-x86_64-unknown-linux-musl.tar.gz

# 内嵌核心 + 内嵌规则基线（第四个参数是基线 tar.gz，取自 oxidns-rules-baseline/Makefile
# 里 PKG_SOURCE_URL/PKG_HASH 指向的 release 资产；不打进去的话这台机器上没有基线包，
# 首次启动就没有规则文件）
curl -LO https://github.com/NetForgeCN/luci-app-oxidns/releases/download/rules-v2026.11.17.0223/oxidns-rules-baseline-2026.11.17.0223.tar.gz
./scripts/build-luci-package.sh 0.2.0 dist-embedded oxidns-x86_64-unknown-linux-musl.tar.gz \
	oxidns-rules-baseline-2026.11.17.0223.tar.gz
```

内嵌核心时请按目标路由器的 CPU 架构选择 release 资产（x86_64 / aarch64 / armv7 / i686），此时包虽然仍是 `_all` 后缀，但**只能在对应架构上使用**。安装时 postinst 会自动把核心解包到 `/etc/oxidns/core` 并建好符号链接，`Core` 页会显示已安装。规则基线内嵌后落在 `/usr/share/oxidns/rules-baseline`，首次启动时由 `/etc/init.d/oxidns` 复制到 `/etc/oxidns/rules`。

### 路由器上安装

```sh
# ipk（旧版 opkg 系统）
opkg install luci-app-oxidns_0.2.0-r1_all.ipk
opkg install luci-i18n-oxidns-zh-cn_0.2.0-r1_all.ipk

# apk（新版 OpenWrt）
apk add --allow-untrusted ./luci-app-oxidns_0.2.0-r1_all.apk
apk add --allow-untrusted ./luci-i18n-oxidns-zh-cn_0.2.0-r1_all.apk
```

安装完成后浏览器打开 LuCI 的 `Services -> OxiDNS`：

1. **方式一（buildroot）或方式二内嵌核心编译的包**：核心已在包里，直接到 `Configuration` 页编辑 `config.yaml` → `Save & Restart`，再到 `Overview` 页 `Start` + `Start on boot`；
2. **普通包**：先到 `Core` 页 `Install Core`（自动按 CPU 架构下载并校验 SHA256；离线环境用 `Upload Core`），再执行上面的配置和启动步骤。

## 编译产物安装后的行为

这个版本解决的核心问题是：**原版固件升级后内核和配置全丢，DNS 服务失效导致断网**。本仓库的实现：

- **开箱自带核心（编译期）**：buildroot 方式编译会通过 `oxidns-core` 子包把官方内核打进固件/ipk；快速打包加第 3 个参数也会内嵌核心。装上即有 DNS 能力，第一次使用不需要任何下载。
- **核心持久保存**：内核二进制和 WebUI 安装到持久分区 `/etc/oxidns/core/`，`/usr/bin/oxidns` 与 `/usr/share/oxidns/webui` 是指向它的符号链接。固件升级（勾选保留配置）后内核原样保留。
- **配置持久保存**：安装时自动把 `/etc/oxidns`、`/etc/config/oxidns` 追加进 `/etc/sysupgrade.conf`，`config.yaml` 和 UCI 设置升级后不丢。
- **开机自愈**：init 脚本、rpcd 状态查询、插件 postinst 三个时机检测符号链接，丢失即自动从持久区重建。固件升级后只需重装一次插件包（`opkg install` 一下），服务即恢复，无需重新下载内核、无需重新粘贴配置。
- **LuCI 内核更新**：`Core` 页 `Check Update` 对比当前版本与 GitHub 最新 release，确认后自动下载（含 SHA256 校验）、替换、重启服务。
- **日志字段过滤**：`Logs` 页支持关键词过滤和 `plugin`（log_cache / log_blocked / log_abroad 等）、`qtype`、`rcode` 下拉筛选，实时显示筛选后行数。

## 固件升级操作步骤

1. LuCI → System → Backup / Flash Firmware，**勾选"保留配置"**；
2. 刷入新固件；
3. 升级完成后重新安装一次本插件的 ipk/apk（插件自身文件会被 sysupgrade 清除，这是 OpenWrt 机制）；
4. 完成。postinst 会自动重建内核符号链接，OxiDNS 服务照常运行，配置原样保留。

不勾选"保留配置"则所有数据都会被清除，这是 OpenWrt 机制本身的行为。

## 默认路径

- 二进制（运行时）：`/usr/bin/oxidns`（符号链接）
- 二进制（持久化）：`/etc/oxidns/core/oxidns`
- WebUI（运行时）：`/usr/share/oxidns/webui`（符号链接）
- WebUI（持久化）：`/etc/oxidns/core/webui`
- 配置：`/etc/oxidns/config.yaml`
- 工作目录：`/var/lib/oxidns`（tmpfs，重启清空，仅运行时数据）
- 服务脚本：`/etc/init.d/oxidns`
- 规则基线（只读）：`/usr/share/oxidns/rules-baseline`（`oxidns-rules-baseline` 包）
- 规则工作副本：`/etc/oxidns/rules`（缺失时由启动脚本从基线补齐）

## 已知限制

- 目前只支持 OxiDNS 已发布的 Linux musl release target。
- 低闪存设备（overlay 剩余空间小于内核包体积）请在 `Settings` 关闭 `Persist core across upgrades`，否则安装可能因空间不足失败。
- `Overview` 的 WebUI 入口根据配置文件中的 HTTP listen 地址生成；监听 `127.0.0.1` 时 LuCI 会提示需要本机访问或 SSH 隧道。
- 私有内核仓库或受限网络环境可在 `Settings` 配置 GitHub token 或下载代理（需要 `curl`）。
- 规则基线包解包后约 24MB（7 份列表），是**硬依赖**：`luci-app-oxidns` 的构建依赖里直接写了 `+oxidns-rules-baseline`，选中这个应用就会把基线一起编译进固件。v7 配置已删掉运行期下载/转换链路，没有基线时 OxiDNS 会在 provider 初始化阶段直接退出，因此不能省；闪存紧张时应改用 `geosite` 分流而不是省掉基线。`Rules` 页的更新走本仓库 release 资产，不依赖 jsDelivr/上游仓库的可用性。

## 许可

GPL-3.0-or-later。基于 [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns) 与 [svenshi/oxidns](https://github.com/svenshi/oxidns) 重新实现与扩展，感谢原作者。
