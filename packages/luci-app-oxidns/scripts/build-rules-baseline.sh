#!/bin/sh
#
# Build the OxiDNS rule baseline tarball used by the oxidns-rules-baseline
# package and by the LuCI "Rules" update page.
#
#   ./scripts/build-rules-baseline.sh [VERSION]     # default: today, YYYY.MM.DD
#
# Output: dist/oxidns-rules-baseline-<VERSION>.tar.gz
#         dist/oxidns-rules-baseline/            (unpacked tree, for inspection)
#
# The archive root is oxidns-rules-baseline/ and it contains:
#   6 upstream lists + cn-domains.txt (converted) + MANIFEST.txt
#   + VERSION + SHA256SUMS + LICENSES/
#
# Everything is validated before the tarball is written: OxiDNS aborts the
# whole process when a domain_set file contains a single unparsable line, so a
# bad baseline must never reach a release.
#
set -eu

VERSION="${1:-${VERSION:-$(date -u +%Y.%m.%d)}}"
OUT_DIR="${OUT_DIR:-dist}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE_NAME="oxidns-rules-baseline"
BASE_DIR="$OUT_DIR/$BASE_NAME"
ASSET="$OUT_DIR/$BASE_NAME-$VERSION.tar.gz"

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf 'required command not found: %s\n' "$1" >&2
		exit 1
	}
}

need_cmd awk
need_cmd curl
need_cmd grep
need_cmd sed
need_cmd sort
need_cmd tar
need_cmd wc

# GNU coreutils and BusyBox both ship sha256sum; macOS only has shasum.
if command -v sha256sum >/dev/null 2>&1; then
	sha256_of() { sha256sum "$1" | awk '{ print $1 }'; }
	sha256_list() { sha256sum "$@"; }
	sha256_stdin() { sha256sum | awk '{ print $1 }'; }
else
	sha256_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }
	sha256_list() { shasum -a 256 "$@"; }
	sha256_stdin() { shasum -a 256 | awk '{ print $1 }'; }
fi

fetch() {
	# fetch <dest> <url> [fallback-url]
	dest="$1"
	url="$2"
	fallback="${3:-}"
	if curl -fsSL --max-time 180 -o "$dest" "$url"; then
		return 0
	fi
	if [ -n "$fallback" ] && curl -fsSL --max-time 180 -o "$dest" "$fallback"; then
		return 0
	fi
	printf 'ERROR: failed to download %s\n' "$url" >&2
	return 1
}

# validate_domain_set <file> <min-lines>
# Mirrors what domain_set accepts: blank lines, '#' comments, prefixed rules
# (domain:/full:/keyword:/regexp:), or a bare domain containing a dot.
validate_domain_set() {
	file="$1"
	min_lines="$2"
	lines="$(wc -l < "$file" | awk '{ print $1 + 0 }')"
	if [ "$lines" -lt "$min_lines" ]; then
		printf 'ERROR: %s has only %s lines (minimum %s)\n' "$file" "$lines" "$min_lines" >&2
		return 1
	fi
	if ! awk '
		/^[[:space:]]*$/ { next }
		/^[[:space:]]*#/ { next }
		/^(domain|full|keyword|regexp):.+/ { next }
		/^[A-Za-z0-9_.-]+$/ && index($0, ".") > 0 { next }
		{
			printf "ERROR: %s: illegal line %d: %.80s\n", FILENAME, NR, $0 > "/dev/stderr";
			exit 1
		}
	' "$file"; then
		return 1
	fi
	return 0
}

# validate_plain_list <file> <min-lines>
validate_plain_list() {
	file="$1"
	min_lines="$2"
	lines="$(wc -l < "$file" | awk '{ print $1 + 0 }')"
	if [ "$lines" -lt "$min_lines" ]; then
		printf 'ERROR: %s has only %s lines (minimum %s)\n' "$file" "$lines" "$min_lines" >&2
		return 1
	fi
	if head -n 5 "$file" | grep -qi '<html'; then
		printf 'ERROR: %s looks like an HTML error page\n' "$file" >&2
		return 1
	fi
	return 0
}

# Only wipe this script's own outputs: --out dir may hold other artifacts
# (ipk/apk from scripts/build-luci-package.sh).
rm -rf "$BASE_DIR" "$ASSET" "$ASSET.sha256"
mkdir -p "$BASE_DIR/LICENSES"

