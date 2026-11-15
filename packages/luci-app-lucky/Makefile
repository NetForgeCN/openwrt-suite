#
# Copyright (C) 2022-2026 gdy666, FloatingDream528
# Copyright (C) 2026 NetForgeCN
# SPDX-License-Identifier: GPL-3.0-only
#
# LuCI front end for the bundled Lucky core.
# The JS view, ACL, menu entry and zh_Hans translation are derived from
# FloatingDream528/luci-app-lucky (GPL-3.0-only). See NOTICE for details.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-lucky
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=NetForgeCN

LUCI_TITLE:=LuCI support for Lucky (core bundled at build time)
# +lucky is mandatory: the core binary must be part of the firmware image.
# rpcd / rpcd-mod-file are needed for fs.stat / fs.exec and service status.
LUCI_DEPENDS:=+lucky +luci-base +rpcd +rpcd-mod-file
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
