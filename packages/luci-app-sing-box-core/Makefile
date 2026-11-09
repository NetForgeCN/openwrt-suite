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
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=NetForgeCN

# ---- 自带的 sing-box 版本（与插件版本解耦，可单独升级）----
SB_VERSION:=1.14.0

# OpenWrt ARCH -> sing-box GOARCH 映射
SB_ARCH:= \
	$(if $(filter x86_64,$(ARCH)),amd64, \
	$(if $(filter i386 i486 i586 i686,$(ARCH)),386, \
	$(if $(filter aarch64%,$(ARCH)),arm64, \
	$(if $(filter arm%,$(ARCH)),armv7, \
	$(if $(filter mipsel%,$(ARCH)),mipsle, \
	$(if $(filter mips64el%,$(ARCH)),mips64le, \
	$(if $(filter mips%,$(ARCH)),mips, \
	$(if $(filter riscv64%,$(ARCH)),riscv64,amd64))))))))

PKG_SOURCE:=sing-box-$(SB_VERSION)-linux-$(SB_ARCH).tar.gz
PKG_SOURCE_URL:=https://github.com/SagerNet/sing-box/releases/download/v$(SB_VERSION)
# 官方 release 未提供逐资产的固定 hash 清单，这里跳过校验。
# 要固定完整性请把 PKG_HASH 换成本地 `sha256sum` 结果。
PKG_HASH:=skip

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Bare-core sing-box transparent proxy panel
  URL:=https://github.com/NetForgeCN/sing-box-core
  DEPENDS:=+kmod-tun +ip-full +curl +ca-bundle
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

$(DL_DIR)/$(PKG_SOURCE):
	$(call Download,$(PKG_SOURCE_URL)/$(PKG_SOURCE))

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(TAR) -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR)
	cp "$(PKG_BUILD_DIR)/sing-box-$(SB_VERSION)-linux-$(SB_ARCH)/sing-box" \
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

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/singbox_core
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/singbox-core/*.js \
		$(1)/www/luci-static/resources/view/singbox-core/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
