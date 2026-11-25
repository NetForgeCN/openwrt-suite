#
# Copyright (C) 2015-2016 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v3.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=v2ray-geodata
PKG_VERSION:=$(shell if [ -n "$$SOURCE_DATE_EPOCH" ]; then date -u -d "@$$SOURCE_DATE_EPOCH" +%Y.%m.%d; else date -u +%Y.%m.%d; fi)
# 版本跟随可复现构建时间戳；规则数据由仓库根 geodata.pin 注入（勿手改）
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=sbwml <admin@cooluc.com>

include $(INCLUDE_DIR)/package.mk

define Package/v2ray-geodata/default
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=IP Addresses and Names
  URL:=https://www.v2fly.org
  PKGARCH:=all
endef

define Package/v2ray-geoip
  $(call Package/v2ray-geodata/default)
  TITLE:=GeoIP List for V2Ray
  LICENSE:=CC-BY-SA-4.0
endef

define Package/v2ray-geosite
  $(call Package/v2ray-geodata/default)
  TITLE:=Geosite List for V2Ray
  LICENSE:=GPL-3.0
endef

# 不用 latest：latest 可能指向只含备份资产的 release导致 404；哈希也不再从同源现取
# 以下五项由 patches/geodata.sh 从仓库根 geodata.pin 注入，请勿在此手动修改
GEODATA_TAG:=202611250113
GEOIP_SHA256:=d4ec4c5e5d5a38c1399964ea9fd8c94288426a3b31b483904b67819fc07f4466
GEOSITE_SHA256:=67ccb3cda9fb1b118be77d4aeb954d16fe3a12c63a6006e72709ad12dee7aab2
GEOIP_URL:=https://github.com/NetForgeCN/v2ray-rules-dat/releases/download/202611250113/geoip.dat
GEOSITE_URL:=https://github.com/NetForgeCN/v2ray-rules-dat/releases/download/202611250113/geosite.dat

# HTTPS only (including redirects), fail on HTTP/TLS errors, bounded time and
# size, with retries. Each URL is downloaded exactly once per build.
CURL_FLAGS:=--fail --silent --show-error --proto '=https' --proto-redir '=https' --location --max-redirs 5 --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 --max-filesize 67108864

define Build/Compile
	( \
		set -e ; \
		cd $(PKG_BUILD_DIR) ; \
		curl --proto =https --proto-redir =https --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 --max-time 300 $(GEOIP_URL) -o geoip.dat ; \
		curl --proto =https --proto-redir =https --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 --max-time 300 $(GEOSITE_URL) -o geosite.dat ; \
		printf "%s  %s\n" "$(GEOIP_SHA256)" geoip.dat | sha256sum -c - ; \
		printf "%s  %s\n" "$(GEOSITE_SHA256)" geosite.dat | sha256sum -c - ; \
	)
endef

define Package/v2ray-geoip/install
	$(INSTALL_DIR) $(1)/usr/share/v2ray
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/geoip.dat $(1)/usr/share/v2ray/geoip.dat
endef

define Package/v2ray-geosite/install
	$(INSTALL_DIR) $(1)/usr/share/v2ray
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/geosite.dat $(1)/usr/share/v2ray/geosite.dat
endef

$(eval $(call BuildPackage,v2ray-geoip))
$(eval $(call BuildPackage,v2ray-geosite))
