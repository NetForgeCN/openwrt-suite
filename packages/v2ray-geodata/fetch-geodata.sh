#!/usr/bin/env bash
# v2ray-geodata 数据下载与校验
#
# 背景：此逻辑原先内联在 Makefile 的 Build/Compile 中。OpenWrt 的 package.mk
# 会对 define 里的命令做二次展开（$(call Build/Compile)），内联 shell 函数里的
# $$1 / $$url 会被吃掉第一个字符（实测变成空串或 "rl"），curl 收到无 scheme 的
# 裸串后按 http 处理，又被 --proto '=https' 拒绝，报
# "curl: (1) Protocol \"http\" disabled"。抽成独立脚本后 shell 变量不再经过
# make 展开，从根上避免这个转义陷阱。
#
# 本脚本工作目录 = PKG_BUILD_DIR，下载的 .dat 与 .sha256sum 落在当前目录。
set -eu

CURL_FLAGS=(--fail --silent --show-error --proto '=https' --proto-redir '=https'
  --location --max-redirs 5 --connect-timeout 15 --max-time 300
  --retry 3 --retry-delay 2 --max-filesize 67108864)

GEOIP_URL="${GEOIP_URL:-https://github.com/NetForgeCN/v2ray-rules-dat/releases/latest/download/geoip.dat}"
GEOSITE_URL="${GEOSITE_URL:-https://github.com/NetForgeCN/v2ray-rules-dat/releases/latest/download/geosite.dat}"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

fetch() {
  url="$1"; dest="$2"; tmp="${dest}.part"
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  curl "${CURL_FLAGS[@]}" "$url" -o "$tmp"
  size=$(wc -c < "$tmp" | tr -d '[:space:]')
  [ "$size" -ge 16 ] || { echo "empty download: $url" >&2; return 1; }
  [ "$size" -le 67108864 ] || { echo "oversized download: $url" >&2; return 1; }
  if head -c 512 "$tmp" | grep -Eqi '<(!doctype|html|head|body)|<error|access denied|too many requests'; then
    echo "download looks like an HTML/error page: $url" >&2
    return 1
  fi
  mv -f "$tmp" "$dest"
}

verify() {
  dest="$1"; sumfile="$2"; name="$3"
  expected=$(awk -v want="$name" '
    NF == 1 { print $1; n++; next }
    NF == 2 { if ($2 != want && $2 != "./" want) exit 1; print $1; n++; next }
    { exit 1 }
    END { if (n != 1) exit 1 }
  ' "$sumfile") || { echo "malformed checksum file for $name" >&2; return 1; }
  case "$expected" in
    ''|*[!0-9a-fA-F]*) echo "malformed checksum for $name" >&2; return 1 ;;
  esac
  [ "${#expected}" -eq 64 ] || { echo "malformed checksum for $name" >&2; return 1; }
  actual=$(sha256_of "$dest")
  [ "$actual" = "$expected" ] || { echo "SHA-256 mismatch for $name" >&2; return 1; }
  echo "verified $name ($actual)"
}

fetch "$GEOIP_URL" geoip.dat
fetch "$GEOIP_URL.sha256sum" geoip.dat.sha256sum
verify geoip.dat geoip.dat.sha256sum geoip.dat
fetch "$GEOSITE_URL" geosite.dat
fetch "$GEOSITE_URL.sha256sum" geosite.dat.sha256sum
verify geosite.dat geosite.dat.sha256sum geosite.dat
