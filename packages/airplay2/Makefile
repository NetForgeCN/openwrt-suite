#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
# updated to work with latest source from abrasive
#

include $(TOPDIR)/rules.mk

PKG_NAME:=airplay2
PKG_VERSION:=5.6.3
PKG_RELEASE:=1

PKG_SOURCE:=shairport-sync-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/mikebrady/shairport-sync/tar.gz/$(PKG_VERSION)?
PKG_HASH:=670f9cefdb9c2d70f7df71890e63ab0a31d08a815dd0734245d935bfd01e766e

PKG_MAINTAINER:=Ted Hess <thess@kitschensync.net>, \
		Mike Brady <mikebrady@eircom.net>
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=COPYING LICENSES shairport.c

# The source tarball unpacks into shairport-sync-$(PKG_VERSION), not
# $(PKG_NAME)-$(PKG_VERSION), so the build directory has to be set by hand.
PKG_BUILD_DIR:=$(BUILD_DIR)/shairport-sync-$(PKG_VERSION)

# Shairport Sync 5.6.x uses Shared Memory Interface Version 11 ("smi11"), so the
# nqptp companion daemon must be 1.2.9 or newer. The nqptp in the OpenWrt
# packages feed is 1.2.4 ("smi10") and cannot be used with this version --
# install the nqptp package shipped in this feed instead.

# shairport-sync 5.x cannot build --with-airplay-2 against mbed TLS, so this
# package is OpenSSL only. The former airplay2-mbedtls / airplay2-mini variants
# have been dropped: without AirPlay 2 they are just an older, less capable
# shairport-sync, and they also broke the build. This mirrors the way the
# package in the OpenWrt packages feed is set up (AirPlay 2 = OpenSSL only).

PKG_FIXUP:=autoreconf
PKG_INSTALL:=1
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

# --- Audio / video feature gate -------------------------------------------
# There have been three generations of this gate:
#   <= 24.10   kconfig symbol AUDIO_SUPPORT          (referenced in sound.mk)
#   master     real packages audio-support / video-support
#   snapshots  in between: symbol gone, packages not there yet
# A gate that does not resolve makes OpenWrt drop the package from the
# metadata entirely (it simply does not appear in menuconfig, with no error),
# so only apply one when this tree actually provides it.
AIRPLAY2_AUDIO_GATE:=$(if $(shell grep -qs AUDIO_SUPPORT "$(TOPDIR)/package/kernel/linux/modules/sound.mk" && echo 1),@AUDIO_SUPPORT,)

# On master libffmpeg defaults to FFMPEG_LIBDRM=y and libdrm depends on
# video-support; OpenWrt propagates that as (!FFMPEG_LIBDRM ||
# PACKAGE_video-support) onto every libffmpeg consumer and hides it when the
# condition is unmet. Only select it where the package exists.
AIRPLAY2_VIDEO_GATE:=$(if $(wildcard $(TOPDIR)/package/system/hardware-support/Makefile),+video-support,)

define Package/airplay2
  SECTION:=sound
  CATEGORY:=Sound
  TITLE:=AirPlay and AirPlay 2 compatible audio player
  DEPENDS:=$(AIRPLAY2_AUDIO_GATE) $(AIRPLAY2_VIDEO_GATE) \
	+libpthread +alsa-lib +libconfig +libdaemon +libpopt \
	+libmosquitto +libopenssl +libavahi-client +libsoxr \
	+libplist +libsodium +libgcrypt +libffmpeg-full +libuuid +nqptp
  URL:=https://github.com/mikebrady/shairport-sync
endef

define Package/airplay2/description
  Shairport Sync plays audio from iTunes and AirPlay sources, including
  iOS devices, Quicktime Player and third party sources such as forkedDaapd.
  Audio played by a Shairport Sync-powered device stays synchronised with the source
  and hence with similar devices playing the same source.

  Shairport Sync does not support AirPlay video or photo streaming.
  Ensure Kernel Modules > Sound Support > kmod-sound-core is selected.
  Also select kmod-usb-audio if you want to use USB-connected sound cards.

  This build uses OpenSSL and includes AirPlay 2 support.
endef

TARGET_CFLAGS += -std=gnu17

CONFIGURE_ARGS += \
	--with-alsa \
	--with-libdaemon \
	--with-pipe \
	--with-mqtt-client \
	--with-metadata \
	--with-avahi \
	--with-soxr \
	--with-ssl=openssl \
	--with-airplay-2

TARGET_LDFLAGS += -Wl,--as-needed

define Package/airplay2/conffiles
/etc/config/airplay2
endef

define Package/airplay2/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/shairport-sync $(1)/usr/bin/airplay2
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/airplay2.init $(1)/etc/init.d/airplay2
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/airplay2.config $(1)/etc/config/airplay2
endef

$(eval $(call BuildPackage,airplay2))
