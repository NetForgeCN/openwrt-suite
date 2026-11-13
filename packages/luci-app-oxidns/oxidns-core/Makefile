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
#
# Bundle choice: this pins the "full" assets (unsuffixed oxidns-<target>.tar.gz).
# OxiDNS 1.7 also publishes oxidns-standard-* and oxidns-minimal-*, but only
# for x86_64/aarch64, and "minimal" drops executors such as arbitrary/response.
# Staying on "full" keeps every architecture on the same feature set.

include $(TOPDIR)/rules.mk

PKG_NAME:=oxidns-core
PKG_VERSION:=1.7.1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=NetForgeCN

PKG_SOURCE_URL:=https://github.com/svenshi/oxidns/releases/download/v$(PKG_VERSION)/

# Map OpenWrt ARCH / CPU_TYPE to OxiDNS release targets.
ifeq ($(ARCH),x86_64)
  OXIDNS_RUST_TARGET:=x86_64-unknown-linux-musl
  OXIDNS_PKG_HASH:=6c82984e477d70d0c9259a6c7997496e248c78a384b2b7585908bba7f4af854c
else ifeq ($(ARCH),aarch64)
  OXIDNS_RUST_TARGET:=aarch64-unknown-linux-musl
  OXIDNS_PKG_HASH:=2e58721f840c3a4f1b92ed953857f14a65d2e825f8072917c262f7e34e2f21bd
else ifeq ($(ARCH),i386)
  OXIDNS_RUST_TARGET:=i686-unknown-linux-musl
  OXIDNS_PKG_HASH:=453ad3f7a975183ea084a3d72cedf7a6701c881df1ffa6dfd37ddc0f32b24d93
else ifeq ($(ARCH),arm)
  ifneq ($(findstring cortex,$(CPU_TYPE)),)
    OXIDNS_RUST_TARGET:=armv7-unknown-linux-musleabihf
    OXIDNS_PKG_HASH:=ea9c078d5eb2bbddf0b545e5959c687bb5b5a4e6e7b8ba326deb4386fd4e54bd
  else
    OXIDNS_RUST_TARGET:=arm-unknown-linux-musleabihf
    OXIDNS_PKG_HASH:=3f43e2eaab61682fcbc8de1ed5a37a2f5fab0611f5e3c0ad032e65b2570c5d83
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
