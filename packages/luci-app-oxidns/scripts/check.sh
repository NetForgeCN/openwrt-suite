#!/bin/sh

set -eu

node -e "for (const f of ['htdocs/luci-static/resources/view/oxidns/overview.js','htdocs/luci-static/resources/view/oxidns/core.js','htdocs/luci-static/resources/view/oxidns/config.js','htdocs/luci-static/resources/view/oxidns/logs.js','htdocs/luci-static/resources/view/oxidns/settings.js','htdocs/luci-static/resources/view/oxidns/rules.js','htdocs/luci-static/resources/view/oxidns/cache.js']) new Function(require('fs').readFileSync(f,'utf8'));"
node -e "for (const f of ['root/usr/share/luci/menu.d/luci-app-oxidns.json','root/usr/share/rpcd/acl.d/luci-app-oxidns.json','root/usr/share/oxidns/targets.json']) JSON.parse(require('fs').readFileSync(f,'utf8'));"
node <<'NODE'
const fs = require('fs');

const required = new Set();
for (const file of [
	'htdocs/luci-static/resources/view/oxidns/overview.js',
	'htdocs/luci-static/resources/view/oxidns/core.js',
	'htdocs/luci-static/resources/view/oxidns/config.js',
	'htdocs/luci-static/resources/view/oxidns/logs.js',
	'htdocs/luci-static/resources/view/oxidns/settings.js',
	'htdocs/luci-static/resources/view/oxidns/rules.js',
	'htdocs/luci-static/resources/view/oxidns/cache.js',
]) {
	const source = fs.readFileSync(file, 'utf8');
	const re = /_\(\s*(['"])((?:\\.|[^\\])*?)\1\s*\)/g;
	let match;
	while ((match = re.exec(source)))
		required.add(Function(`return ${match[1]}${match[2]}${match[1]}`)());
}

const menu = JSON.parse(fs.readFileSync('root/usr/share/luci/menu.d/luci-app-oxidns.json', 'utf8'));
for (const entry of Object.values(menu)) {
	if (entry.title)
		required.add(entry.title);
}

function poIds(file) {
	const ids = new Set();
	const content = fs.readFileSync(file, 'utf8');
	const re = /^msgid "((?:\\.|[^"\\])*)"$/mg;
	let match;
	while ((match = re.exec(content))) {
		const id = JSON.parse(`"${match[1]}"`);
		if (id)
			ids.add(id);
	}
	return ids;
}

const pot = poIds('po/templates/oxidns.pot');
const zh = poIds('po/zh_Hans/oxidns.po');
const failures = [];
for (const [label, ids] of [['POT', pot], ['zh_Hans PO', zh]]) {
	for (const id of [...required].sort()) {
		if (!ids.has(id))
			failures.push(`${label} missing msgid: ${id}`);
	}
}
for (const id of [...pot].sort()) {
	if (!required.has(id))
		failures.push(`POT stale msgid: ${id}`);
}
if (failures.length) {
	console.error(failures.join('\n'));
	process.exit(1);
}
NODE
for script in scripts/po2lmo.mjs scripts/strip-tar-eof.mjs scripts/write-apk-data-tar.mjs scripts/write-ar-archive.mjs; do
	node --check "$script"
done
node scripts/po2lmo.mjs po/zh_Hans/oxidns.po "${TMPDIR:-/tmp}/oxidns.zh-cn.lmo"
test -s "${TMPDIR:-/tmp}/oxidns.zh-cn.lmo"
rm -f "${TMPDIR:-/tmp}/oxidns.zh-cn.lmo"
if command -v msgfmt >/dev/null 2>&1; then
	msgfmt --check po/zh_Hans/oxidns.po -o /dev/null
fi
sh -n root/usr/libexec/rpcd/luci.oxidns
sh -n root/etc/init.d/oxidns
# [API password] Both callers of `oxidns check/start` must inject OXIDNS_API_PASS:
# init.d covers the procd service, rpcd covers config validate/save and core
# install. A gap here makes any ${OXIDNS_API_PASS} config fail only in the UI.
grep -q "option api_pass" root/etc/config/oxidns
grep -q 'config_get API_PASS main api_pass' root/etc/init.d/oxidns
grep -q 'procd_set_param env OXIDNS_API_PASS=' root/etc/init.d/oxidns
grep -q 'uci_get api_pass' root/usr/libexec/rpcd/luci.oxidns
grep -q 'export OXIDNS_API_PASS' root/usr/libexec/rpcd/luci.oxidns
# [cache lookup] rpcd must register all five new methods in both list and dispatch.
for m in cache_suggest cache_detail upstreams probe_upstreams zone_info; do
	grep -q "\"$m\":" root/usr/libexec/rpcd/luci.oxidns
	grep -q "^			$m)" root/usr/libexec/rpcd/luci.oxidns
done
# [cache lookup] The two handlers that call the authenticated management API
# (api_http_get -> Basic Auth with OXIDNS_API_PASS) MUST call load_settings in
# their own body. rpcd does not inherit the procd service env; without this the
# API returns 401, the body is empty, and the page silently shows 0 entries.
# Check the function body, not the whole file, so a load_settings elsewhere
# cannot satisfy the assertion.
for fn in emit_cache_suggest emit_cache_detail; do
	if ! awk -v fn="$fn" '
		$0 == fn "() {" { in_fn = 1 }
		in_fn && /load_settings/ { found = 1 }
		in_fn && $0 == "}" { exit }
		END { exit(found ? 0 : 1) }
	' root/usr/libexec/rpcd/luci.oxidns; then
		echo "$fn() must call load_settings() before api_http_get (API auth)" >&2
		exit 1
	fi
done
# [cache lookup] The frontend must surface cache_ok=0 instead of silently
# rendering an empty cache when the management API call failed.
grep -q 'res.cache_ok === 0' htdocs/luci-static/resources/view/oxidns/cache.js
sh -n scripts/build-luci-package.sh
sh -n scripts/integration-check.sh
sh -n scripts/service-check.sh
sh -n scripts/release-check.sh
sh -n scripts/build-rules-baseline.sh
sh -n oxidns-rules-baseline/files/90-oxidns-rules

# jsonfilter rejects "@.[*]" (dot before the bracket): it exits non-zero and
# prints nothing, which is indistinguishable from an empty result and once
# surfaced as a bogus "no release" error. Only the "@[*].field" form is valid.
if grep -v '^[[:space:]]*#' root/usr/libexec/rpcd/luci.oxidns | grep -q '@\.\['; then
	echo "invalid jsonfilter expression in luci.oxidns: use @[*].field, not @.[*].field" >&2
	exit 1
fi

# Package/xxx/install gets $(1) = $(PKG_BUILD_DIR)/ipkg-<arch>/<pkg>, i.e. a
# directory *inside* the build directory. Copying "$(PKG_BUILD_DIR)/." into it
# makes cp fail with "cannot copy a directory ... into itself", so install from
# a subdirectory instead (this repo uses $(PKG_BUILD_DIR)/src).
self_copy="$(grep -rnF --include=Makefile '$(PKG_BUILD_DIR)/.' . 2>/dev/null \
	| grep -v ': *#' || true)"
if [ -n "$self_copy" ]; then
	echo 'Makefile copies $(PKG_BUILD_DIR)/. into the package dir: use a subdirectory such as $(PKG_BUILD_DIR)/src' >&2
	echo "$self_copy" >&2
	exit 1
fi
