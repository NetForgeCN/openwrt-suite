#
# luci-app-sing-box-core - bare-core sing-box panel for OpenWrt
#
# 设计约束：
#   1. 自带 sing-box 二进制，装到 /usr/libexec/sing-box-core/，绝不覆盖系统的 /usr/bin/sing-box
#   2. 服务名 singbox_core，与系统 sing-box 包完全隔离，可共存
#   3. 不依赖系统 sing-box 包版本，固件升级不会把旧版塞回来
#
# 注意：DEPENDS 里刻意不写 +sing-box。系统自带的旧版与本插件无关，二者可共存。
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-sing-box-core
PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=NetForgeCN

# ---- 自带的 sing-box 版本（与插件版本解耦，可单独升级）----
SB_VERSION:=1.14.0

# OpenWrt ARCH -> SagerNet release 资产名
#
# 只取 -musl 变体。musl 版是 CGO_ENABLED=0 的纯静态二进制：
#   - 没有任何 DT_NEEDED，打包时 OpenWrt 的「Package ... is missing
#     dependencies for the following libraries」校验天然通过；
#   - 不需要 glibc 的 /lib64/ld-linux-x86-64.so.2，musl 固件上能直接执行。
# 不带后缀的 sing-box-linux-<arch>.tar.gz 是 glibc 动态链接版（还捆了
# libcronet.so），装进 musl 固件既过不了依赖检查、也跑不起来，不要用。
SB_ASSET:=$(strip \
	$(if $(filter x86_64,$(ARCH)),amd64-musl, \
	$(if $(filter i386 i486 i586 i686,$(ARCH)),386-musl, \
	$(if $(filter aarch64%,$(ARCH)),arm64-musl, \
	$(if $(filter arm%,$(ARCH)),armv7-musl, \
	$(if $(filter mipsel%,$(ARCH)),mipsle-softfloat-musl, \
	$(if $(filter riscv64%,$(ARCH)),riscv64-musl,)))))))

# 官方只对这六个架构出 musl 资产。这里用 warning 而不是 $(error)：$(error)
# 会在 menuconfig 的元数据扫描阶段就把整棵树打断，而实际构建时若资产名为空，
# 下载阶段自然会失败。
$(if $(strip $(SB_ASSET)),,$(warning luci-app-sing-box-core: $(ARCH) 没有对应的 musl 静态资产，无法打包自带的 sing-box 核心))

# 逐资产 sha256（download.pl 会校验，换 SB_VERSION 时要一起更新）
SB_HASH_amd64-musl:=d2d6b4543d850269214ced70ffe41b13b1595baa1b6f9c016466abfba162c4d4
SB_HASH_386-musl:=7dd44c5f2fd11f2fabe50eada0ebc6546e13ca51304393b71a030de96ff4d520
SB_HASH_arm64-musl:=1811c446a4957edee1b62ed2363607f8e99e1f7b6d88179719251d7ed5f30169
SB_HASH_armv7-musl:=a46243ee738200dce68638720a36c8e3bf53ce868a043ec49c29baf122cc4b20
SB_HASH_mipsle-softfloat-musl:=2f71d969cf4cf2181a6497bbb147fd38a1aaea101caf48cbbf8e29a2ca4a415e
SB_HASH_riscv64-musl:=2ab42d9566ecfa81cd47033ee1f6cc6f00ce817ab0db43fd371bab860b882338
PKG_HASH:=$(if $(strip $(SB_ASSET)),$(SB_HASH_$(SB_ASSET)),skip)

PKG_SOURCE:=sing-box-$(SB_VERSION)-linux-$(SB_ASSET).tar.gz
PKG_SOURCE_URL:=https://github.com/SagerNet/sing-box/releases/download/v$(SB_VERSION)
# 下载规则由 $(INCLUDE_DIR)/package.mk 自带，这里不要重复定义（会触发
# "warning: overriding recipe for target .../dl/sing-box-*.tar.gz"）。

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

# 依赖说明：除 kmod-tun / ip-full / curl / ca-bundle 外，还必须有
# luci-base（视图框架 + rpcd 的 luci 对象）、rpcd（ubus/文件 RPC），
# 以及 ucode / ucode-mod-fs / ucode-mod-uci —— render.uc 由 ucode 解释，
# import 'fs' 与 import 'uci' 各需要一个模块包，缺任一个都会在首次启动
# 渲染配置时直接失败。
define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Bare-core sing-box transparent proxy panel
  URL:=https://github.com/NetForgeCN/sing-box-core
  DEPENDS:=+kmod-tun +ip-full +curl +ca-bundle \
           +luci-base +rpcd +ucode +ucode-mod-fs +ucode-mod-uci
endef

define Package/$(PKG_NAME)/description
  Bare-core sing-box panel for OpenWrt. The core owns the datapath; this
  LuCI app only renders UCI into config.json and supervises the process.

  Ships its own sing-box binary at /usr/libexec/sing-box-core/sing-box, so
  the (usually outdated) sing-box package from OpenWrt feeds is left
  untouched: different binary, different service, different config
  namespace. Both can be installed side by side.

  No iptables/nft glue of its own -- TUN + auto_route + auto_redirect let
  sing-box manage routing and the fw4 compatibility rules by itself.

  Features: Hysteria2 / TUIC single node, DoH DNS split (CN / non-CN) with
  bootstrap and persistent cache, geosite routing fetched at runtime, and a
  check-before-reload apply path that rolls back instead of cutting the
  network.
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/singbox_core
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/sing-box-core enable
	/etc/init.d/rpcd restart
}
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/sing-box-core stop 2>/dev/null
	/etc/init.d/sing-box-core disable 2>/dev/null
}
exit 0
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(TAR) -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR)
	cp "$(PKG_BUILD_DIR)/sing-box-$(SB_VERSION)-linux-$(SB_ASSET)/sing-box" \
	   "$(PKG_BUILD_DIR)/sing-box"
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	# --- 私有 sing-box 二进制 ---
	$(INSTALL_DIR) $(1)/usr/libexec/sing-box-core
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/sing-box $(1)/usr/libexec/sing-box-core/sing-box

	# --- UCI / 服务 ---
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/singbox_core $(1)/etc/config/singbox_core

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/sing-box-core $(1)/etc/init.d/sing-box-core

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/90_luci-app-sing-box-core \
		$(1)/etc/uci-defaults/90_luci-app-sing-box-core

	# --- 后端脚本 ---
	$(INSTALL_DIR) $(1)/usr/libexec/sing-box-core
	$(INSTALL_BIN) ./root/usr/libexec/sing-box-core/render.uc $(1)/usr/libexec/sing-box-core/render.uc
	$(INSTALL_BIN) ./root/usr/libexec/sing-box-core/apply.sh $(1)/usr/libexec/sing-box-core/apply.sh

	# --- LuCI 资源 ---
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-sing-box-core.json \
		$(1)/usr/share/luci/menu.d/luci-app-sing-box-core.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-sing-box-core.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-sing-box-core.json

	# 视图目录名必须与 menu.d 的 path、仓库内源码目录三者一致（都是 singbox-core）；
	# 之前这里写成 singbox_core，INSTALL_DIR 建出的目录和 INSTALL_DATA 的目标不一致，
	# 安装阶段 cp 找不到目录会直接失败。
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/singbox-core
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/singbox-core/*.js \
		$(1)/www/luci-static/resources/view/singbox-core/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
