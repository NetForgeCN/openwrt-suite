include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-oxidns
PKG_VERSION:=0.2.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Sven Shi <isvenshi@gmail.com>

LUCI_TITLE:=LuCI support for OxiDNS
LUCI_DEPENDS:=+luci-base +rpcd +jsonfilter +uclient-fetch +ca-bundle +oxidns-core
LUCI_PKGARCH:=all

define Package/luci-app-oxidns/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
# Keep the core binary, webui and configuration across firmware upgrades.
if [ -f /etc/sysupgrade.conf ]; then
	for entry in /etc/oxidns /etc/config/oxidns; do
		grep -qxF "$$entry" /etc/sysupgrade.conf 2>/dev/null || \
			echo "$$entry" >> /etc/sysupgrade.conf
	done
fi
# After a firmware upgrade the persistent core survives; just relink it so the
# service starts again without re-downloading anything.
if [ -x /etc/oxidns/core/oxidns ] && [ ! -x /usr/bin/oxidns ]; then
	mkdir -p /usr/bin
	ln -sf /etc/oxidns/core/oxidns /usr/bin/oxidns
fi
if [ -d /etc/oxidns/core/webui ] && [ ! -d /usr/share/oxidns/webui ]; then
	mkdir -p /usr/share/oxidns
	ln -sfn /etc/oxidns/core/webui /usr/share/oxidns/webui
fi
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -d /www/luci-static/resources/view/oxidns ]; then
	find /www/luci-static/resources/view/oxidns -type f -name '*.js' -exec touch {} + 2>/dev/null || true
fi
if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
exit 0
endef

define Package/luci-app-oxidns/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
