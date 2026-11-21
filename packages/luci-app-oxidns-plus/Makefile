#
# Copyright (C) 2026 NetForgeCN
#
# Licensed under GPL-3.0-or-later. See /LICENSE.
#
# luci-app-oxidns-plus is an ADD-ON for an existing OxiDNS 1.7.x runtime.
# It builds a small static Rust binary (oxidns-prewarmer) from the vendored
# src/prewarmer-rs source at package-build time, using OpenWrt's native Rust
# cross-toolchain (feeds/packages/lang/rust + package/libs/libstd-rust). No
# prebuilt binary and no GitHub Release are involved: the target architecture
# is derived from $(ARCH) by rust-values.mk, so every supported architecture
# gets a binary compiled with its own musl toolchain.
#
# It performs TTL-adaptive stale-hit prewarming by talking to OxiDNS's own
# management API and DNS listener. It does NOT ship or modify the OxiDNS core,
# and it never reads or writes /etc/oxidns/config.yaml.
#
# Supported architectures mirror oxidns-core: x86_64, aarch64, i386 and arm
# (armv6 / armv7 are distinguished by rust-values.mk from CONFIG_arm_v6/v7).
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-oxidns-plus
PKG_VERSION:=0.3.0
PKG_RELEASE:=4

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=NetForgeCN

LUCI_TITLE:=OxiDNS Plus - TTL-adaptive prewarming
# Architecture gate mirrors oxidns-core. $(RUST_ARCH_DEPENDS) from
# rust-values.mk is intentionally not used: it is broader (mips/ppc/riscv/...)
# than the architectures this package is validated for.
LUCI_DEPENDS:=+luci-base +rpcd +jsonfilter @(x86_64||aarch64||i386||arm)

# Pure Rust package: build for every target arch, so no arch pinning.
LUCI_PKGARCH:=

# Rust source lives in the feed itself (no PKG_SOURCE download).
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
# Relative path inside PKG_BUILD_DIR that contains Cargo.toml.
MAKE_PATH:=src/prewarmer-rs

# Use OpenWrt's host Rust toolchain; rust-package.mk derives the target
# musl triple and cross linker from $(ARCH)/$(REAL_GNU_TARGET_NAME).
PKG_BUILD_DEPENDS:=rust/host

define Package/luci-app-oxidns-plus/description
  Adds a LuCI page, UCI settings, a procd-managed binary and an rpcd API on top
  of an existing OxiDNS installation. A small static Rust daemon is compiled
  from source at package-build time with the OpenWrt cross-toolchain. It reads
  the OxiDNS cache API for TTL truth, maintains one independent deadline per
  (domain,qtype) and fires a query at OxiDNS's own listener just after fresh
  expiry so the native lazy cache refreshes in the background. TTL changes are
  followed, retries back off, single-flight and jitter are enforced, and the
  old cache is always kept. The OxiDNS main config is never read or written.
endef

define Package/luci-app-oxidns-plus/conffiles
/etc/config/oxidnsplus
/etc/oxidnsplus/watch.list
endef

define Package/luci-app-oxidns-plus/postinst
#!/bin/sh
ROOT="$${IPKG_INSTROOT:-}"
for f in /etc/init.d/oxidnsplus /usr/libexec/rpcd/luci.oxidnsplus /usr/libexec/oxidns-prewarmer; do
	[ -f "$$ROOT$$f" ] && chmod 755 "$$ROOT$$f"
done
[ -n "$$ROOT" ] && exit 0
if [ -f /etc/sysupgrade.conf ]; then
	for entry in /etc/config/oxidnsplus /etc/oxidnsplus/watch.list; do
		grep -qxF "$$entry" /etc/sysupgrade.conf 2>/dev/null || echo "$$entry" >> /etc/sysupgrade.conf
	done
fi
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -x /etc/init.d/rpcd ]; then /etc/init.d/rpcd restart >/dev/null 2>&1 || true; fi
exit 0
endef

define Package/luci-app-oxidns-plus/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
if [ -x /etc/init.d/oxidnsplus ]; then
	/etc/init.d/oxidnsplus stop >/dev/null 2>&1 || true
	/etc/init.d/oxidnsplus disable >/dev/null 2>&1 || true
	/etc/init.d/oxidnsplus cleanup >/dev/null 2>&1 || true
fi
if [ -f /etc/sysupgrade.conf ]; then
	grep -vxE '/etc/config/oxidnsplus|/etc/oxidnsplus/watch.list' \
		/etc/sysupgrade.conf > /etc/sysupgrade.conf.oxidnsplus.tmp && \
		mv /etc/sysupgrade.conf.oxidnsplus.tmp /etc/sysupgrade.conf
