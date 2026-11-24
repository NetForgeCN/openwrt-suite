include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-hevsocks5
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI support for hev-socks5-server
LUCI_DESCRIPTION:=Manage hev-socks5-server: service control, random credentials and full YAML options.
LUCI_DEPENDS:=+hev-socks5-server +luci-base
LUCI_PKGARCH:=all
LUCI_MAINTAINER:=NetForgeCN

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
