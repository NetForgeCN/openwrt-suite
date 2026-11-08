include $(TOPDIR)/rules.mk
include $(CURDIR)/version.mk

PKG_NAME:=open-nexttrace-core
PKG_VERSION:=$(NEXTTRACE_VERSION)
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only
PKG_SOURCE_URL:=https://github.com/nxtrace/NTrace-core/releases/download/$(NEXTTRACE_TAG)

# Go's MIPS softfloat builds also run on CPUs with an FPU. Never ship the
# hardfloat MIPS asset to the many OpenWrt routers which have no FPU.
NEXTTRACE_ARCH:=
ifeq ($(ARCH),aarch64)
  NEXTTRACE_ARCH:=arm64
endif
ifeq ($(ARCH),arm)
  NEXTTRACE_ARCH:=armv5
  ifneq ($(filter arm1176jzf-s arm11mpcore,$(CPU_TYPE)),)
    NEXTTRACE_ARCH:=armv6
  endif
  ifneq ($(filter cortex-a% cortex-r%,$(CPU_TYPE)),)
    NEXTTRACE_ARCH:=armv7
  endif
endif
ifeq ($(ARCH),i386)
  NEXTTRACE_ARCH:=386
endif
ifeq ($(ARCH),x86_64)
  NEXTTRACE_ARCH:=amd64
endif
ifeq ($(ARCH),mips)
  NEXTTRACE_ARCH:=mips
  ifeq ($(CONFIG_SOFT_FLOAT),y)
    NEXTTRACE_ARCH:=mips_softfloat
  endif
endif
ifeq ($(ARCH),mipsel)
  NEXTTRACE_ARCH:=mipsle
  ifeq ($(CONFIG_SOFT_FLOAT),y)
    NEXTTRACE_ARCH:=mipsle_softfloat
  endif
endif
ifeq ($(ARCH),mips64)
  NEXTTRACE_ARCH:=mips64
  ifeq ($(CONFIG_CPU_LITTLE_ENDIAN),y)
    NEXTTRACE_ARCH:=mips64le
  endif
endif
ifneq ($(filter mips64el mips64le,$(ARCH)),)
  NEXTTRACE_ARCH:=mips64le
endif
ifeq ($(ARCH),riscv64)
  NEXTTRACE_ARCH:=riscv64
endif
ifeq ($(ARCH),loongarch64)
  NEXTTRACE_ARCH:=loong64
endif
ifeq ($(ARCH),loong64)
  NEXTTRACE_ARCH:=loong64
endif
ifeq ($(ARCH),powerpc64)
  NEXTTRACE_ARCH:=ppc64
endif
ifeq ($(ARCH),powerpc64le)
  NEXTTRACE_ARCH:=ppc64le
endif
ifeq ($(ARCH),s390x)
  NEXTTRACE_ARCH:=s390x
endif

PKG_SOURCE:=nexttrace-$(PKG_VERSION)_linux_$(NEXTTRACE_ARCH)
PKG_SOURCE_URL_FILE:=nexttrace_linux_$(NEXTTRACE_ARCH)
PKG_HASH:=$(NEXTTRACE_HASH_$(NEXTTRACE_ARCH))
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)-$(NEXTTRACE_ARCH)
# These are upstream prebuilt ELF files, potentially UPX packed. Keep them
# byte-for-byte intact rather than running the OpenWrt target strip tool.
STRIP:=:
RSTRIP:=:
PKG_CHECK_FORMAT_SECURITY:=0

include $(INCLUDE_DIR)/package.mk

define Package/open-nexttrace-core
  SECTION:=net
  CATEGORY:=Network
  TITLE:=NextTrace upstream prebuilt core
  URL:=https://github.com/nxtrace/NTrace-core
  DEPENDS:=@(aarch64||arm||i386||x86_64||mips||mipsel||mips64||mips64el||mips64le||riscv64||loongarch64||loong64||powerpc64||powerpc64le||s390x) +ca-bundle
  CONFLICTS:=nexttrace
endef

define Package/open-nexttrace-core/description
 Architecture-specific NextTrace release binary, verified by SHA-256.
 No Go compiler or NTrace-core source compilation is required.
endef

define Build/Prepare
	$(if $(NEXTTRACE_ARCH),,$(error Unsupported NextTrace CPU architecture: $(ARCH)))
	$(if $(PKG_HASH),,$(error Missing SHA-256 for NextTrace architecture: $(NEXTTRACE_ARCH)))
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) $(DL_DIR)/$(PKG_SOURCE) $(PKG_BUILD_DIR)/nexttrace
endef

define Build/Configure
endef
define Build/Compile
endef

define Package/open-nexttrace-core/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/share/open-nexttrace
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/nexttrace $(1)/usr/bin/nexttrace
	printf '%s\n' '$(NEXTTRACE_TAG)' > $(1)/usr/share/open-nexttrace/version
endef

$(eval $(call BuildPackage,open-nexttrace-core))
