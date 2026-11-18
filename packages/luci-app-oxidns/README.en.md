# luci-app-oxidns

Language: [中文](./README.md) | English

`luci-app-oxidns` is the LuCI management app for OxiDNS on OpenWrt. After installation, LuCI adds `Services -> OxiDNS` pages for managing the OxiDNS core binary, the OpenWrt service, configuration, and logs.

Built on [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns). Licensed under GPL-3.0-or-later.

## Features

| Capability | Description |
|---|---|
| Core binary location | `/etc/oxidns/core/oxidns` (persistent); runtime path `/usr/bin/oxidns` is a symlink |
| Configuration persistence | `/etc/oxidns` and `/etc/config/oxidns` are added to `/etc/sysupgrade.conf`, so config survives a "keep settings" firmware upgrade |
| Recovery after sysupgrade | Symlinks are rebuilt automatically; reinstall the package once and the service is back |
| Core upgrades | `Check Update` button on the `Core` page |
| Logs | Keyword filter plus `plugin` / `qtype` / `rcode` dropdowns with a live line counter |
| Low-flash devices | Persistence can be disabled in `Settings` |
| Rule subscriptions | `oxidns-rules-baseline` ships the baseline; files are seeded locally at boot, the `Rules` page updates from a repository release |

## Building From Source

### Option 1: OpenWrt buildroot / SDK (recommended, can be baked into firmware)

```sh
# 1. Prepare an OpenWrt build environment matching your target firmware
git clone https://github.com/openwrt/openwrt.git
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a

# 2. Clone this repository as a package (includes the oxidns-core and
#    oxidns-rules-baseline subpackages)
git clone https://github.com/NetForgeCN/luci-app-oxidns.git package/luci-app-oxidns

# 3. Select it in menuconfig (LuCI -> Applications -> luci-app-oxidns; oxidns-core
#    and oxidns-rules-baseline are hard dependencies and get selected with it)
make menuconfig

# 4. Build
make package/luci-app-oxidns/compile V=s
```

**Bundled core**: the `oxidns-core` subpackage downloads the official OxiDNS release for the target architecture at build time (URL and SHA256 pinned in `oxidns-core/Makefile`) and bakes the binary, webui and default config into the firmware/ipk. The installed system has a working core out of the box — no first-run download needed. Runtime updates via the LuCI `Check Update` button are not limited to the pinned version.

**Bundled rules**: `oxidns-rules-baseline` is another build-time download (URL and SHA256 pinned) that lands in `/usr/share/oxidns/rules-baseline`. `luci-app-oxidns` depends on it unconditionally, so a firmware that includes the app always includes the rule baseline: the files are copied into `/etc/oxidns/rules` at package install and again before every service start, which means **the first boot needs no network at all**. Use `Services -> OxiDNS -> Rules` to check for and install newer lists.

- Supported architectures: x86_64, aarch64, i386 (i686 binary), ARM hard-float (cortex → armv7, others → armv6).
- For unsupported architectures (e.g. MIPS), build `luci-app-oxidns` without `oxidns-core` and install the core from the LuCI page instead.
- To bump the core version, edit `PKG_VERSION` and the matching `PKG_HASH` in `oxidns-core/Makefile` and rebuild.

Artifacts land in `bin/packages/<arch>/`: `oxidns-core_*.ipk`, `oxidns-rules-baseline_*.ipk`, `luci-app-oxidns_*.ipk` and `luci-i18n-oxidns-zh-cn_*.ipk`. Selecting `<*>` in menuconfig bakes the plugin, the core and the rule baseline directly into the firmware image.

### Option 2: Quick packaging without the SDK

Requires `node`, `tar`, `gzip`, `sha256sum`:

```sh
git clone https://github.com/NetForgeCN/luci-app-oxidns.git
cd luci-app-oxidns

# Plain package (core downloaded from the LuCI page after install)
./scripts/build-luci-package.sh 0.2.0 dist

# Package with an embedded core (works out of the box on the matching arch)
curl -LO https://github.com/svenshi/oxidns/releases/download/v1.6.1/oxidns-x86_64-unknown-linux-musl.tar.gz
./scripts/build-luci-package.sh 0.2.0 dist-embedded oxidns-x86_64-unknown-linux-musl.tar.gz

# Core plus the rule baseline. The fourth argument is the baseline tarball from
# the release pinned in oxidns-rules-baseline/Makefile.
curl -LO https://github.com/NetForgeCN/luci-app-oxidns/releases/download/rules-v2026.11.17.0223/oxidns-rules-baseline-2026.11.17.0223.tar.gz
./scripts/build-luci-package.sh 0.2.0 dist-embedded oxidns-x86_64-unknown-linux-musl.tar.gz \
	oxidns-rules-baseline-2026.11.17.0223.tar.gz
```

