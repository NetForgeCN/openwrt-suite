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
GEODATA_TAG:=202611270326
GEOIP_SHA256:=9dc8e7de8db8300ce27b606f4a30632265713d2f33bcc568c0d2c44c825c8687
GEOSITE_SHA256:=ee46ede27b8648ba62d6e544d6a0f62a6a2d3e4b5fd2a31dd4c330a13ea33031
GEOIP_URL:=https://github.com/NetForgeCN/v2ray-rules-dat/releases/download/202611270326/geoip.dat
GEOSITE_URL:=https://github.com/NetForgeCN/v2ray-rules-dat/releases/download/202611270326/geosite.dat


# 下载/校验逻辑已抽到 fetch-geodata.sh：Build/Compile 里的内联 shell 在
# OpenWrt package.mk 的 $(call) 二次展开下会把 $$1 / $$url 吃掉首字符，
# 导致 curl 拿到裸串并按 http 处理（--proto '=https' 直接拒绝）。
# Build/Prepare 负责把脚本送进 PKG_BUILD_DIR，Compile 只传 URL 并调用。
define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./fetch-geodata.sh $(PKG_BUILD_DIR)/fetch-geodata.sh
endef

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
