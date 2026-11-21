#!/bin/sh
# Copyright (C) 2026 NetForgeCN - GPL-3.0-or-later
# Static validation for the repository. Runs on a workstation; no OpenWrt or
# OxiDNS binary required. Optional: Rust/cargo for unit tests, node for JS syntax.

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
FAIL=0
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

printf '== shell syntax ==\n'
for f in "$ROOT/root/etc/init.d/oxidnsplus" \
         "$ROOT/root/usr/libexec/rpcd/luci.oxidnsplus" \
         "$ROOT/scripts/check.sh" "$ROOT/scripts/build.sh"; do
    sh -n "$f" 2>/dev/null && ok "sh -n ${f#$ROOT/}" || bad "sh -n ${f#$ROOT/}"
done

printf '== JSON syntax ==\n'
for f in "$ROOT/root/usr/share/rpcd/acl.d/luci-app-oxidns-plus.json" \
         "$ROOT/root/usr/share/luci/menu.d/luci-app-oxidns-plus.json"; do
    python3 -m json.tool "$f" >/dev/null 2>&1 && ok "json ${f#$ROOT/}" || bad "json ${f#$ROOT/}"
done

printf '== JS syntax ==\n'
if command -v node >/dev/null 2>&1; then
    node --check "$ROOT/htdocs/luci-static/resources/view/oxidnsplus/plus.js" >/dev/null 2>&1 \
        && ok "node --check plus.js" || bad "node --check plus.js"
else
    printf '  SKIP node unavailable\n'
fi

printf '== Rust unit tests ==\n'
if command -v cargo >/dev/null 2>&1; then
    ( cd "$ROOT/src/prewarmer-rs" && cargo test >/dev/null 2>&1 ) \
        && ok "cargo test" || bad "cargo test"
else
    printf '  SKIP cargo unavailable\n'
fi

printf '== defaults copies ==\n'
cmp -s "$ROOT/root/etc/config/oxidnsplus" "$ROOT/root/usr/share/oxidnsplus/uci.defaults" \
    && ok "uci.defaults matches" || bad "uci.defaults differs"
cmp -s "$ROOT/root/etc/oxidnsplus/watch.list" "$ROOT/root/usr/share/oxidnsplus/watch.list.defaults" \
    && ok "watch.list.defaults matches" || bad "watch.list.defaults differs"

python3 - "$ROOT" <<'PY'
import json, os, re, sys
root = sys.argv[1]
fail = False
def bad(msg):
    global fail
    print('  FAIL ' + msg); fail = True
def read(rel):
    return open(os.path.join(root, rel), encoding='utf-8').read()

print('== cross-file consistency ==')
required = [
    'LICENSE','README.md','Makefile','.gitignore',
    'root/etc/config/oxidnsplus','root/etc/init.d/oxidnsplus',
    'root/etc/oxidnsplus/watch.list',
    'root/usr/libexec/rpcd/luci.oxidnsplus',
    'root/usr/share/rpcd/acl.d/luci-app-oxidns-plus.json',
    'root/usr/share/luci/menu.d/luci-app-oxidns-plus.json',
    'root/usr/share/oxidnsplus/uci.defaults',
    'root/usr/share/oxidnsplus/watch.list.defaults',
    'htdocs/luci-static/resources/view/oxidnsplus/plus.js',
    'po/zh_Hans/oxidnsplus.po',
    'scripts/build.sh','scripts/check.sh',
    'src/prewarmer-rs/Cargo.toml','src/prewarmer-rs/Cargo.lock',
    'src/prewarmer-rs/src/main.rs',
    'src/prewarmer-rs/src/scheduler.rs','src/prewarmer-rs/src/api.rs',
    'src/prewarmer-rs/src/json.rs','src/prewarmer-rs/src/dns.rs',
    'src/prewarmer-rs/src/model.rs',
]
for rel in required:
    if not os.path.isfile(os.path.join(root, rel)): bad('missing ' + rel)

# No prebuilt binary may be committed: the package is built from source by
# OpenWrt's Rust toolchain at package-build time.
if os.path.isdir(os.path.join(root, 'src', 'bin')):
    bad('src/bin/ must not exist (binary is built at package-build time)')
if not fail:
    print('  OK   required source files present, no prebuilt binary')

rpcd = read('root/usr/libexec/rpcd/luci.oxidnsplus')
acl = json.loads(read('root/usr/share/rpcd/acl.d/luci-app-oxidns-plus.json'))
menu = json.loads(read('root/usr/share/luci/menu.d/luci-app-oxidns-plus.json'))
js = read('htdocs/luci-static/resources/view/oxidnsplus/plus.js')
po = read('po/zh_Hans/oxidnsplus.po')
uci = read('root/etc/config/oxidnsplus')
mk = read('Makefile')

# Method set: ACL is authoritative; every method must have an emit_* function
# and a dispatch case in rpcd call, and be declared as a JS rpc.declare.
grp = acl.get('luci-app-oxidns-plus', {})
acl_m = set(grp.get('read',{}).get('ubus',{}).get('luci.oxidnsplus',[]) +
            grp.get('write',{}).get('ubus',{}).get('luci.oxidnsplus',[]))
