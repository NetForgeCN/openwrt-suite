#
# Copyright (C) 2026 NetForgeCN
# SPDX-License-Identifier: MIT
#
# Lucky core, bundled INTO the firmware at build time.
#
# The official prebuilt (statically linked) Lucky core is downloaded during
# `make download`, verified against a pinned sha256 and installed as
# /usr/bin/lucky by Package/lucky/install. Nothing is fetched at first boot:
# lucky/files/lucky.init only logs an error and returns 1 when the binary is
# missing. The image is therefore fully usable offline and reproducible from
# a single commit.
#
# Version and hashes below are maintained by scripts/bump-version.py, which
# runs daily in CI. The build itself NEVER probes the network for "latest":
# it always uses the exact version pinned in this file.
#
# Core source/license: https://github.com/gdy666/lucky (MIT)
# Release channel:     https://release.66666.host/

include $(TOPDIR)/rules.mk

PKG_NAME:=lucky
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=NetForgeCN
PKG_LICENSE_FILES:=LICENSE

# BEGIN AUTO-GENERATED (scripts/bump-version.py) -- DO NOT EDIT BY HAND
# Source: https://release.66666.host/  (latest stable v3.8.1, checked 2026-11-15T06:03:00Z)
PKG_VERSION:=3.8.1
LUCKY_RELEASE_DIR:=v3.8.1/3.8.1_lucky
ifeq ($(ARCH),x86_64)
  LUCKY_ARCH:=x86_64
  PKG_HASH:=b9d49448f24b7d285622bd0e7adc18e4b101caf4ad8c7f7e9fca11ace1dc1053
else ifeq ($(ARCH),i386)
  LUCKY_ARCH:=i386
  PKG_HASH:=2825c177dd2a3f4e04d1bf92437dd711b08054123e062e8b418215ca845c6209
else ifeq ($(ARCH),aarch64)
  LUCKY_ARCH:=arm64
  PKG_HASH:=ba81af2afab7e18b4c403eebaf11dc361ef56282d4912199209db786386293c3
else ifeq ($(ARCH),arm)
  ifneq ($(findstring cortex,$(CPU_TYPE)),)
    LUCKY_ARCH:=armv7
    PKG_HASH:=d7175479056237b48e36521e55ef5f042fae95c4df18fc42a173fbee79aa36ef
  else
    LUCKY_ARCH:=armv5
    PKG_HASH:=caf397b88d7549bf851851f7a3491a99be42378f17994d82430eb9e15f04fd0b
  endif
else ifeq ($(ARCH),mips)
  LUCKY_ARCH:=mips_softfloat
  PKG_HASH:=9e4a82285fc5f726b6c859b5fd1cc9906d5c40a1284ae223eaf06a50ccaeab68
else ifeq ($(ARCH),mipsel)
  LUCKY_ARCH:=mipsle_softfloat
  PKG_HASH:=0528a877225c14428a85de00814c43174e0023f5d826be43ebcc86bc0187fad0
else ifeq ($(ARCH),mips64)
  LUCKY_ARCH:=mips64_softfloat
  PKG_HASH:=634043984f6dfb0fbb30e0c529de04094615a01fa5ac3548f3a424fe04409ded
else ifeq ($(ARCH),riscv64)
  LUCKY_ARCH:=riscv64
  PKG_HASH:=f445ad4c47fc339fcfb7e9ca04142c3c56d3a4177993031d4d61793d588c7966
else
  LUCKY_ARCH:=
  PKG_HASH:=
endif
# END AUTO-GENERATED (scripts/bump-version.py)

PKG_SOURCE:=lucky_$(PKG_VERSION)_Linux_$(LUCKY_ARCH).tar.gz
PKG_SOURCE_URL:=https://release.66666.host/$(LUCKY_RELEASE_DIR)
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/lucky
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Lucky core (prebuilt static binary, bundled into the firmware)
  URL:=https://github.com/gdy666/lucky
  DEPENDS:=+ca-bundle @(x86_64||i386||aarch64||arm||mips||mipsel||mips64||riscv64)
endef

define Package/lucky/description
  Official Lucky core (IPv4/IPv6 port forwarding, DDNS, reverse proxy,
  Wake-on-LAN, ACME certificates and more). The statically linked binary is
  downloaded and sha256-verified at build time, then installed into the
  firmware image. No runtime download is required, ever.
endef

# The release tarball is flat (lucky, LICENSE, scripts/) instead of having a
# single top-level directory, so the default PKG_UNPACK would strip away the
# binary. Extract without stripping, like oxidns-core does.
define Build/Prepare
	@test -n "$(LUCKY_ARCH)" || { echo "lucky: unsupported target ARCH '$(ARCH)'" >&2; exit 1; }
	rm -rf $(PKG_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)
	tar -C $(PKG_BUILD_DIR) -xzf $(DL_DIR)/$(PKG_SOURCE)
	chmod +x $(PKG_BUILD_DIR)/lucky
	test -x $(PKG_BUILD_DIR)/lucky
endef

define Build/Compile
endef

define Package/lucky/conffiles
/etc/config/lucky
endef

define Package/lucky/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/lucky $(1)/usr/bin/lucky
	$(INSTALL_BIN) $(CURDIR)/files/lucky.init $(1)/etc/init.d/lucky
	$(INSTALL_CONF) $(CURDIR)/files/luckyuci $(1)/etc/config/lucky
endef

define Package/lucky/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
/etc/init.d/lucky enable >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,lucky))