fi
logger -t oxidns-plus "prerm: prewarmer stopped and runtime state removed" 2>/dev/null || true
exit 0
endef

define Package/luci-app-oxidns-plus/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/oxidnsplus.status.json /tmp/oxidnsplus.status.json.tmp 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -f /etc/sysupgrade.conf ]; then
	grep -vxE '/etc/config/oxidnsplus|/etc/oxidnsplus/watch.list' \
		/etc/sysupgrade.conf > /etc/sysupgrade.conf.tmprm && \
		mv /etc/sysupgrade.conf.tmprm /etc/sysupgrade.conf
fi
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true
exit 0
endef

# Copy the vendored Rust source into the build dir. No download, so Build/Prepare
# is defined explicitly rather than relying on the default PKG_SOURCE unpack.
# Create the full destination path: $(CP) is cp -fpR, which does not create
# missing parent directories, and rust-package.mk has no Build/Prepare of its
# own. MAKE_PATH points at $(PKG_BUILD_DIR)/src/prewarmer-rs for cargo install.
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/src/prewarmer-rs
	$(CP) ./src/prewarmer-rs/. $(PKG_BUILD_DIR)/src/prewarmer-rs/
endef

# Build/Compile is supplied by rust-package.mk (Build/Compile/Cargo), which
# runs: cargo install --path $(PKG_BUILD_DIR)/$(MAKE_PATH) --root $(PKG_INSTALL_DIR)
# The resulting binary is at $(PKG_INSTALL_DIR)/bin/oxidns-prewarmer.
#
# Disable the generic Build/Install step. package.mk defines it as
#   Build/Install=$(if $(PKG_INSTALL),$(call Build/Install/Default,))
# and Build/Install/Default runs `make -C $(PKG_BUILD_DIR)/$(MAKE_PATH) install`.
# Our MAKE_PATH (src/prewarmer-rs) is a pure Cargo project with no Makefile, so
# that step would fail with "No rule to make target 'install'". cargo install
# already places the binary into PKG_INSTALL_DIR during Build/Compile, and our
# Package/.../install copies it into the package: no Build/Install is needed.
# Define this BEFORE luci.mk, whose trailing BuildPackage eval captures it.
Build/Install:=

define Package/luci-app-oxidns-plus/install
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/oxidns-prewarmer $(1)/usr/libexec/oxidns-prewarmer
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/oxidnsplus $(1)/etc/init.d/oxidnsplus
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/luci.oxidnsplus $(1)/usr/libexec/rpcd/luci.oxidnsplus
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./root/etc/config/oxidnsplus $(1)/etc/config/oxidnsplus
	$(INSTALL_DIR) $(1)/etc/oxidnsplus
	$(INSTALL_DATA) ./root/etc/oxidnsplus/watch.list $(1)/etc/oxidnsplus/watch.list
	$(INSTALL_DIR) $(1)/usr/share/oxidnsplus
	$(INSTALL_DATA) ./root/usr/share/oxidnsplus/uci.defaults $(1)/usr/share/oxidnsplus/uci.defaults
	$(INSTALL_DATA) ./root/usr/share/oxidnsplus/watch.list.defaults $(1)/usr/share/oxidnsplus/watch.list.defaults
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-oxidns-plus.json $(1)/usr/share/rpcd/acl.d/luci-app-oxidns-plus.json
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-oxidns-plus.json $(1)/usr/share/luci/menu.d/luci-app-oxidns-plus.json
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/oxidnsplus
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/oxidnsplus/plus.js $(1)/www/luci-static/resources/view/oxidnsplus/plus.js
endef

# rust-package.mk overrides Build/Compile with Build/Compile/Cargo and defines
# the target triples / cross linker. It must be included BEFORE luci.mk so that
# the package registered by luci.mk picks up the Cargo compile rule.
include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

# luci.mk sets LUCI_BUILD_PACKAGES := $(PKG_NAME) and, at its end, evaluates
# BuildPackage for every entry. That is the ONE and ONLY registration point.
# Do NOT add an explicit $(eval $(call BuildPackage,...)) here: it would
# register the package a second time and make it appear twice in menuconfig.
include $(TOPDIR)/feeds/luci/luci.mk

# scan.mk discovers packages by grepping for "call BuildPackage"; a comment is
# enough for discovery but is not evaluated, so registration stays single.
# call BuildPackage - OpenWrt buildroot signature
