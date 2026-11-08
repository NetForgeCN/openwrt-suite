#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
# updated to work with latest source from abrasive
#
# Shairport Sync 5.x talks to NQPTP over shared memory interface version 11
# ("smi11"), which is only provided by NQPTP 1.2.9 or later. The nqptp in the
# OpenWrt packages feed is 1.2.4 ("smi10") and is therefore not usable with
# shairport-sync 5.x -- AirPlay 2 timing would fail. This package provides a
# matching NQPTP.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=nqptp
PKG_VERSION:=1.2.9
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/mikebrady/nqptp/tar.gz/$(PKG_VERSION)?
PKG_HASH:=6aa1d73b8ee760bf19378c319db0d0537a867ff961764b150e19f87d96a02210

PKG_MAINTAINER:=Ben Klang <bklang@wirehack.net>
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=COPYING LICENSES nqptp.c

PKG_FIXUP:=autoreconf
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/nqptp
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Not Quite PTP -- timing helper for AirPlay 2
  URL:=https://github.com/mikebrady/nqptp
  DEPENDS:=+libpthread
  PROVIDES:=nqptp
endef

define Package/nqptp/description
  nqptp is a daemon that monitors timing data from PTP clocks it sees on ports
  319 and 320. It maintains records for one clock, identified by its Clock ID.

  It is a companion application to Shairport Sync and provides timing
  information for AirPlay 2 operation.

  Version 1.2.9 provides Shared Memory Interface Version 11 ("smi11"), which
  is required by shairport-sync 5.6.x.
endef

define Package/nqptp/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/nqptp $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/nqptp.init $(1)/etc/init.d/nqptp
endef

$(eval $(call BuildPackage,nqptp))
