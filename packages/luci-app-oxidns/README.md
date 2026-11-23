# luci-app-oxidns（NetForgeCN）

[English](./README.en.md)

一个面向 OpenWrt 的 OxiDNS 管理插件。安装后，LuCI 的 `Services -> OxiDNS` 提供内核、配置、服务、日志、规则和预热的完整管理界面。

它在 [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns) 的框架之上，补齐了“**装好即用、升级不丢、常用域名提前解析**”的能力。基于 GPL-3.0-or-later 发布。

## 相比上游增加了什么

| 能力 | 这个版本 | 带来的好处 |
|---|---|---|
| 内核随包分发 | `oxidns-core` 子包在编译期内置官方核心、WebUI 和默认配置 | 刷完固件就有 DNS 能力，首次使用无需联网安装内核 |
| 规则随包分发 | `oxidns-rules-baseline` 子包内置 5 份规则基线 | 首次启动完全离线完成，规则文件缺失时自动补齐 |
| 规则订阅管理 | `Rules` 页检查 / 更新，带 SHA256 校验、暂存校验和回滚 | 一键完成规则升级，替换前先完成校验与暂存 |
| 域名预热 | `Prewarm` 页按 A / AAAA 提前查询并写入缓存 | 常用域名首次访问直接使用缓存，减少等待 |
| 内核在线升级 | `Core` 页 `Check Update` | 不用重新编译固件即可升级内核 |
| 日志筛选 | 关键词 + `plugin` / `qtype` / `rcode` 过滤，实时行数 | 快速定位某类查询，日志再多也能看 |
| API 密码托管 | 密码存 UCI，脚本自动注入 `${OXIDNS_API_PASS}` | 配置里不放明文，服务与网页校验都能正常工作 |
| 升级自愈 | 内核、WebUI、配置和规则在 sysupgrade 后自动恢复 | 保留配置升级固件后，重装一次插件即可恢复服务 |

## 页面一览

| 页面 | 用途 |
|---|---|
| `Overview` | 内核 / 服务状态、WebUI 入口、配置路径、日志状态 |
| `Core` | 安装、上传、升级、修复或移除内核 |
| `Configuration` | 查看、校验、保存 `config.yaml` |
| `Logs` | 过滤和刷新 OxiDNS 日志 |
| `Settings` | 仓库、bundle、代理、路径、日志与 API 密码 |
| `Rules` | 规则基线状态、检查更新、一键更新 |
| `Prewarm` | 预热开关、域名清单、目标地址与周期、手动执行 |

## 快速开始

1. 按下面的“构建与安装”把插件装进固件或路由器。
2. 设置 API 密码，密码只保存在 UCI：

   ```sh
   uci set oxidns.main.api_pass="$(openssl rand -base64 24)"
   uci commit oxidns
   /etc/init.d/rpcd restart
   ```

3. 打开 `Services -> OxiDNS -> Configuration`，按需编辑 `config.yaml`，点 `Save & Restart`。
4. 打开 `Overview`，启动服务并启用开机自启。
5. 打开 `Prewarm`，确认目标地址与 `config.yaml` 中的监听一致，点 `Run now` 立即预热。

## 域名预热（Prewarm）

预热会遍历清单里的每个域名，向指定的 OxiDNS 监听地址发起 A 和 AAAA 查询。查询经过该监听入口的规则链并进入缓存后，客户端首次访问这些域名时就能直接命中。

| 项目 | 默认值 |
|---|---|
| 启用 | 开 |
| 目标 | `udp://127.0.0.1:5333` |
| 周期 | 3000 秒（约 50 分钟） |
| 清单 | 包内默认 89 个域名，可在页面增删 |
| 并发 | 4 |
| 单次查询超时 / 重试 | 2 秒 / 1 次 |

让预热生效只需要三件事：

- `config.yaml` 里有 `cache` 插件，并且它在预热目标入口实际执行的链路上；
- 预热页里的 IP、端口、协议与 `udp_server` / `tcp_server` 的 `listen` 一致；
- 路由器上有 `dig`，或支持 `-port` 的 `nslookup`。

页面上的 `Server IP` 可选 `127.0.0.1` 或 `192.168.1.1`；端口和协议可自由填写。`Run now` 不受总开关影响，可随时手动执行一轮。周期填 `0` 表示服务启动时执行一次。

验证预热：

