# luci-app-oxidns-plus

TTL-adaptive prewarming add-on for [OxiDNS](https://oxidns.org) 1.7.x on OpenWrt.

This package keeps the domains you care about warm without deleting cache or
querying any upstream by itself. It builds one small **static Rust binary**
(`oxidns-prewarmer`, ~590 KB, musl) **from source at package-build time** using
OpenWrt's native cross-toolchain, plus a LuCI page. It never modifies
`/etc/oxidns/config.yaml`.

Supported architectures mirror `oxidns-core`: **x86_64, aarch64, i386 and arm
(armv6/armv7)**. There is no prebuilt binary and no GitHub Release — the target
triple and cross linker are derived automatically from the OpenWrt build target.

## How it works

OxiDNS's cache plugin already implements stale-while-revalidate via
`lazy_cache_ttl`: while a fresh entry is alive it is served from cache and never
refreshes; once fresh expires, a query hitting the stale entry makes OxiDNS
refresh it asynchronously in the background. This add-on exploits that exact
mechanism — it does **not** reimplement it.

For every `(domain, qtype)` it maintains one independent deadline:

1. Read TTL truth from `GET /api/plugins/cache_main/entries`
   (`ttl`, `remaining_ttl`) — `remaining_ttl` is a live decreasing value, so
   `expire_at = now + remaining_ttl` never drifts and automatically follows TTL
   changes from upstream (e.g. 120s → 300s).
2. Schedule the probe at `expire_at + grace` (just inside the stale window).
3. At the deadline, send one plain DNS query to OxiDNS's own listener
   (`127.0.0.1:5333`). This is a stale hit → OxiDNS fires its native refresh.
4. Wait `refresh_delay`, re-read the API. If `remaining_ttl` jumped back up, the
   refresh succeeded → reschedule from the NEW TTL. If not, keep the old cache
   and retry with exponential backoff.
5. Repeat.

Protections inherited from the design spec: per-key single-flight, jitter,
short-TTL fixed lead (no hammering), backoff, and only entries with real
A/AAAA answers are tracked (negative/black-hole rows are skipped).

### Why not "prewarm before expiry"?
A query that hits a *fresh* entry does not cause OxiDNS to go upstream, so any
probe before fresh expiry is a no-op. The only non-destructive trigger point is
just after fresh expiry (the stale window) — that is what this add-on uses.
Deleting a still-valid cache entry to force a refresh is deliberately avoided:
it would drop working cache and risk an outage if the upstream is down.

## Install

This repository follows the standard OpenWrt feed layout: the package Makefile
lives in the `luci-app-oxidns-plus/` subdirectory, **not** at the repository
root. Add it to `feeds.conf` as its own feed:

```sh
src-git oxidnsplus https://github.com/NetForgeCN/luci-app-oxidns-plus.git
```

Then:

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig   # LuCI -> Applications -> luci-app-oxidns-plus
make -j$(nproc)
```

> **Why the subdirectory matters:** OpenWrt `include/scan.mk` discovers packages
> with `grep -aHE 'call BuildPackage'` and strips the match using
> `sed 's#/Makefile:.*##'`. That pattern requires a `/` before `Makefile`.
> If the Makefile sits at the feed root, the stripped line becomes
> `Makefile:$(eval $(call BuildPackage,...))`, which is then treated as a
> package directory. The result is
> `grep: feeds/oxidnsplus/Makefile:$(eval: No such file or directory` during
> `feeds update`, a broken `.files-packageinfo.mk`, and repeated
> `Ignoring feed 'oxidnsplus' - index missing` during `feeds install -a`.
> The subdirectory layout is what makes `feeds/oxidnsplus.index` generate
> correctly.

The `oxidns-prewarmer` binary is compiled during `make` by OpenWrt's
`feeds/packages/lang/rust` toolchain (`rust/host` + `rust-package.mk`), using the
target's own musl cross compiler. Nothing is downloaded and the repository
ships no prebuilt binary. For workstation-side checks, run `scripts/build.sh`
from the package directory (needs Rust 1.83+ and the musl targets); it compiles
and verifies all five architectures into the gitignored `build/` directory.

**Runtime requirement:** OxiDNS 1.7.x already installed and running, with a
DNS listener (default `127.0.0.1:5333`) and a management API. The add-on reads
the API listen address and username from your config.yaml (read-only). If your
API uses basic auth, set the password in `oxidnsplus.@main[0].api_pass` (or
export `OXIDNS_API_PASS`).

## Configure

LuCI → Services → OxiDNS Plus:

- **Live status**: per-domain TTL, remaining, next probe, last result, counters.
- **Watch list**: domains to prewarm in `list` mode (`domain [A|AAAA]` per line).
- **Settings**: mode (`list` / `all`), grace, min interval, jitter, timings.

Key UCI options (`/etc/config/oxidnsplus`):

| Option | Default | Meaning |
|---|---|---|
| `enabled` | 1 | master switch |
| `mode` | list | `list` = watch list only; `all` = every cached entry |
| `dns_target` | 127.0.0.1:5333 | local OxiDNS listener to probe |
| `cache_tag` | cache_main | cache plugin tag |
| `grace` | 3 | seconds after fresh expiry to fire the probe |
| `refresh_delay` | 1200 | ms to wait before verifying the refresh |
| `min_ttl` | 30 | below this TTL, fixed lead (no short-TTL hammering) |
| `min_interval` | 10 | minimum seconds between probes of one key |
| `jitter` | 5 | random extra seconds on each deadline |
| `retry_base` / `retry_max` / `retry_max_count` | 15 / 300 / 8 | backoff |

Requirements for the OxiDNS side (in your v9 config): `cache.lazy_cache_ttl > 0`
(already the case) and the management API enabled. That is all.

## Layout

```
<repo>/luci-app-oxidns-plus/   <- this package (single feed entry)
  src/prewarmer-rs/  Rust source (pure stdlib, zero crates) + Cargo.lock + unit tests
  root/              OpenWrt files (init, UCI, rpcd, menu, ACL, defaults)
  htdocs/            LuCI view
  po/                zh_Hans translations
  scripts/           build.sh (local 5-arch musl build + tests), check.sh (static validation)
  (no src/bin/: binary is built from source by OpenWrt at package-build time)
```

## Design notes

- "Let OxiDNS own the cache; the add-on owns only the schedule." It stores no
  answers, no IPs, keeps no stale state of its own, and never queries upstream.
- API password handling follows the same single-source rule as the main app:
  UCI is the source; the init script passes it to the daemon at start.
- Uninstall (`prerm`/`postrm`) stops the daemon, clears the status file and
  removes sysupgrade entries. Your main config is never touched.

License: GPL-3.0-or-later.
