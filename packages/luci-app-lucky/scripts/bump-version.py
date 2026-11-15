#!/usr/bin/env python3
"""Pin the latest stable Lucky core into lucky/Makefile.

Design contract (important - do not "simplify" this away):

* The *build* never asks the network which version is current. lucky/Makefile
  always carries an explicit PKG_VERSION, release directory and per-architecture
  sha256, so a firmware built from a given commit is reproducible and offline.
* This script is the only thing that looks for "latest". It runs in CI once a
  day, rewrites the pinned block and commits. Downstream feeds (openwrt-suite
  daily sync, OpenWRT / OpenWrt-ScriptBuild FEEDS clones) then pick up the new
  pin automatically. No first-boot download is ever involved.

Exit codes: 0 = done (with or without changes), 1 = detection/verification
failure (CI goes red, nothing is committed, the old pin stays valid).
"""

from __future__ import annotations

import concurrent.futures
import datetime
import hashlib
import io
import json
import os
import pathlib
import re
import sys
import tarfile
import urllib.error
import urllib.request

BASE = "https://release.66666.host"
ROOT = pathlib.Path(__file__).resolve().parent.parent
MAKEFILE = ROOT / "lucky" / "Makefile"
ASSETS = ROOT / "lucky" / "assets.json"

BEGIN = "# BEGIN AUTO-GENERATED (scripts/bump-version.py) -- DO NOT EDIT BY HAND"
END = "# END AUTO-GENERATED (scripts/bump-version.py)"

# Every Linux asset published for 3.8.1. Hashes for all of them are recorded in
# assets.json; the Makefile only references the architectures OpenWrt can build.
ALL_ARCHES = [
    "x86_64",
    "arm64",
    "armv5",
    "armv6",
    "armv7",
    "i386",
    "mips_hardfloat",
    "mips_softfloat",
    "mips64_hardfloat",
    "mips64_softfloat",
    "mipsle_hardfloat",
    "mipsle_softfloat",
    "riscv64",
]

# (OpenWrt ARCH, required hash key, LUCKY_ARCH) in Makefile branch order.
BRANCHES = [
    ("x86_64", "x86_64", "x86_64"),
    ("i386", "i386", "i386"),
    ("aarch64", "arm64", "arm64"),
    ("arm", "armv7", "armv7"),
    ("arm_legacy", "armv5", "armv5"),
    ("mips", "mips_softfloat", "mips_softfloat"),
    ("mipsel", "mipsle_softfloat", "mipsle_softfloat"),
    ("mips64", "mips64_softfloat", "mips64_softfloat"),
    ("riscv64", "riscv64", "riscv64"),
]
# Only these must exist for the Makefile to be complete. Extra assets (armv6,
# hardfloat variants ...) are recorded for auditing but may come and go across
# releases without blocking the bump.
REQUIRED_ARCHES = {key for _, key, _ in BRANCHES}

UA = {"User-Agent": "NetForgeCN-lucky-version-bump/1.0"}


def fetch(url: str, timeout: int = 180) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def text(url: str, timeout: int = 60) -> str:
    return fetch(url, timeout).decode("utf-8", "replace")


def vkey(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in v.split("."))


def find_latest() -> str:
    html = text(BASE + "/")
    # Only plain x.y.z directories are stable releases. Skip beta/dev/rc dirs.
    versions = set(re.findall(r'href="\./v(\d+\.\d+\.\d+)/"', html))
    if not versions:
        raise RuntimeError("no stable vX.Y.Z directory found at " + BASE)
    return max(versions, key=vkey)


def find_release_dir(ver: str) -> str:
    html = text(f"{BASE}/v{ver}/")
    dirs = set(re.findall(r'href="\./([^"/]+_lucky)/"', html))
    if not dirs:
        raise RuntimeError(f"no *_lucky subdirectory under /v{ver}/")
    preferred = f"{ver}_lucky"
    chosen = preferred if preferred in dirs else sorted(dirs)[-1]
    return f"v{ver}/{chosen}"


def asset_names(release_dir: str, ver: str) -> set[str]:
    html = text(f"{BASE}/{release_dir}/")
    return set(re.findall(r'href="\./(lucky_[^"]*_Linux_[^"]+\.tar\.gz)"', html))