emit_m = set(re.findall(r'^emit_([a-z_]+)\(\)', rpcd, re.M))
call_m = set(re.findall(r'^\s+([a-z_]+)\)\s+emit_', rpcd, re.M))
decl_m = set(re.findall(r"method: '([a-z_]+)'", js))
if acl_m and acl_m == emit_m == call_m == decl_m:
    print('  OK   ACL/emit/dispatch/JS methods aligned (%d): %s' % (len(acl_m), sorted(acl_m)))
else:
    bad('method mismatch acl=%s emit=%s call=%s jsdecl=%s' % (
        sorted(acl_m), sorted(emit_m), sorted(call_m), sorted(decl_m)))

# Field set: UCI is authoritative; rpcd FIELDS and JS FIELDS must match it.
m = re.search(r'^FIELDS="([^"]+)"', rpcd, re.M)
rpcd_fields = set(m.group(1).split()) if m else set()
uci_opts = set(re.findall(r'^\s*option\s+([a-z_]+)\s', uci, re.M))
m = re.search(r'var FIELDS = \[(.*?)\];', js, re.S)
js_fields = set(re.findall(r"'([a-z_]+)'", m.group(1))) if m else set()
if uci_opts and rpcd_fields == uci_opts == js_fields:
    print('  OK   UCI/rpcd/JS field sets aligned (%d)' % len(uci_opts))
else:
    bad('field mismatch uci=%s rpcd=%s js=%s' % (
        sorted(uci_opts), sorted(rpcd_fields), sorted(js_fields)))

# i18n completeness (unescape JS \' and PO \" before comparing)
used = set(s.replace("\\'", "'") for s in re.findall(r"_\('((?:[^'\\]|\\.)*)'\)", js))
known = set(s.replace('\\"','"') for s in re.findall(r'^msgid "(.*)"$', po, re.M))
missing = sorted(used - known)
if missing: bad('untranslated msgids: %s' % missing)
else: print('  OK   i18n: all %d msgids translated' % len(used))

# menu -> view file
vp = menu.get('admin/services/oxidnsplus/plus',{}).get('action',{}).get('path')
if vp and not os.path.isfile(os.path.join(root,'htdocs/luci-static/resources/view',vp+'.js')):
    bad('menu view has no JS: ' + vp)
if 'PKG_NAME:=luci-app-oxidns-plus' not in mk: bad('Makefile package name mismatch')

# Source-build contract: must use OpenWrt's Rust toolchain, no prebuilt binary,
# and the architecture gate must mirror oxidns-core (x86_64/aarch64/i386/arm).
for needle, label in [
    ('rust-package.mk', 'Makefile missing rust-package.mk include'),
    ('PKG_BUILD_DEPENDS:=rust/host', 'Makefile missing rust/host build dep'),
    ('MAKE_PATH:=src/prewarmer-rs', 'Makefile missing MAKE_PATH'),
    ('$(PKG_INSTALL_DIR)/bin/oxidns-prewarmer', 'install does not use cargo output'),
]:
    if needle not in mk: bad(label)
if 'LUCI_PKGARCH:=x86_64' in mk: bad('Makefile still pins x86_64')
if '@(x86_64||aarch64||i386||arm)' not in mk:
    bad('architecture gate does not mirror oxidns-core')
# menuconfig must show the package exactly ONCE. luci.mk already evaluates
# BuildPackage at its end; a hand-written eval would register it a second time.
if '$(eval $(call BuildPackage,luci-app-oxidns-plus))' in mk:
    bad('Makefile has a manual BuildPackage eval (duplicate -> two menuconfig entries)')
if '# call BuildPackage - OpenWrt buildroot signature' not in mk:
    bad('Makefile missing scan.mk discovery signature comment')
# rust-package.mk must come before luci.mk so luci.mk's BuildPackage eval
# captures the Cargo Build/Compile rule.
if mk.find('rust-package.mk') > mk.find('feeds/luci/luci.mk'):
    bad('rust-package.mk must be included before luci.mk')
if not fail:
    print('  OK   source-build Makefile (rust-package.mk, arch gate, cargo output, single registration)')

# HARD RULE: must not modify OxiDNS main config anywhere.
for rel in ['root/etc/init.d/oxidnsplus','root/usr/libexec/rpcd/luci.oxidnsplus',
            'htdocs/luci-static/resources/view/oxidnsplus/plus.js']:
    text = read(rel)
    for pat in [r'uci\s+set\s+oxidns\.', r'>\s*/etc/oxidns/config\.yaml']:
        if re.search(pat, text): bad('%s writes main config (pattern %s)' % (rel, pat))
if not fail: print('  OK   main config never written')

sys.exit(1 if fail else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))

printf '\n'
if [ "$FAIL" -eq 0 ]; then printf 'All checks passed.\n'; exit 0; fi
printf '%s check(s) failed.\n' "$FAIL"; exit 1
