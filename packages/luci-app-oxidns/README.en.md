# luci-app-oxidns (NetForgeCN)

[中文](./README.md)

A LuCI management app for OxiDNS on OpenWrt. Once installed, `Services -> OxiDNS` gives you a complete UI for the core binary, configuration, service, logs, rule subscriptions and DNS prewarming.

Built on the [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns) framework, with one extra goal: **installed and ready, resilient across upgrades, and popular domains already resolved**. Licensed under GPL-3.0-or-later.

## What this fork adds

| Capability | What you get | Why it matters |
|---|---|---|
| Bundled core | `oxidns-core` packages the official binary, WebUI and default config at build time | DNS works right after flashing; no first-run core download |
| Bundled rule baseline | `oxidns-rules-baseline` ships five rule lists | First boot works offline; missing rule files are restored automatically |
| Rule subscriptions | `Rules` page checks and applies updates with SHA256 verification, staging and rollback | One-click rule updates, validated and staged before replacement |
| DNS prewarming | `Prewarm` page queries A / AAAA records ahead of time and fills the cache | First visit to common domains is served from cache |
| Core upgrades | `Core -> Check Update` | Upgrade the core without rebuilding firmware |
| Log filtering | Keyword plus `plugin` / `qtype` / `rcode` filters and a live line count | Find the queries you care about, even in large logs |
| DNS hijack | `DNS Hijack` page redirects LAN port 53 to the local OxiDNS listener, IPv4 and IPv6 | LAN clients use OxiDNS without changing their DNS setting, with real client IPs visible |
| CodeMirror editor | Configuration page uses a YAML syntax-highlighting editor with line numbers and an internal scroll viewport | Editing long configs no longer jumps the page |
| Geo data management | `Geo Data` page downloads/updates geoip.dat and geosite.dat; URLs are editable and restorable | Refresh geo data without rebuilding firmware; defaults use the self-maintained rule source |
| API password handling | Password lives in UCI and is injected into both the service and rpcd | No plaintext password in YAML; config validation and service stay in sync |
| Upgrade self-healing | Core, WebUI, config and rules recover after sysupgrade | Keep settings, reinstall the app once, and the service is back |

## Pages

| Page | Purpose |
|---|---|
| `Overview` | Core / service status, WebUI entry, config path, log status |
| `Core` | Install, upload, upgrade, repair or remove the core |
| `DNS Hijack` | LAN port 53 redirect switch, target port source, firewall section status |
| `Configuration` | CodeMirror highlighting, validate and save `config.yaml` |
| `Logs` | Filter and refresh OxiDNS logs |
| `Settings` | Repository, bundle, proxy, paths, logging and API password |
| `Rules` | Baseline status, check for updates, apply updates |
| `Geo Data` | geoip.dat / geosite.dat status, download URLs, directory, online update |
| `Prewarm` | Enable switch, domain list, target endpoint, interval and manual run |

## Quick start

1. Install the package as described in “Build and install”.
2. Set the API password; it is stored only in UCI:

   ```sh
   uci set oxidns.main.api_pass="$(openssl rand -base64 24)"
   uci commit oxidns
   /etc/init.d/rpcd restart
   ```

3. Open `Services -> OxiDNS -> Configuration`, adjust `config.yaml`, then click `Save & Restart`.
4. Open `Overview`, start the service and enable it at boot.
5. Open `Prewarm`, make sure the target matches the listener in `config.yaml`, then click `Run now`.

## DNS prewarming

Prewarming walks the domain list and sends A and AAAA queries to the selected OxiDNS listener. The queries pass through that listener's rule chain, fill the cache, and later client requests hit the cache directly.

| Item | Default |
|---|---|
| Enabled | yes |
| Target | `udp://127.0.0.1:5333` |
| Interval | 3000 seconds (~50 minutes) |
| List | 89 bundled domains, editable in the page |
| Concurrency | 4 |
| Query timeout / retries | 2 seconds / 1 |

Three things make prewarming effective:

- `config.yaml` contains a `cache` plugin on the chain used by the target listener;
- the IP, port and protocol in the page match the listener's `listen` value;
- the router has `dig`, or an `nslookup` that supports `-port`.

`Server IP` accepts `127.0.0.1` or `192.168.1.1`; port and protocol are free-form. `Run now` ignores the enable switch and always runs one pass. An interval of `0` runs once at service start.

