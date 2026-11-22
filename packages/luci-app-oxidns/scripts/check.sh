#!/bin/sh

set -eu

node -e "for (const f of ['htdocs/luci-static/resources/view/oxidns/overview.js','htdocs/luci-static/resources/view/oxidns/core.js','htdocs/luci-static/resources/view/oxidns/config.js','htdocs/luci-static/resources/view/oxidns/logs.js','htdocs/luci-static/resources/view/oxidns/settings.js','htdocs/luci-static/resources/view/oxidns/rules.js']) new Function(require('fs').readFileSync(f,'utf8'));"
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

# [force lists r12] force-cn.txt / force-abroad.txt are hand-maintained policy
# lists shipped by the baseline package. Every non-comment line must be a valid
# domain_set expression, both files must stay reasonably populated, and every
# distribution path must list them so they are seeded and survive the Rules
# page whole-directory swap.
for f in oxidns-rules-baseline/files/rules/force-cn.txt \
	oxidns-rules-baseline/files/rules/force-abroad.txt; do
	[ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
	bad="$(grep -v '^[[:space:]]*#' "$f" | grep -v '^[[:space:]]*$' \
		| grep -cv '^\(full\|domain\):[a-z0-9.-]*$' || true)"
	[ "$bad" = 0 ] || { echo "$f has $bad invalid rule lines" >&2; exit 1; }
done
cn_count="$(grep -c '^\(full\|domain\):' oxidns-rules-baseline/files/rules/force-cn.txt)"
ab_count="$(grep -c '^\(full\|domain\):' oxidns-rules-baseline/files/rules/force-abroad.txt)"
[ "$cn_count" -ge 80 ] || { echo "force-cn.txt lost entries ($cn_count)" >&2; exit 1; }
[ "$ab_count" -ge 50 ] || { echo "force-abroad.txt lost entries ($ab_count)" >&2; exit 1; }

# Every seeding path must know about both files.
for f in force-cn.txt force-abroad.txt; do
	grep -q "$f" oxidns-rules-baseline/Makefile \
		|| { echo "baseline Makefile does not seed $f" >&2; exit 1; }
	grep -q "$f" oxidns-rules-baseline/files/90-oxidns-rules \
		|| { echo "uci-defaults does not seed $f" >&2; exit 1; }
	grep -q "$f" root/etc/init.d/oxidns \
		|| { echo "init script does not seed $f" >&2; exit 1; }
done

# The baseline package must install the files/rules overlay.
grep -q '\$(CP) ./files/rules/' oxidns-rules-baseline/Makefile \
	|| { echo "baseline install missing files/rules overlay" >&2; exit 1; }

# The Rules page swaps the whole rules directory, so the update flow must
# carry the force lists over (current working copy first, baseline as seed).
grep -q 'force-cn.txt force-abroad.txt' root/usr/libexec/rpcd/luci.oxidns \
	|| { echo "rpcd rules update does not carry over the force lists" >&2; exit 1; }

# The force lists are NOT subscription files: the Rules page stage check must
# not require them in the release archive.
if awk '/^rules_files\(\) \{/{f=1} f{print} f&&/^}/{exit}' root/usr/libexec/rpcd/luci.oxidns \
	| grep -q 'force-'; then
	echo "rules_files() must not list the force lists" >&2
	exit 1
fi
