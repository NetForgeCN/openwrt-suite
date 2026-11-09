# sing-box-core

**裸核心跑 sing-box 的 OpenWrt 面板。** 自带新版内核，只把 LuCI 表单渲染成 `config.json`，
不接管防火墙、不拼数据面、不碰系统自带的 sing-box。

一个词概括设计取向：**薄**。插件只负责"把配置写对、把进程看住"，其余全交给 sing-box 自己。

## 裸核心是什么意思

同样是 "sing-box 的 LuCI"，接管型插件和本项目的分工完全不同：

| | 接管型（momo / HomeProxy / Nikki） | 裸核心（本项目） |
|---|---|---|
| 配置来源 | 插件自己的一套 profile 逻辑 | UCI 表单 → `config.json`，一对一 |
| 数据面 | 插件生成 iptables/nft 规则、`ip rule`、DNS 劫持 | sing-box 自己的 `auto_route` / `auto_redirect` |
| 出问题时 | 插件逻辑和内核行为混在一起，只能猜 | 只有一份配置，`sing-box check` 直接给答案 |
| 与 dae 共存 | 停掉后残留什么不可知 | 表 2023 / rule 9100 / 接口 `sbc-tun` 全部已知可清 |
| 升级 sing-box | 受插件版本约束 | 换 `SB_VERSION` 重新编译即可 |

本项目的 `auto_redirect` 会自动往 OpenWrt 的 fw4 表插入兼容规则——也就是说，
"接管型插件帮你做的那部分转发配置"，在 sing-box 1.10 之后核心自己就能做。
插件再做一遍，只是多一层需要同步的中间层。

## 这个包解决什么问题

OpenWrt 官方源的 sing-box 版本通常落后好几个大版本，而 1.12 起配置格式有破坏性变更
（DNS 服务器改为 `type` 判别式、`geosite`/`geoip` 字段移除），1.14 又引入了
`source_mac_address`、`optimistic`、`http_client`。用旧内核跑新配置只会得到一堆
`unknown field` 报错。

所以本项目**自带二进制**，装到 `/usr/libexec/sing-box-core/`，与系统包互不影响。

## 与系统 sing-box 完全隔离

| | 系统包（旧版） | 本插件 |
|---|---|---|
| 二进制 | `/usr/bin/sing-box` | `/usr/libexec/sing-box-core/sing-box` |
| 服务 | `/etc/init.d/sing-box` | `/etc/init.d/sing-box-core` |
| UCI | `/etc/config/sing-box` | `/etc/config/singbox_core` |
| 运行配置 | — | `/var/run/sing-box-core/config.json` |
| 规则集 | — | 运行时拉取，缓存于 `/etc/sing-box-core/cache.db` |

**不需要卸载系统包。** 删除它会破坏 opkg 依赖图（HomeProxy、momo、部分第三方 feed
都写了 `DEPENDS:=+sing-box`），而且固件升级会把旧版重新装回来。走独立路径零副作用。

`DEPENDS` 里刻意不含 `+sing-box`，所以装本插件不会因为版本约束去降级系统包。

## 目录结构

```
sing-box-core/
├── Makefile                              # 按 $(ARCH) 下载对应架构的 musl 静态二进制
├── LICENSE                               # GPL-3.0
├── root/
│   ├── etc/config/singbox_core                  # UCI 默认值（唯一数据源）
│   ├── etc/init.d/sing-box-core                 # procd 服务
│   ├── etc/uci-defaults/90_luci-app-sing-box-core
│   ├── usr/libexec/sing-box-core/
│   │   ├── sing-box                    # 编译时下载的官方二进制
│   │   ├── render.uc                   # UCI -> config.json
│   │   └── apply.sh                    # check -> restart -> 回滚
│   ├── usr/share/luci/menu.d/
│   ├── usr/share/rpcd/acl.d/
│   └── www/luci-static/resources/view/singbox-core/
│       ├── overview.js                 # 状态 / 日志 / 手动应用
│       ├── node.js                     # Hysteria2 / TUIC
│       ├── dns.js                      # DoH 分流 + bootstrap + 缓存
│       └── route.js                    # 分流开关 / TUN / 进程例外
```

## 编译

```sh
# 放进自己的 feed
echo "src-git sbcore https://github.com/NetForgeCN/sing-box-core.git;main" >> feeds.conf.default
./scripts/feeds update sbcore
./scripts/feeds install luci-app-sing-box-core

make menuconfig   # LuCI -> Applications -> luci-app-sing-box-core
make package/luci-app-sing-box-core/compile V=s
```

编译时会从 `github.com/SagerNet/sing-box/releases` 下载对应架构的 **musl 静态**二进制：

