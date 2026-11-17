#
# Copyright (C) 2026 NetForgeCN
#
# This is free software, licensed under the GNU General Public License v3.
# See /LICENSE for more information.
#
# Ships a baseline copy of every rule subscription used by OxiDNS so a fresh
# install (or a device whose rule files were wiped) can start without any
# network access:
#
#   /usr/share/oxidns/rules-baseline/   read-only, replaced on package upgrade
#   /etc/oxidns/rules/                  working copy, seeded from the baseline
#                                       by /etc/init.d/oxidns when a file is
#                                       missing, updated at runtime by the
#                                       LuCI "Rules" page
#
# Why this package exists: domain_set / adguard_rule abort the whole OxiDNS
# process when a referenced file is missing or contains an unparsable line,
# and every download/reload path runs after plugin initialisation. Without a
# local copy the first boot depends on six upstream URLs being reachable.
#
# The archive is produced by scripts/build-rules-baseline.sh and published as
# a release asset (tag rules-v<version>) on this repository.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=oxidns-rules-baseline
PKG_VERSION:=2026.11.17.0223
PKG_RELEASE:=1
PKGARCH:=all

PKG_LICENSE:=GPL-3.0-or-later MIT 0BSD
PKG_LICENSE_FILES:=LICENSES/AdGuardSDNSFilter.LICENSE LICENSES/anti-AD.LICENSE \
	LICENSES/AdRules.LICENSE LICENSES/neodevhost.LICENSE \
	LICENSES/dnsmasq-china-list.LICENSE
PKG_MAINTAINER:=NetForgeCN

PKG_SOURCE:=oxidns-rules-baseline-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/NetForgeCN/luci-app-oxidns/releases/download/rules-v$(PKG_VERSION)/
PKG_HASH:=cb6b246969dbbdfb800174694e4282efbb4520ce6a8292e72f169ba094db6d25

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/oxidns-rules-baseline
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=DNS
  TITLE:=OxiDNS built-in rule subscriptions baseline
  URL:=https://github.com/NetForgeCN/luci-app-oxidns
  PKGARCH:=all
endef

define Package/oxidns-rules-baseline/description
  Bundled baseline of the OxiDNS rule subscriptions (China domain list plus
  three ad domain lists). Installed to /usr/share/oxidns/rules-baseline and
  used to seed /etc/oxidns/rules when files are missing, so the DNS service
  starts without downloading anything. Runtime updates are handled by the
  LuCI "Rules" page, which pulls a newer release of the same archive.
endef

define Build/Compile
endef

define Package/oxidns-rules-baseline/install
	$(INSTALL_DIR) $(1)/usr/share/oxidns/rules-baseline
	$(CP) $(PKG_BUILD_DIR)/. $(1)/usr/share/oxidns/rules-baseline/
endef

$(eval $(call BuildPackage,oxidns-rules-baseline))