```sh
logread -t oxidns-prewarm              # 查看每轮结果
/usr/libexec/oxidns-prewarm --once     # 手动执行一轮
dig @127.0.0.1 -p 5333 youtube.com A   # 验证监听口在应答
```

## 规则基线

基线只包含 OxiDNS 实际加载的 5 份列表，构建时从上游拉取并校验，设备中不需要再做格式转换：

| 文件 | 用途 |
|---|---|
| `cn-domains.txt` | 国内域名长尾，配合 geosite 判定国内组 |
| `anti-ad-domains.txt` | anti-AD 域名表 |
| `adrules-domains.txt` | AdRules 域名表 |
| `neodevhost-domains.txt` | neoDevHost 域名表 |
| `adguard-hostlist.txt` | AdGuard HostlistsRegistry 规则 |

`cn-domains.txt` 由 dnsmasq-china-list 在构建机上转换生成，原始 conf 不随包分发。规则更新由 `Rules` 页统一处理，先校验再替换；校验不通过时自动保留上一版。

## 构建与安装

### 方式一：OpenWrt buildroot（推荐，可编进固件）

```sh
git clone https://github.com/openwrt/openwrt.git
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a

git clone https://github.com/NetForgeCN/luci-app-oxidns.git package/luci-app-oxidns
make menuconfig
# LuCI -> Applications -> luci-app-oxidns
make package/luci-app-oxidns/compile V=s
```

`oxidns-core` 和 `oxidns-rules-baseline` 是硬依赖，选中插件会一起选中。产物在 `bin/packages/<架构>/`。

支持 x86_64、aarch64、i386、ARM hard-float（cortex 映射 armv7，其余映射 armv6）。MIPS 等未发布 musl 内核的架构可不选 `oxidns-core`，再用页面上传内核。

### 方式二：快速打包

需要 `node`、`tar`、`gzip`、`sha256sum`：

```sh
git clone https://github.com/NetForgeCN/luci-app-oxidns.git
cd luci-app-oxidns

# 只打插件，内核到页面安装
./scripts/build-luci-package.sh 0.2.0 dist

# 内置内核 + 规则基线（按路由器架构选 release 资产）
curl -LO https://github.com/svenshi/oxidns/releases/download/v1.7.1/oxidns-x86_64-unknown-linux-musl.tar.gz
curl -LO https://github.com/NetForgeCN/luci-app-oxidns/releases/download/rules-v2026.11.17.0223/oxidns-rules-baseline-2026.11.17.0223.tar.gz
./scripts/build-luci-package.sh 0.2.0 dist-embedded \
	oxidns-x86_64-unknown-linux-musl.tar.gz \
	oxidns-rules-baseline-2026.11.17.0223.tar.gz
```

安装：

```sh
opkg install luci-app-oxidns_*.ipk
opkg install luci-i18n-oxidns-zh-cn_*.ipk
# apk 系统：
apk add --allow-untrusted ./luci-app-oxidns_*.apk
```

## 持久化与升级

- 内核和 WebUI 放在 `/etc/oxidns/core/`，运行路径是符号链接；
- `/etc/oxidns`、`/etc/config/oxidns` 加入 `/etc/sysupgrade.conf`，配置跨固件升级保留；
- 开机时自动补齐缺失的符号链接和规则文件；
- 升级固件时勾选“保留配置”，刷完重装一次插件即可恢复服务；
- 内核升级用 `Core -> Check Update`，规则升级用 `Rules` 页，二者互不影响。

## 默认路径

| 用途 | 路径 |
|---|---|
| 内核（运行 / 持久） | `/usr/bin/oxidns` → `/etc/oxidns/core/oxidns` |
| WebUI（运行 / 持久） | `/usr/share/oxidns/webui` → `/etc/oxidns/core/webui` |
| 核心配置 | `/etc/oxidns/config.yaml` |
| 工作目录 | `/var/lib/oxidns` |
| UCI 配置 | `/etc/config/oxidns` |
| 规则基线（只读） | `/usr/share/oxidns/rules-baseline` |
| 规则工作副本 | `/etc/oxidns/rules` |
| 预热清单 | `/etc/oxidns/prewarm.txt` |
| 服务脚本 | `/etc/init.d/oxidns` |

## 许可与致谢

GPL-3.0-or-later，详见 [LICENSE](LICENSE)。基于 [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns) 和 [svenshi/oxidns](https://github.com/svenshi/oxidns) 构建，感谢上游作者的贡献。
