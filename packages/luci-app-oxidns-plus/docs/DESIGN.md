# Design

## Scope

A single static Rust daemon + LuCI/rpcd/UCI. No changes to the OxiDNS core, no
edits to `config.yaml`, no second cache implementation. Zero external crates:
JSON/HTTP/DNS are implemented with the standard library so the binary stays
small and has no supply-chain surface.

The daemon is compiled from source at package-build time by OpenWrt's native
Rust cross-toolchain (`rust/host` + `rust-package.mk`), which derives the musl
target triple and linker from `$(ARCH)`. Supported architectures mirror
`oxidns-core`: x86_64, aarch64, i386, arm (armv6/armv7). No prebuilt binary is
committed and no GitHub Release is downloaded. The source is platform-neutral
(no `cfg(target_arch)`, no inline asm, no pointer-width assumptions).

## Lifecycle of one entry (stale-hit trigger)

```
GET entries -> ttl, remaining_ttl (live truth)
  expire_at   = now + remaining_ttl
  trigger     = expire_at + grace + jitter
                     |
                     v (deadline reached, single-flight)
  DNS query -> OxiDNS listener (stale hit)
                     |
                     v
  OxiDNS native lazy cache: async background refresh + writeback
                     |
                     v (refresh_delay)
  GET entries -> remaining_ttl jumped?  yes -> reschedule from NEW ttl
                                        no  -> keep old cache, backoff retry
```

## Why grace lands in the stale window

`cache` plugin docs: "The original response TTL still defines the fresh-hit
window. `lazy_cache_ttl` defines the stale reply TTL. Stale hits trigger an
asynchronous background refresh. This setting does not shorten the original
fresh TTL." A probe in the fresh window is a fresh hit (no refresh). So the
trigger must be just after `expire_at`. `grace` (default 3s) absorbs clock skew
and API rounding.

## TTL tracking — no local state file

`remaining_ttl` from the API is already the live decreasing value. Reading it
as truth each reconcile removes the drift that a local `cache_time/original_ttl`
file would accumulate, and naturally follows upstream TTL changes (120→300).
A genuine upward jump is the only event that resets a deadline; natural decay
never does.

## Failure handling

- Trigger transport error → backoff and retry; old cache untouched.
- No TTL recovery within `refresh_delay` → treat as failed, keep old cache,
  retry with exponential backoff (base 15s, cap 300s, max count 8).
- Cold start (no entry yet) → immediate probe seeds the cache, then schedules
  from the returned TTL.

## Guardrails

- Single-flight per `(domain,qtype)` via an in-flight flag under mutex.
- Jitter added to every deadline to avoid synchronized bursts.
- TTL < `min_ttl` uses a fixed lead (`min_interval`) instead of a tiny ratio.
- Only entries with a real non-0.0.0.0/:: A/AAAA answer are scheduled.
- Minimum interval between two probes of the same key.

## API surface used (all read-only on OxiDNS)

`GET /api/plugins/<cache_tag>/entries?qname=&limit=`. Nothing else. No delete,
no flush, no insert, no config write.

## Verification

- `scripts/build.sh`: Rust unit tests + static musl builds for all five
  architectures (x86_64/aarch64/i386/armv7/armv6), using rust-lld per target.
- `scripts/check.sh`: shell/JS/JSON syntax, cargo tests, i18n completeness,
  rpcd list/call/ACL alignment, UCI/JS field alignment, hard-rule assertions.
- End-to-end (development): real binary driven against a mock OxiDNS
  (HTTP API + UDP DNS listener) on a Linux host, verifying cold seed, stale
  refresh, TTL 120→300 follow, backoff and schedule timing.
