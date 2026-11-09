#
# Copyright (C) 2026 NetForgeCN
#
# This is free software, licensed under the GNU General Public License v3.
# See /LICENSE for more information.
#
# Bundles the official OxiDNS core release (prebuilt musl binary + webui +
# default config) into the firmware / package. The release archive matching
# the build target architecture is downloaded at compile time, so the
# resulting image ships with a working DNS core out of the box. The core is
# installed to the persistent area (/etc/oxidns/core) so it survives
# sysupgrade when "keep settings" is used.
#
# When a new OxiDNS core is released, bump PKG_VERSION and refresh the
# hashes below (or use the LuCI "Check Update" button at runtime, which is
# not limited to the pinned version).

include $(TOPDIR)/rules.mk

PKG_NAME:=oxidns-core
PKG_VERSION:=1.6.1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=NetForgeCN

PKG_SOURCE_URL:=https://github.com/svenshi/oxidns/releases/download/v$(PKG_VERSION)/

# Map OpenWrt ARCH / CPU_TYPE to OxiDNS release targets.
ifeq ($(ARCH),x86_64)
  OXIDNS_RUST_TARGET:=x86_64-unknown-linux-musl
  OXIDNS_PKG_HASH:=2ac8e103e03407a73c29da848f6ce2d524e751ce1da8a744aa9168fc1384e3b0
else ifeq ($(ARCH),aarch64)
  OXIDNS_RUST_TARGET:=aarch64-unknown-linux-musl
  OXIDNS_PKG_HASH:=d879d4b9199c5c911d296af4df8d9e974523fb98a6ee2418ae7274d152365e42
else ifeq ($(ARCH),i386)
  OXIDNS_RUST_TARGET:=i686-unknown-linux-musl
  OXIDNS_PKG_HASH:=1696dc4db29a0eee90540d0ab5a01f58ffcbfd70e9e3d0c68b6047854042c2ab
else ifeq ($(ARCH),arm)
  ifneq ($(findstring cortex,$(CPU_TYPE)),)
    OXIDNS_RUST_TARGET:=armv7-unknown-linux-musleabihf
    OXIDNS_PKG_HASH:=369739e626e2664131d91b7f2b9b4cf396475672ed3086d07358675f390e9786
  else
    OXIDNS_RUST_TARGET:=arm-unknown-linux-musleabihf
    OXIDNS_PKG_HASH:=bde4518f430fa29d1f63d86844c4a5063a1d9c74a411b31eaeda03d35564f08c
  endif
else
  OXIDNS_RUST_TARGET:=unsupported-arch
  OXIDNS_PKG_HASH:=skip
endif

PKG_SOURCE:=oxidns-$(OXIDNS_RUST_TARGET).tar.gz
PKG_HASH:=$(OXIDNS_PKG_HASH)

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/oxidns-core
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=DNS
  TITLE:=OxiDNS core (prebuilt musl binary, bundled at compile time)
  DEPENDS:=@(x86_64||aarch64||i386||arm)
endef

define Package/oxidns-core/description
  Bundles the official OxiDNS core release for the build target architecture
  ($(OXIDNS_RUST_TARGET)). Installs the binary and webui to the persistent
  area /etc/oxidns/core so they survive firmware upgrades, and links them
  into /usr/bin and /usr/share/oxidns. Upgrades can later be applied from
  the luci-app-oxidns "Check Update" page.
endef

# The OxiDNS release tarball has multiple top-level entries (oxidns,
# config.yaml, LICENSE, webui/) instead of a single root directory, so the
# default PKG_UNPACK (which strips the first path component) would destroy
# it. Extract without stripping instead.
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	tar -C $(PKG_BUILD_DIR) -xzf $(DL_DIR)/$(PKG_SOURCE)
endef

define Build/Compile
endef

define Package/oxidns-core/conffiles
/etc/oxidns/config.yaml
endef

define Package/oxidns-core/install
	$(INSTALL_DIR) \
		$(1)/etc/oxidns/core \
		$(1)/usr/bin \
		$(1)/usr/share/oxidns

	$(INSTALL_BIN) $(PKG_BUILD_DIR)/oxidns $(1)/etc/oxidns/core/oxidns
	$(CP) $(PKG_BUILD_DIR)/webui $(1)/etc/oxidns/core/webui
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/config.yaml $(1)/etc/oxidns/config.yaml

	$(LN) /etc/oxidns/core/oxidns $(1)/usr/bin/oxidns
	$(LN) /etc/oxidns/core/webui $(1)/usr/share/oxidns/webui
endef

define Package/oxidns-core/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
# Keep the core across firmware upgrades.
if [ -f /etc/sysupgrade.conf ]; then
	for entry in /etc/oxidns /etc/config/oxidns; do
		grep -qxF "$$entry" /etc/sysupgrade.conf 2>/dev/null || \
			echo "$$entry" >> /etc/sysupgrade.conf
	done
fi
# Self-heal after a firmware upgrade: relink if the persistent copy survived.
if [ -x /etc/oxidns/core/oxidns ] && [ ! -x /usr/bin/oxidns ]; then
	mkdir -p /usr/bin
	ln -sf /etc/oxidns/core/oxidns /usr/bin/oxidns
fi
if [ -d /etc/oxidns/core/webui ] && [ ! -d /usr/share/oxidns/webui ]; then
	mkdir -p /usr/share/oxidns
	ln -sfn /etc/oxidns/core/webui /usr/share/oxidns/webui
fi
exit 0
endef

$(eval $(call BuildPackage,oxidns-core))