- 版本由 Makefile 里的 `SB_VERSION` 控制（默认 1.14.0）
- 架构按 `$(ARCH)` 映射到资产名：`x86_64`→`amd64-musl`、`aarch64*`→`arm64-musl`、
  `arm*`→`armv7-musl`、`i386/486/586/686`→`386-musl`、`mipsel*`→`mipsle-softfloat-musl`、
  `riscv64*`→`riscv64-musl`
- 每个资产的 sha256 写在 `SB_HASH_<资产名>`，由 `download.pl` 校验；升 `SB_VERSION`
  时这几行要一起换（官方没有统一的 hash 清单，只能逐个钉）
- **不要用**不带后缀的 `sing-box-<ver>-linux-<arch>.tar.gz`：那是 glibc 动态链接版，
  还捆了 `libcronet.so`。装到 musl 固件上有两个硬伤 —— 打包时过不了 OpenWrt 的
  “missing dependencies for the following libraries”（它要 `libc.so.6` / `libdl.so.2` /
  `libpthread.so.0`），而固件里没有提供这些名字的包；就算强行装上，也没有
  `/lib64/ld-linux-x86-64.so.2` 这个 glibc 加载器，二进制起不来
- musl 版是 `CGO_ENABLED=0` 构建的纯静态二进制（`file` 显示 statically linked，
  没有 DT_NEEDED），Hysteria2 / TUIC / QUIC / WireGuard / clash_api 等特性都在；
  唯一没有的是需要 cronet 的 `naive` 出站
- 官方只对这六个架构出 musl 资产，其它架构在解析阶段会打一条明确的 warning，
  真去编译会在下载阶段失败 —— 那种情况只能改成源码编译

## 规则集

**不随包分发，也不进仓库。** `render.uc` 生成的是 `type: remote` 的 rule-set，
由 sing-box 在启动时自己从 SagerNet 官方源拉取，下载结果缓存进
`/etc/sing-box-core/cache.db`，之后重启不再重复下载，每 7 天刷新一次。

用到的分类：

| tag | 用途 |
|---|---|
| `geosite-cn` | 国内域名（DNS 分流 + 直连判断） |
| `geosite-category-ads-all` | 广告拦截 |
| `geosite-google` / `-github` | 显式远端分类（可在 DNS 页增删） |
| `geosite-category-ai-!cn` | AI 服务，文件名含 `!`，URL 里编码为 `%21` |
| `geoip-cn` | 国内 IP |

合计约 148KB，只在首次联网时下载一次。

### 下载走哪个出站

1.14 起 rule-set 的下载出站由 `http_client` 控制（`download_detour` 已弃用），
这里指向 proxy：

```json
"http_clients": [{ "tag": "rs-download", "detour": "proxy" }]
```

有个坑值得记一笔：`detour` **不能指向「空的 direct 出站」**，否则 sing-box 直接拒绝启动：

```
FATAL: detour to an empty direct outbound makes no sense
```

同一个限制也适用于 DNS server 的 `detour`。所以配置里 bootstrap 和国内 DoH 都没有
写 `detour`——不写就是系统直连，反而不需要出站。

**这意味着首次启动必须先能连通节点**：规则集下载要经过 proxy，节点连不通就拉不到规则，
服务会起不来。`apply.sh` 会把 `logread -e sing-box-core` 的最后几行打出来，方便判断
是节点问题还是别的问题。

### 想改成离线分发

如果哪天 GitHub 不可达，把 `.srs` 放进 `/usr/share/sing-box-core/rulesets/`，
再把 `render.uc` 里 rule-set 的 `type` 从 `remote` 改成 `local`、把 `url` 换成
`path` 即可。分类文件可以从这两个仓库的 `rule-set` 分支取：

- https://github.com/SagerNet/sing-geosite/tree/rule-set
- https://github.com/SagerNet/sing-geoip/tree/rule-set

也可以从官方的 `.db` 自己裁：下载 `geosite.db`(3.81MB) 后用
`sing-box geosite -f geosite.db export <category> <out.srs>` 逐个导出。
`.db` 只是导出工具的输入，**不能直接写进配置**。

## 首次使用

1. 装包。服务已 enable，但没填节点时渲染会失败、进程不会启动（不影响原有网络）
2. 进 `服务 → sing-box-core → 节点`，填服务器地址、端口、密码/UUID、SNI
3. 点保存，插件会依次执行：渲染 → `sing-box check` → 重启 → 存活探测
4. 进 `概览` 看状态和日志

## 配置渲染机制

```
LuCI 表单
   ↓  uci commit singbox_core
/etc/config/singbox_core  ──render.uc──▶  /var/run/sing-box-core/config.json
                                        ↓
                                 sing-box check
                                  ↙          ↘
                            通过 restart    失败 → 恢复备份 + 报错回显
```

三个设计要点：

