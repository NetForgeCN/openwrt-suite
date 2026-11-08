include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-open_nexttrace
PKG_VERSION:=0.2.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-open_nexttrace
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=OpenTrace-style visual traceroute for OpenWrt
  URL:=https://github.com/haohaoget/luci-app-open_nexttrace
  DEPENDS:=+open-nexttrace-core +luci-base +lua +luci-lib-nixio +luci-lib-jsonc +libubus-lua
endef

define Package/luci-app-open_nexttrace/description
 Browser-based NextTrace route visualization with multi-WAN interface selection.
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-open_nexttrace/install
	$(INSTALL_DIR) $(1) $(1)/www
	$(CP) $(CURDIR)/root/. $(1)/
	$(CP) $(CURDIR)/htdocs/. $(1)/www/
	chmod 0755 $(1)/usr/libexec/rpcd/open_nexttrace
endef

$(eval $(call BuildPackage,luci-app-open_nexttrace))