def probe(ver: str, release_dir: str, arch: str) -> tuple[str, str]:
    name = f"lucky_{ver}_Linux_{arch}.tar.gz"
    url = f"{BASE}/{release_dir}/{name}"
    data = fetch(url)
    digest = hashlib.sha256(data).hexdigest()
    # Fail loudly if upstream changes the tarball layout: the Makefile's
    # Build/Prepare extracts a flat "lucky" ELF from the archive root.
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        member = next(
            (m for m in tar.getmembers() if m.name.lstrip("./") == "lucky" and m.isfile()),
            None,
        )
        if member is None:
            raise RuntimeError(f"{name}: no top-level 'lucky' binary")
        handle = tar.extractfile(member)
        if handle is None or handle.read(4) != b"\x7fELF":
            raise RuntimeError(f"{name}: 'lucky' is not an ELF binary")
        if not (member.mode & 0o111):
            raise RuntimeError(f"{name}: 'lucky' is not executable")
    return arch, digest


def render_block(ver: str, release_dir: str, hashes: dict[str, str], now: str) -> str:
    out = [
        BEGIN,
        f"# Source: {BASE}/  (latest stable v{ver}, checked {now})",
        f"PKG_VERSION:={ver}",
        f"LUCKY_RELEASE_DIR:={release_dir}",
    ]
    arm_legacy_pending = False
    for idx, (ow_arch, key, lucky_arch) in enumerate(BRANCHES):
        if ow_arch == "arm_legacy":
            # Emitted inside the arm/cortex branch as the else leg.
            continue
        kw = "ifeq" if idx == 0 else "else ifeq"
        out.append(f'{kw} ($(ARCH),{ow_arch})')
        if ow_arch == "arm":
            out.append("  ifneq ($(findstring cortex,$(CPU_TYPE)),)")
            out.append(f"    LUCKY_ARCH:={lucky_arch}")
            out.append(f"    PKG_HASH:={hashes[key]}")
            out.append("  else")
            out.append("    LUCKY_ARCH:=armv5")
            out.append(f"    PKG_HASH:={hashes['armv5']}")
            out.append("  endif")
            arm_legacy_pending = True
        else:
            out.append(f"  LUCKY_ARCH:={lucky_arch}")
            out.append(f"  PKG_HASH:={hashes[key]}")
    out += ["else", "  LUCKY_ARCH:=", "  PKG_HASH:=", "endif", END]
    assert arm_legacy_pending, "arm branch missing"
    return "\n".join(out)


def rewrite_makefile(block: str) -> None:
    src = MAKEFILE.read_text(encoding="utf-8")
    pattern = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END), re.S)
    if not pattern.search(src):
        raise RuntimeError("AUTO-GENERATED block not found in lucky/Makefile")
    MAKEFILE.write_text(pattern.sub(lambda _: block, src, count=1), encoding="utf-8")


def gh_output(key: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(f"{key}={value}\n")


def main() -> int:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        ver = find_latest()
        release_dir = find_release_dir(ver)
        available = asset_names(release_dir, ver)
        missing = {
            a for a in REQUIRED_ARCHES
            if f"lucky_{ver}_Linux_{a}.tar.gz" not in available
        }
        if missing:
            raise RuntimeError("upstream is missing required assets: " + ", ".join(sorted(missing)))
        arches = [
            a for a in ALL_ARCHES
            if f"lucky_{ver}_Linux_{a}.tar.gz" in available
        ]

        old = {}
        if ASSETS.exists():
            try:
                old = json.loads(ASSETS.read_text(encoding="utf-8"))
            except (ValueError, OSError):
                old = {}
        if old.get("version") == ver and old.get("release_dir") == release_dir:
            print(f"[bump] already pinned to latest stable {ver}; nothing to do")
            gh_output("changed", "false")
            gh_output("version", ver)
            return 0

        print(f"[bump] new release detected: {ver} ({release_dir}), {len(arches)} assets")
        hashes: dict[str, str] = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            futures = {pool.submit(probe, ver, release_dir, a): a for a in arches}
            for future in concurrent.futures.as_completed(futures):
                arch, digest = future.result()
                hashes[arch] = digest
                print(f"  {arch:20s} {digest}")

        block = render_block(ver, release_dir, hashes, now)
        rewrite_makefile(block)

        payload = {
            "version": ver,
            "release_dir": release_dir,
            "checked_at": now,
            "source": BASE + "/",
            "assets": {
                a: {
                    "file": f"lucky_{ver}_Linux_{a}.tar.gz",
                    "sha256": hashes[a],
                    "url": f"{BASE}/{release_dir}/lucky_{ver}_Linux_{a}.tar.gz",
                }
                for a in arches
            },
        }
        ASSETS.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

        print(f"[bump] pinned {ver} in lucky/Makefile and wrote lucky/assets.json")
        gh_output("changed", "true")
        gh_output("version", ver)
        return 0
    except (urllib.error.URLError, RuntimeError, OSError, ValueError, tarfile.TarError) as exc:
        print(f"[bump] FAILED, keeping the existing pin: {exc}", file=sys.stderr)
        gh_output("changed", "false")
        return 1


if __name__ == "__main__":
    sys.exit(main())