1. **UCI 是唯一数据源**。`config.json` 是生成物，不提供 JSON 编辑器，
   也就不会出现"手改 JSON 后被界面覆盖"或"少一个逗号整个服务起不来"。
2. **改错不会断网**。`apply.sh` 先备份旧配置，`check` 失败就原样恢复；
   `restart` 后如果进程没存活，也会回滚。这是整个插件最重要的保证。
3. **规则集缺失时降级**。`render.uc` 在引用 `.srs` 前会检查文件存在，
   缺了就跳过该条规则并告警，而不是渲染出一份必然检查失败的配置。

## 规则生成顺序

`render.uc` 里顺序是固定的，改顺序要改代码：

```
1. sniff
2. bypass_process          直连（dnsmasq / zerotier-one），排在劫持前 = dae 的 must_direct
3. dns_hijack_exempt_process  UDP 53 放行
4. hijack-dns
5. forced_proxy_process + forced_proxy_target:443  强制代理
6. geosite-category-ads-all  reject
7. UDP 443                   reject（阻断 QUIC）
8. lan_mac                   按源 MAC 强制代理（需 1.14+）
9. geoip-cn                  direct
10. 224.0.0.0/3              direct
11. ip_is_private            direct
12. final → proxy
```

第 6 条之前没有"按分类阻断 QUIC"的独立规则，因为第 7 条 `UDP 443` 已经覆盖全部匹配空间，
再写一条只多一次规则集查找。

## 和 dae 互斥切换

TUN 用的是 `iproute2_table_index: 2023` + `iproute2_rule_index: 9100`，
和 sing-box 默认的 2022 / 9000 错开，也和 dae 的 fwmark 段不冲突。
停服务时 `init.d` 会清 `sbc-tun`、2023 表、以及名字带 `sing` 的 nft 表。

配套的切换脚本见同工作区 `singbox-bare/proxy-switch`，把里面的
`SB_TABLE=2023`、`SB_RULE=9100` 与本插件保持一致即可。

## 排障

按这个顺序查，每步都能排除一大类问题：

```sh
/usr/libexec/sing-box-core/sing-box version          # 1. 版本对不对
/usr/libexec/sing-box-core/render.uc && echo OK      # 2. 能不能渲染
/usr/libexec/sing-box-core/sing-box check -c /var/run/sing-box-core/config.json   # 3. 配置合不合法
ip link show sbc-tun                        # 4. TUN 建起来没（查 kmod-tun）
ip rule show | grep 910                    # 5. auto_route 生效没（查 ip-full）
nft list tables | grep -i sing             # 6. auto_redirect 生效没
logread -e sing-box-core | tail -50                  # 7. 服务日志
```

`ip-full` 是硬依赖。缺了它表现为"服务起来了、日志干净、但路由没建"。

LuCI 侧和脚本侧同样写进了 `DEPENDS`：`luci-base`、`rpcd`、`ucode` 以及
`ucode-mod-fs` / `ucode-mod-uci`。渲染脚本是 ucode 写的（`import ... from 'fs'`、
`import * as uci from 'uci'`），若手工装 ipk 时用 `--force-depends` 跳过依赖，
故障会以 `/usr/libexec/sing-box-core/render.uc: not found` 或
`unable to load module 'uci'` 的形式出现在首次启动，而不是安装阶段提示。

### 1.14 的三个坑（插件已规避，手改 JSON 时会遇到）

```sh
# 1. missing `route.default_domain_resolver`
"route": { "default_domain_resolver": "bootstrap" }

# 2. default domain resolver not found: bootstrap
#    —— 上面指向的 tag 必须真实存在于 dns.servers
"dns": { "servers": [{ "type": "udp", "tag": "bootstrap", "server": "223.5.5.5" }] }

# 3. detour to an empty direct outbound makes no sense
#    —— detour 不能指向没配 bind_interface 的 direct 出站
#    所以 bootstrap / 国内 DoH 都不写 detour（不写 = 系统直连）
```

三条错误信息完全不同，指向的字段也不同，但都只出现在启动阶段——
`sing-box check` 全都不会报。

## 已知限制

| 限制 | 说明 |
|---|---|
| 单节点 | 设计如此。多节点需要 rule_set 分组和 selector，会显著增加界面复杂度 |
| 无 dscp 匹配 | sing-box 没有 DSCP/TOS 字段，dae 的 `dscp()` 规则无法迁移 |
| `process_name` 只对本机有效 | 局域网流量来自 TUN，没有进程上下文，这些规则不会命中 |
| `source_mac_address` 需 1.14+ | 低版本自动跳过该规则，并需要 `find_neighbor` + DHCP 租约 |
| 首次启动需要联网 | 规则集在启动时下载，节点连不通就拉不到规则，服务起不来 |
| 规则集版本随上游漂移 | `rule-set` 分支滚动更新，没有 tag；要固定版本就改成本地 `local` 类型 |
