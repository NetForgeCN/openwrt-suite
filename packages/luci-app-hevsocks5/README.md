# luci-app-hevsocks5

LuCI 控制页面，用于管理 OpenWrt 上的 [hev-socks5-server](https://github.com/heiher/hev-socks5-server)。

上游 OpenWrt 包的 UCI 配置只有 `enabled` 和 `conffile` 两项，真正生效的是
`/etc/hev-socks5-server/main.yml`。本应用把全部配置放进 UCI，再由自带脚本渲染成 YAML，
因此既能在网页上改，也能直接用 `uci` 命令改。

## 功能

- 服务状态轮询，启动 / 停止 / 重启 / 重新生成配置并应用
- 开机自启动开关（同时操作 procd 启动链接和 UCI `enabled`）
- 基础页：用户名和密码，各带随机生成按钮；随机值由服务端 `/dev/urandom` 生成（浏览器 Web Crypto 在部分 WebView 中不可用或被 mock 成全 0，故不依赖它）；密码默认掩码，右侧小眼睛可切换明文方便复制；首次安装自动生成一组随机凭据
- 每个操作按钮都有忙碌态和结果提示（成功/失败），避免点击后没有任何可见反馈
- 高级页：以标签页形式展开上游全部 YAML 配置项，每项都有作用说明、默认值和填写示例
- 生成脚本做原子替换（`tmp` + `mv`），避免 procd 在写入中途读到半个 YAML
- 不覆盖上游的 `/etc/init.d/hev-socks5-server`，不会与 opkg 文件冲突

## 安装

```sh
opkg update
opkg install luci-app-hevsocks5 luci-i18n-hevsocks5-zh-cn
```

依赖：`hev-socks5-server`（OpenWrt 23.05+ 社区源 `net/hev-socks5-server`）、`luci-base`。

从源码编译：把本仓库放到 `package/` 或 `feeds/luci/applications/` 下，然后：

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig   # LuCI -> Applications -> luci-app-hevsocks5
make package/luci-app-hevsocks5/compile V=s
```

## 工作原理

```text
LuCI 页面 (UCI)  ->  ucitrack 触发 /etc/init.d/hevsocks5-sync
                 ->  /usr/bin/hevsocks5-ctl generate
                 ->  /etc/hev-socks5-server/main.yml (0600, 原子替换)
                 ->  procd 监控 conffile 变化 / 显式 restart
                 ->  /usr/bin/hev-socks5-server
```

安装的文件：

| 路径 | 作用 |
|---|---|
| `/usr/bin/hevsocks5-ctl` | UCI → YAML 渲染器、服务控制及 `rand` 随机值生成入口 |
| `/etc/init.d/hevsocks5-sync` | UCI 改动时的同步钩子 |
| `/etc/uci-defaults/luci-hevsocks5` | 首次安装写入默认值与随机凭据 |
| `/usr/share/luci/menu.d/luci-app-hevsocks5.json` | 菜单项 |
| `/usr/share/rpcd/acl.d/luci-app-hevsocks5.json` | 权限 |
| `/usr/share/ucitrack/luci-app-hevsocks5.json` | UCI 变更触发关系 |
| `/www/luci-static/resources/view/hevsocks5.js` | 页面 |

## 配置项对应关系

UCI 段为 `hev-socks5-server.config`。UCI 选项名使用下划线（rpcd 的 `uci/set` 不接受连字符），渲染成 YAML 时会转回上游的连字符键名：

| 页签 | 选项 |
|---|---|
| 基础 | `enabled`、`username`、`password` |
| 高级 - 监听 | `workers`、`port`、`listen_address`、`udp_port`、`udp_listen_address`、`udp-public-address-v4/v6`、`listen_ipv6_only`、`tcp_fastopen` |
| 高级 - 路由 | `bind_address`、`bind-address-v4/v6`、`bind_interface`、`domain_address_type`、`mark` |
| 高级 - 认证 | `auth_file`、`allow_no_auth` |
| 高级 - 调优与日志 | `task_stack_size`、`udp_recv_buffer_size`、`udp_copy_buffer_nums`、`connect_timeout`、`tcp_read_write_timeout`、`udp_read_write_timeout`、`read_write_timeout`、`log_file`、`log_level`、`limit_nofile`、`pid_file` |

两个特殊选项：

- `auth_file` 对应 YAML 的 `auth.file`。设置后优先于内联的 `username/password`，认证文件内容格式为每行 `USER PASS [MARK]`，修改后可用 `SIGUSR1` 热重载。
- `allow_no_auth` 是本应用增加的安全开关。凭据和认证文件都为空时只有打开它才会生成无认证配置，避免误操作把路由器变成开放代理。
- `read_write_timeout` 是旧版兼容项：设置后渲染器不再写 TCP/UDP 专用超时，上游会把该值同时应用到两者；留空则使用下方的专用超时。

`pid_file` 仅作展示，生成 YAML 时会被忽略：上游在设置它后会调用 `daemon()` 自行脱壳，与 procd 监管冲突。
`limit_nofile` 默认写 1000000，与上游 init 脚本向 procd 申请的值保持一致，否则程序启动时会把上限降回默认的 65535。

## 安全提醒

- 用户名、密码明文保存在 UCI 和生成的 YAML 中；生成的 YAML 权限为 `0600`，UCI 文件权限由系统控制。
- 记得在防火墙中放行 TCP 端口以及选定的 UDP 端口/端口范围。
- 不要把服务直接暴露到公网，除非确认认证和防火墙策略都正确。

## License

MIT，见 [LICENSE](LICENSE)。上游 hev-socks5-server 亦为 MIT 许可。