printf '== downloading upstream lists ==\n'
fetch "$BASE_DIR/adguard-antiad.txt" "https://anti-ad.net/easylist.txt"
fetch "$BASE_DIR/adguard-hostlist.txt" \
	"https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"
fetch "$BASE_DIR/anti-ad-domains.txt" \
	"https://cdn.jsdelivr.net/gh/privacy-protection-tools/anti-AD@master/anti-ad-domains.txt" \
	"https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-domains.txt"
fetch "$BASE_DIR/adrules-domains.txt" \
	"https://cdn.jsdelivr.net/gh/Cats-Team/AdRules@main/mosdns_adrules.txt" \
	"https://raw.githubusercontent.com/Cats-Team/AdRules/main/mosdns_adrules.txt"
fetch "$BASE_DIR/neodevhost-domains.txt" \
	"https://cdn.jsdelivr.net/gh/neodevpro/neodevhost@master/domain" \
	"https://raw.githubusercontent.com/neodevpro/neodevhost/master/domain"
fetch "$BASE_DIR/accelerated-domains.china.conf" \
	"https://cdn.jsdelivr.net/gh/felixonmars/dnsmasq-china-list@master/accelerated-domains.china.conf" \
	"https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf"

printf '== converting accelerated-domains.china.conf ==\n'
sed -n 's|^server=/\([^/]*\)/.*|\1|p' "$BASE_DIR/accelerated-domains.china.conf" \
	| grep -F . \
	| LC_ALL=C sort -u > "$BASE_DIR/cn-domains.txt"

printf '== validating ==\n'
validate_plain_list "$BASE_DIR/adguard-antiad.txt" 50000
validate_plain_list "$BASE_DIR/adguard-hostlist.txt" 50000
validate_domain_set "$BASE_DIR/anti-ad-domains.txt" 50000
validate_domain_set "$BASE_DIR/adrules-domains.txt" 100000
validate_domain_set "$BASE_DIR/neodevhost-domains.txt" 100000
validate_domain_set "$BASE_DIR/cn-domains.txt" 50000
printf 'all rule files passed validation\n'

