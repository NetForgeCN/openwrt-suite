# Copyright (C) 2016 Openwrt.org
#
# This package is licensed under GPL-3.0-only; see the repository LICENSE file.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-airplay2
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_TITLE:=Luci for Apple Airplay2 Receiver
LUCI_DEPENDS:=+luci-base +alsa-utils +airplay2
LUCI_PKGARCH:=all

PKG_MAINTAINER:=sbwml <admin@cooluc.com>
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
