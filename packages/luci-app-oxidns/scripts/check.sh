#!/bin/sh

set -eu

node -e "for (const f of ['htdocs/luci-static/resources/view/oxidns/overview.js','htdocs/luci-static/resources/view/oxidns/core.js','htdocs/luci-static/resources/view/oxidns/config.js','htdocs/luci-static/resources/view/oxidns/logs.js','htdocs/luci-static/resources/view/oxidns/settings.js','htdocs/luci-static/resources/view/oxidns/rules.js','htdocs/luci-static/resources/view/oxidns/prewarm.js']) new Function(require('fs').readFileSync(f,'utf8'));"
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
	'htdocs/luci-static/resources/view/oxidns/prewarm.js',
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
# [prewarm] Keep the LuCI page, ACL endpoint, helper script and default list
# wired together. A missing piece makes the tab render but every action fail.
grep -q 'oxidns/prewarm' root/usr/share/luci/menu.d/luci-app-oxidns.json
grep -q '"prewarm_read"' root/usr/share/rpcd/acl.d/luci-app-oxidns.json
grep -q '"prewarm_save"' root/usr/share/rpcd/acl.d/luci-app-oxidns.json
grep -q '"prewarm_run"' root/usr/share/rpcd/acl.d/luci-app-oxidns.json
grep -q 'config prewarm' root/etc/config/oxidns
test -s root/usr/share/oxidns/prewarm.default.txt
test -x root/usr/libexec/oxidns-prewarm
sh -n root/usr/libexec/oxidns-prewarm
sh -n scripts/build-luci-package.sh
sh -n scripts/integration-check.sh
sh -n scripts/service-check.sh
sh -n scripts/release-check.sh
sh -n scripts/build-rules-baseline.sh
sh -n oxidns-rules-baseline/files/90-oxidns-rules

# [cache lookup removed] Keep the page and its RPC surface gone. A stale menu
# entry or ACL method would leave a dead view in LuCI, so fail if any of them
# ever comes back.
if grep -qi 'cache.js\|Cache Lookup\|cache_suggest\|cache_detail\|probe_upstreams\|zone_info\|trace_route' \
	htdocs root 2>/dev/null; then
	echo "Cache Lookup page artifacts are still present" >&2
	exit 1
fi

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

# [r13] v12 config and r13 package removed the hand-maintained force_cn /
# force_abroad split lists, their baseline files, and every seeding path.
# Guard against accidental reintroduction (scripts/ itself is excluded
# because this assertion necessarily mentions the names).
if grep -rqi 'force-cn\|force-abroad\|force_cn\|force_abroad' \
	oxidns-rules-baseline root htdocs 2>/dev/null; then
	echo "force split lists must stay removed (r13)" >&2
	exit 1
fi

# All rule files shipped by the baseline must come from the release archive
# overlay; there is no longer a local files/rules overlay to install.
if grep -q './files/rules' oxidns-rules-baseline/Makefile; then
	echo "baseline Makefile still installs a local files/rules overlay" >&2
	exit 1
fi
