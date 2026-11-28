# luci-app-lucky

为 NetForgeCN 固件仓库群准备的 Lucky 打包层。**核心二进制在编译期进入固件，刷机后无需联网即可使用**；`lucky` 版本在仓库里钉死并带 sha256，构建可复现。

## 设计约定

| 约定 | 实现 |
|---|---|
| 核心必须存在于编译后的固件 | `lucky/Makefile` 用标准 `PKG_SOURCE` 在 `make download` 阶段下载官方静态二进制，`Package/lucky/install` 把它 `INSTALL_BIN` 到 `/usr/bin/lucky`，随 rootfs 一起打包 |
| 开机零联网 | `lucky/files/lucky.init` 检测不到二进制只写日志并 `return 1`；`init.d` / `uci-defaults` / `postinst` / JS 页面里没有任何下载核心的语句 |
| 可复现 | 版本、发布目录、13 个 Linux 架构的 sha256 全部写在 `lucky/Makefile` 里。`make download` 会用 `PKG_HASH` 校验，校验不过直接失败 |
| 自动跟进最新版 | 由 CI 每天检查官网并改写这个 pin，**不是**编译期现场探测 |

## 自动更新机制

```
官网目录 https://release.66666.host/
        │  每天 01:30 (北京) 解析 href="./vX.Y.Z/"，取最大稳定版
        ▼
scripts/bump-version.py
        │  下载 13 个 Linux tar.gz → 算 sha256 → 校验包内含可执行 ELF lucky
        │  改写 lucky/Makefile 的 AUTO-GENERATED 块 + lucky/assets.json
        ▼
.github/workflows/bump.yml  commit & push
        │
        ├─ openwrt-suite 每日 02:30 同步快照
        ├─ OpenWRT / OpenWrt-ScriptBuild 构建时直接 clone 本仓库
        ▼
固件使用「仓库里锁定的最新版」
```

编译期永远不联网问"最新版"，每天只有版本真的变了才会提交一次。新版 tar 结构若改变（不再是平铺的 `lucky` ELF），脚本报错、workflow 变红、旧 pin 保持不动。若想固定在某个版本，暂停 `bump.yml` 即可。

在 Actions 里手动 `Run workflow` 时勾选 **force**，可强制重新下载并校验全部 13 个资产、刷新 pin；不勾选时若已是最新版则不会产生提交。

当前版本：**3.8.1**（`v3.8.1/3.8.1_lucky/`），x86_64 核心 17.08 MiB，静态链接（ELF 无 `PT_INTERP` / `PT_DYNAMIC`），固件约增加 17 MiB。

## 产生的包

| 包 | 菜单位置 | 说明 |
|---|---|---|
| `lucky` | Network | 核心二进制 + `/etc/init.d/lucky` + `/etc/config/lucky` |
| `luci-app-lucky` | LuCI → Applications | 纯客户端 JS 界面（状态、启停、端口/安全入口、后台链接） |
| `luci-i18n-lucky-zh-cn` | LuCI → Translations | 由 `luci.mk` 依据 `po/zh_Hans/lucky.po` 自动生成 |

默认后台 `http://<路由器>:16601`，配置目录 `/etc/config/lucky.daji`，UCI 在 `/etc/config/lucky`。LuCI 页面只做服务管理，端口转发 / DDNS / 反代 / ACME / WOL 都在 Lucky 自带后台里。

`LUCI_DEPENDS:=+lucky +luci-base +rpcd +rpcd-mod-file`：`+lucky` 是硬约束，保证选界面必然带上核心；后两项是 `fs.exec` / 服务状态查询所需。rpcd ACL 只放行精确命令行（`-info` / `-baseConfInfo ...` / `-setconf ...`），不给 `/usr/bin/lucky` 的裸 `exec` 权限，避免只读会话传入任意参数。`configdir` 在界面和 init 脚本里都做白名单校验，并拒绝符号链接。

## 在 OpenWrt 源码树里用

本仓库根目录就是包目录（根 `Makefile` = LuCI 包，`lucky/` = 核心子包）。**直接 clone 到 `package/`，不要挂成 feed**：

```bash
# 官方 feed 照常准备：两条 Makefile 只依赖 rules.mk 与 feeds/luci/luci.mk，
# 不要删 luci feed，也不需要为本包新增任何 src-git 条目
./scripts/feeds update -a
./scripts/feeds install -a

git clone https://github.com/NetForgeCN/luci-app-lucky.git package/luci-app-lucky
make menuconfig   # 勾选 LuCI → Applications → luci-app-lucky
```

后续更新本地检出：

```bash
git -C package/luci-app-lucky pull --ff-only
```

`.config` 由使用者自己维护；建议 `CONFIG_PACKAGE_lucky=y`、`CONFIG_PACKAGE_luci-app-lucky=y`（界面靠 `+lucky` 硬依赖自动带上核心）。也可单独编译：

```bash
make package/luci-app-lucky/compile V=s
```

预下载（可选，便于离线/国内网络）：

```bash
wget -O dl/lucky_3.8.1_Linux_x86_64.tar.gz \
  https://release.66666.host/v3.8.1/3.8.1_lucky/lucky_3.8.1_Linux_x86_64.tar.gz
```

## 验收

```bash
python3 scripts/verify-bundle.py     # 静态检查：pin / hash / +lucky / 零运行时下载
python3 scripts/bump-version.py      # 手动检查官网最新版（已是最新则不动）
```

编译后确认核心真的在固件里：

```bash
file build_dir/target-*/root-*/usr/bin/lucky     # statically linked
# 或解包 squashfs 后查找 /usr/bin/lucky
```

刷机后**拔网线**启动，`/etc/init.d/lucky start` 应能起来，`:16601` 可访问。

## 许可

见 [LICENSE](LICENSE)（GPL-3.0 全文）、[lucky/LICENSE](lucky/LICENSE)（核心/打包层的 MIT 文本）与 `NOTICE`（三部分的版权/许可归属）。核心二进制来自 `gdy666/lucky`（MIT），LuCI 界面衍生自 `FloatingDream528/luci-app-lucky`（GPL-3.0-only），打包脚本由 NetForgeCN 维护。