Verify it:

```sh
logread -t oxidns-prewarm              # per-pass results
/usr/libexec/oxidns-prewarm --once     # run one pass manually
dig @127.0.0.1 -p 5333 youtube.com A   # confirm the listener responds
```

## Rule baseline

The baseline ships only the five lists OxiDNS actually loads. Lists are fetched and validated at build time, so the device never converts formats:

| File | Purpose |
|---|---|
| `cn-domains.txt` | Long-tail China domains, used with geosite |
| `anti-ad-domains.txt` | anti-AD domain list |
| `adrules-domains.txt` | AdRules domain list |
| `neodevhost-domains.txt` | neoDevHost domain list |
| `adguard-hostlist.txt` | AdGuard HostlistsRegistry rules |

`cn-domains.txt` is converted from dnsmasq-china-list on the build machine; the original conf is not shipped. Updates go through the `Rules` page: staged, validated, then swapped in. If validation does not pass, the previous set is kept.

## Build and install

### Option 1: OpenWrt buildroot (recommended, can be baked into firmware)

```sh
git clone https://github.com/openwrt/openwrt.git
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a

git clone https://github.com/NetForgeCN/luci-app-oxidns.git package/luci-app-oxidns
make menuconfig
# LuCI -> Applications -> luci-app-oxidns
make package/luci-app-oxidns/compile V=s
```

`oxidns-core` and `oxidns-rules-baseline` are hard dependencies and are selected with the app. Artifacts appear in `bin/packages/<arch>/`.

Supported targets: x86_64, aarch64, i386 and ARM hard-float (cortex maps to armv7, others to armv6). On architectures without a published musl core (for example MIPS), leave `oxidns-core` unselected and upload a core from the page.

### Option 2: Quick packaging

Requires `node`, `tar`, `gzip` and `sha256sum`:

```sh
git clone https://github.com/NetForgeCN/luci-app-oxidns.git
cd luci-app-oxidns

# App only; install the core later from LuCI
./scripts/build-luci-package.sh 0.2.0 dist

# App with embedded core and rule baseline (pick the asset for your CPU)
curl -LO https://github.com/svenshi/oxidns/releases/download/v1.7.1/oxidns-x86_64-unknown-linux-musl.tar.gz
curl -LO https://github.com/NetForgeCN/luci-app-oxidns/releases/download/rules-v2026.11.24.0419/oxidns-rules-baseline-2026.11.24.0419.tar.gz
./scripts/build-luci-package.sh 0.2.0 dist-embedded \
	oxidns-x86_64-unknown-linux-musl.tar.gz \
	oxidns-rules-baseline-2026.11.24.0419.tar.gz
```

Install:

```sh
opkg install luci-app-oxidns_*.ipk
opkg install luci-i18n-oxidns-zh-cn_*.ipk
# apk systems:
apk add --allow-untrusted ./luci-app-oxidns_*.apk
```

## Persistence and upgrades

- Core and WebUI live in `/etc/oxidns/core/`; runtime paths are symlinks.
- `/etc/oxidns` and `/etc/config/oxidns` are added to `/etc/sysupgrade.conf`, so configuration survives a keep-settings upgrade.
- At boot, missing symlinks and rule files are restored from persistent storage.
- For a firmware upgrade, keep settings, flash, then reinstall the app once.
- Upgrade the core with `Core -> Check Update` and the lists with `Rules`; they are independent.

## Default paths

| Purpose | Path |
|---|---|
| Core (runtime / persistent) | `/usr/bin/oxidns` → `/etc/oxidns/core/oxidns` |
| WebUI (runtime / persistent) | `/usr/share/oxidns/webui` → `/etc/oxidns/core/webui` |
| Core config | `/etc/oxidns/config.yaml` |
| Working directory | `/var/lib/oxidns` |
| UCI config | `/etc/config/oxidns` |
| Rule baseline (read-only) | `/usr/share/oxidns/rules-baseline` |
| Rule working copy | `/etc/oxidns/rules` |
| Prewarm list | `/etc/oxidns/prewarm.txt` |
| Init script | `/etc/init.d/oxidns` |

## License

GPL-3.0-or-later, see [LICENSE](LICENSE). Built on [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns) and [svenshi/oxidns](https://github.com/svenshi/oxidns); thanks to the original authors.
