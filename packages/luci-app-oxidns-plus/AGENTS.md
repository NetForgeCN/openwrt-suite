# AGENTS.md

## What this repository is

`luci-app-oxidns-plus` is an **add-on** for an existing OxiDNS 1.7.x runtime on
OpenWrt. It adds TTL-aware cache warming, DHCP-lease hostname learning,
upstream latency diagnostics, a LuCI page, and automated rollback.

It is owned by NetForgeCN. It is **not** a fork of, and never pushes to,
`svenshi/oxidns`. It also does **not** modify `NetForgeCN/luci-app-oxidns`:
no shared file is overwritten, and the add-on is designed to be installed
side by side with the base LuCI app.

## Hard boundaries

- **No code in this repository reads or writes `/etc/oxidns/config.yaml`.**
  Not the rpcd backend, not the LuCI page, not the helper scripts, not the
  init script, not the install/remove hooks. Since 0.2.0 there is no config
  template, no config tuning RPC, and no config health check. Main-config
  edits (TTL values, upstreams, ECS, hosts files) belong to the user, made
  directly in their own file. This is deliberate: a single number change is
  faster and clearer in the file than through a UI action.
- The OxiDNS core binary is **not** in this repository. The base package
  `luci-app-oxidns` (and its optional `oxidns-core` build recipe) ships the
  official prebuilt musl binary. This repository contains **no Rust code**.
- Frontend pages must call system operations through rpcd. No shell/system
  actions directly in LuCI JavaScript.
- Do not echo API passwords into UI, logs or RPC error messages.
- Do not ship anything that looks like a "recommended config" or a
  "config suggestion". Documentation may *state* which main-config line a
  feature needs, but must not generate, patch or validate that file.

## Why an add-on and not a full fork

The base app has five LuCI JS pages and a ~66 KB rpcd backend. Copying them
would be pure duplication with no functional gain, and would collide with the
base package on every path (UCI, init.d, menu, rpcd object, ACL). The add-on
uses its own namespace on every axis.

## Namespaces (keep all of these distinct from the base app)

| Axis | Base app | This add-on |
|---|---|---|
| Package | `luci-app-oxidns` | `luci-app-oxidns-plus` |
| UCI | `oxidns.main` | `oxidnsplus.main` |
| init.d | `/etc/init.d/oxidns` | `/etc/init.d/oxidnsplus` |
| rpcd object | `luci.oxidns` | `luci.oxidnsplus` |
| ACL group | `luci-app-oxidns` | `luci-app-oxidns-plus` |
| LuCI menu | `admin/services/oxidns` | `admin/services/oxidnsplus` |
| LuCI view | `oxidns/*` | `oxidnsplus/plus` |
| i18n catalog | `oxidns` | `oxidnsplus` |
| Conffiles | `/etc/config/oxidns` | `/etc/config/oxidnsplus`, `/etc/oxidns/warm.list` |

## Runtime design notes

- Warming and DHCP sync run from the **system crond**, not from OxiDNS's
  internal `cron`/`script` plugins. This is the reason the add-on never needs
  to edit `config.yaml` for those features. The init script owns a marked
  block in `/etc/crontabs/root` (`# oxidns-plus:begin` / `end`) and replaces
  it idempotently.
- **Warming is TTL-aware, not fixed-interval.** `warm_interval` is the crond
  poll period (default 1 minute), not a refresh period. The warmer keeps a
  per-`(domain,type)` record of the last observed answer TTL in
  `/tmp/oxidnsplus-warm.entries` and only queries a pair that is due. Due
  means `now + poll >= last + refresh_at`, where `refresh_at` is derived from
  the TTL minus a configurable margin and clamped by `warm_min_ttl` /
  `warm_max_ttl`. The look-ahead is what makes minute-grained crond safe.
- The TTL is read from `dig +noall +answer` field 2 (minimum across CNAME
  chains). NODATA/NXDOMAIN/blocked answers have no TTL and use
  `warm_noanswer_ttl`; failed queries use `warm_retry_ttl` as backoff.