cp "$ROOT_DIR"/rules-baseline/LICENSES/*.LICENSE "$BASE_DIR/LICENSES/"

printf '%s\n' "$VERSION" > "$BASE_DIR/VERSION"

{
	printf '# OxiDNS rule baseline - bundled, read-only reference copy\n'
	printf '# Installed by oxidns-rules-baseline to /usr/share/oxidns/rules-baseline.\n'
	printf '# Seeded into /etc/oxidns/rules by /etc/init.d/oxidns when a file is missing.\n'
	printf '# Updated at runtime by the LuCI "Rules" page (release tags rules-v<version>).\n'
	printf '#\n'
	printf '# version: %s\n' "$VERSION"
	printf '# built:   %s\n' "${BUILD_STAMP:-$(printf '%s' "$VERSION" | tr '.' '-')}"
	printf '#\n'
	printf '%-34s %10s %8s  %s\n' FILE BYTES LINES LICENSE
	for entry in \
		"adguard-antiad.txt:GPL-3.0-or-later" \
		"adguard-hostlist.txt:GPL-3.0-or-later" \
		"anti-ad-domains.txt:MIT" \
		"adrules-domains.txt:0BSD" \
		"neodevhost-domains.txt:MIT" \
		"accelerated-domains.china.conf:WTFPL" \
		"cn-domains.txt:derived"
	do
		name="${entry%%:*}"
		license="${entry##*:}"
		printf '%-34s %10s %8s  %s\n' "$name" \
			"$(wc -c < "$BASE_DIR/$name" | awk '{ print $1 + 0 }')" \
			"$(wc -l < "$BASE_DIR/$name" | awk '{ print $1 + 0 }')" \
			"$license"
	done
	printf '#\n'
	printf '# sources:\n'
	printf '#  adguard-antiad.txt            https://anti-ad.net/easylist.txt\n'
	printf '#  adguard-hostlist.txt          https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt\n'
	printf '#  anti-ad-domains.txt           https://github.com/privacy-protection-tools/anti-AD\n'
	printf '#  adrules-domains.txt           https://github.com/Cats-Team/AdRules\n'
	printf '#  neodevhost-domains.txt        https://github.com/neodevpro/neodevhost\n'
	printf '#  accelerated-domains.china...  https://github.com/felixonmars/dnsmasq-china-list\n'
	printf '#  cn-domains.txt                converted from accelerated-domains.china.conf\n'
	printf '#\n'
	printf '# License texts: LICENSES/ (GPL-3.0 for the AdGuard filter, MIT for anti-AD and\n'
	printf '# neodevhost, 0BSD for AdRules, WTFPL-style for dnsmasq-china-list).\n'
} > "$BASE_DIR/MANIFEST.txt"

(
	cd "$BASE_DIR"
	sha256_list *.txt *.conf > SHA256SUMS
)

# Reproducible timestamps: two builds of the same rule data must produce the
# same archive bytes, otherwise PKG_HASH in the package Makefile would break
# on every re-run. The stamp is derived from VERSION (no date parsing, so BSD
# and GNU tools behave the same) and gzip -n drops its own timestamp.
#
# VERSION is YYYY.MM.DD or YYYY.MM.DD.HHMM; touch -t wants YYYYMMDDhhmm.SS, so
# the previous "strip the dots and append 0000.00" produced a 16-digit string
# that both BSD and GNU touch reject (silently, thanks to "|| true"), which is
# why archives were never actually reproducible.
stamp_of() {
	printf '%s\n' "$VERSION" | awk -F. '{
		hh = "00"; mm = "00";
		if (NF >= 4 && length($4) == 4) { hh = substr($4, 1, 2); mm = substr($4, 3, 2) }
		printf "%s%s%s%s%s.00\n", $1, $2, $3, hh, mm
	}'
}
iso_of() {
	printf '%s\n' "$VERSION" | awk -F. '{
		hh = "00"; mm = "00";
		if (NF >= 4 && length($4) == 4) { hh = substr($4, 1, 2); mm = substr($4, 3, 2) }
		printf "%s-%s-%s %s:%s:00 UTC\n", $1, $2, $3, hh, mm
	}'
}
STAMP="$(stamp_of)"
find "$BASE_DIR" -exec touch -t "$STAMP" {} + 2>/dev/null || true
# GNU date only: used for tar --mtime, which normalises the archive even if the
# filesystem mtimes above did not stick. Empty on BSD, where touch above is the
# reproducibility guarantee.
EPOCH="$(date -u -d "$(iso_of)" +%s 2>/dev/null || true)"

printf '== packaging %s ==\n' "$ASSET"
# gzip -n keeps the timestamp out of the gzip header; without it two runs
# produce different bytes even with identical content.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
	TAR_ARGS="--sort=name --owner=0 --group=0 --numeric-owner --format=ustar"
	if [ -n "$EPOCH" ]; then
		TAR_ARGS="$TAR_ARGS --mtime=@$EPOCH"
	fi
	# shellcheck disable=SC2086
	tar $TAR_ARGS -c -C "$OUT_DIR" "$BASE_NAME" | gzip -n -9 > "$ASSET"
else
	# bsdtar: normalise ownership and feed a sorted file list so the archive
	# layout does not depend on directory readdir order.
	(
		cd "$OUT_DIR"
		find "$BASE_NAME" -print | LC_ALL=C sort \
			| tar --no-recursion --format=ustar --uid 0 --gid 0 --uname root --gname root \
				-c -T - | gzip -n -9 > "$(basename "$ASSET")"
	)
fi

sha256_of "$ASSET" > "$ASSET.sha256"

# Content hash: independent of tar metadata, so CI can tell whether the rule
# data actually changed between two builds (the tarball bytes always differ
# because of timestamps).
{
	for name in adguard-antiad.txt adguard-hostlist.txt anti-ad-domains.txt \
		adrules-domains.txt neodevhost-domains.txt \
		accelerated-domains.china.conf cn-domains.txt; do
		printf '%s  %s\n' "$(sha256_of "$BASE_DIR/$name")" "$name"
	done
} | LC_ALL=C sort | sha256_stdin > "$OUT_DIR/CONTENT-SHA256"

printf '\nasset:  %s\nsha256: %s\n' "$ASSET" "$(cat "$ASSET.sha256")"