When embedding a core, pick the release asset matching the router CPU (x86_64 / aarch64 / armv7 / i686). postinst unpacks it into `/etc/oxidns/core` on install and creates the symlinks. An embedded rule baseline lands in `/usr/share/oxidns/rules-baseline` and is copied to `/etc/oxidns/rules` by `/etc/init.d/oxidns` on the first start.

## Install On The Router

```sh
opkg install luci-app-oxidns_0.2.0-r1_all.ipk
opkg install luci-i18n-oxidns-zh-cn_0.2.0-r1_all.ipk
# or on apk-based OpenWrt:
apk add --allow-untrusted ./luci-app-oxidns_0.2.0-r1_all.apk
```

Then open LuCI → `Services -> OxiDNS`:

1. Core already in the package (buildroot or embedded-core build): `Configuration` page → edit `config.yaml` → `Save & Restart`, then `Overview` page → `Start` + `Start on boot`;
2. Plain package: `Core` page → `Install Core` (auto-selects the release for your CPU architecture and verifies SHA256; use `Upload Core` offline), then the configuration and start steps above.

## Persistence And Self-Healing

- **Bundled core (build time)**: buildroot builds embed the official core via the `oxidns-core` subpackage; quick packaging embeds one when a core archive is passed as the third argument. The system has DNS capability right after install — no first-run download.
- **Persistent core**: the binary and webui live in `/etc/oxidns/core/` on the persistent partition; runtime paths are symlinks. They survive a sysupgrade with "keep settings".
- **Persistent configuration**: `/etc/oxidns` and `/etc/config/oxidns` are appended to `/etc/sysupgrade.conf` on install.
- **Boot self-healing**: init script, rpcd status and package postinst all recreate missing symlinks from the persistent copy. After a firmware upgrade, reinstalling the package once brings the service back.
- **LuCI core updates**: `Check Update` compares the installed version with the latest GitHub release and updates in place (with SHA256 verification).
- **Log filtering**: keyword filter plus `plugin` / `qtype` / `rcode` dropdowns with a live line counter.

## Firmware Upgrade Steps

1. LuCI → System → Backup / Flash Firmware, check **"keep settings"**;
2. Flash the new firmware;
3. Reinstall this package once (the plugin's own files are wiped by sysupgrade — that is how OpenWrt works);
4. Done. postinst rebuilds the core symlinks automatically; configuration is preserved.

Without "keep settings", everything is wiped — that is the OpenWrt mechanism itself.

## Default Paths

- Binary (runtime): `/usr/bin/oxidns` (symlink)
- Binary (persistent): `/etc/oxidns/core/oxidns`
- WebUI (runtime): `/usr/share/oxidns/webui` (symlink)
- WebUI (persistent): `/etc/oxidns/core/webui`
- Config: `/etc/oxidns/config.yaml`
- Working directory: `/var/lib/oxidns` (tmpfs, runtime only)
- Init script: `/etc/init.d/oxidns`
- Rule baseline (read-only): `/usr/share/oxidns/rules-baseline`
- Rule working copy: `/etc/oxidns/rules` (seeded from the baseline when missing)

## Known Limitations

- Only published Linux musl release targets of OxiDNS are supported.
- Low-flash devices (less free overlay space than the core bundle) should disable `Persist core across upgrades` in `Settings`.
- The `Overview` WebUI entry is generated from the HTTP listen address; `127.0.0.1` requires local access or an SSH tunnel.
- Private core repositories or restricted networks can use a GitHub token or download proxy in `Settings` (requires `curl`).
- The rule baseline unpacks to about 24MB (7 lists) and is a hard dependency: `luci-app-oxidns` declares `+oxidns-rules-baseline`, so selecting the app compiles the baseline into the firmware too. `Rules` page updates come from this repository's release assets.

## License

GPL-3.0-or-later, see [LICENSE](LICENSE). Based on [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns) and [svenshi/oxidns](https://github.com/svenshi/oxidns). Thanks to the original author.