- A change in the OxiDNS process-set signature, a missing state file, an
  explicit `--force`, or a saved warm list forces a full baseline rebuild.
  A core restart invalidates the in-memory cache, so this is required.
- The init script also fires one warmer run in the background at start,
  because a cron job waits one full interval before its first trigger.
- DHCP sync only calls the OxiDNS reload API when the generated file actually
  changed and `dhcp_auto_reload` is enabled. Reload costs cache entries newer
  than the last `cache.dump` (600 s by default), so it is off by default.
- **To use DHCP hostnames, the user must add
  `/etc/oxidns/dhcp-hosts` to `hosts_system.files` in their own
  `config.yaml`.** The package creates an empty stub so that reference can
  never break a start. It never adds that line itself.

## Automated rollback

- `/etc/init.d/oxidnsplus stop` removes the cron block and reloads crond.
- `cleanup` drops all `/tmp` state and rewrites the DHCP hosts file as an
  empty stub (it is intentionally **not deleted**: the user's config may
  still reference it).
- `prerm` runs before package files are removed: `stop` + `disable` +
  `cleanup` + remove exactly the three lines postinst appended to
  `/etc/sysupgrade.conf`.
- `postrm` is a belt-and-braces repeat for package managers that skip prerm.
- `restore_defaults` RPC resets `/etc/config/oxidnsplus` and the warm list
  from read-only copies in `/usr/share/oxidnsplus/`, clears state and
  reinstalls the cron block. It never touches `config.yaml`.
- Because the main config is never modified, uninstalling the package leaves
  the OxiDNS installation exactly as it was. The only optional leftovers are
  conffiles (opkg keeps them by default), the empty `dhcp-hosts` stub, and
  its reference in the user's own config.yaml.

## Key paths

- `Makefile` - OpenWrt package definition, conffiles, postinst/prerm/postrm.
- `root/etc/config/oxidnsplus` - default UCI settings.
- `root/etc/init.d/oxidnsplus` - cron block, cold-start warming, `cleanup`.
- `root/etc/oxidns/warm.list` - editable warm domain list.
- `root/usr/libexec/oxidnsplus-warm.sh` - TTL-aware cache keeper.
- `root/usr/libexec/oxidnsplus-dhcp-hosts.sh` - lease to hosts file.
- `root/usr/libexec/oxidnsplus-diagnose.sh` - upstream latency report.
- `root/usr/libexec/rpcd/luci.oxidnsplus` - rpcd backend.
- `root/usr/share/rpcd/acl.d/luci-app-oxidns-plus.json` - ACL.
- `root/usr/share/luci/menu.d/luci-app-oxidns-plus.json` - menu.
- `root/usr/share/oxidnsplus/uci.defaults` - read-only default UCI copy.
- `root/usr/share/oxidnsplus/warm.list.defaults` - read-only default list copy.
- `htdocs/luci-static/resources/view/oxidnsplus/plus.js` - LuCI page.
- `po/zh_Hans/oxidnsplus.po` - Simplified Chinese translation.
- `scripts/check.sh` - local static validation.

## Validation

```sh
scripts/check.sh
```

On a device, the real acceptance test is:

```sh
/etc/init.d/oxidnsplus restart
/etc/init.d/oxidnsplus warm
cat /tmp/oxidnsplus-warm.state
cat /tmp/oxidnsplus-warm.entries
logread -e oxidns-plus
```

`scripts/check.sh` enforces the "no main-config access" rule by scanning
every executable file for the removed RPC names and config identifiers.

## Commit notes

- Conventional Commits.
- Any new rpcd method must be added to **all three**: the `list` signature,
  the `call` dispatcher, and the ACL JSON.
- Any new UCI option must be added to the default config, `uci.defaults`,
  `settings_read`, `settings_save` and its signature, the LuCI form,
  `docs/CONFIGURATION.md`, and the Chinese po file.
- `uci.defaults` and `warm.list.defaults` must stay byte-identical to their
  `/etc` counterparts; `check.sh` asserts this.
