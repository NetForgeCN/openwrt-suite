#!/bin/sh
# Offline static checks for luci-app-hevsocks5 (used by CI and developers).
# Requires only sh, node and python3; nothing is installed into the package.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

fail=0

check_sh() {
	for f do
		if sh -n "$f"; then
			echo "ok   sh -n $f"
		else
			echo "FAIL sh -n $f" >&2
			fail=1
		fi
	done
}

check_js() {
	command -v node >/dev/null 2>&1 || { echo "FAIL node not found" >&2; fail=1; return 0; }
	for f do
		if node --check "$f"; then
			echo "ok   node --check $f"
		else
			echo "FAIL node --check $f" >&2
			fail=1
		fi
	done
}

check_json() {
	command -v python3 >/dev/null 2>&1 || { echo "FAIL python3 not found" >&2; fail=1; return 0; }
	for f do
		if python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$f"; then
			echo "ok   python3 json $f"
		else
			echo "FAIL python3 json $f" >&2
			fail=1
		fi
	done
}

check_yaml() {
	command -v python3 >/dev/null 2>&1 || return 0
	python3 -c 'import yaml' >/dev/null 2>&1 || { echo "skip YAML parse (PyYAML unavailable)"; return 0; }
	for f do
		if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$f"; then
			echo "ok   python3 yaml $f"
		else
			echo "FAIL python3 yaml $f" >&2
			fail=1
		fi
	done
}

check_sh \
	scripts/check.sh \
	root/etc/init.d/hevsocks5-sync \
	root/etc/uci-defaults/luci-hevsocks5 \
	root/usr/bin/hevsocks5-ctl

check_js htdocs/luci-static/resources/view/hevsocks5.js

check_json \
	root/usr/share/luci/menu.d/luci-app-hevsocks5.json \
	root/usr/share/rpcd/acl.d/luci-app-hevsocks5.json \
	root/usr/share/ucitrack/luci-app-hevsocks5.json

check_yaml .github/workflows/ci.yml

[ "$fail" -eq 0 ] || { echo "static checks failed" >&2; exit 1; }
echo "all static checks passed"
