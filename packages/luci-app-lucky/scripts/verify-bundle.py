#!/usr/bin/env python3
"""Enforce the "core is in the firmware, never fetched at first boot" contract.

Run locally or in CI:  python3 scripts/verify-bundle.py
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE_MK = ROOT / "lucky" / "Makefile"
LUCI_MK = ROOT / "Makefile"
ASSETS = ROOT / "lucky" / "assets.json"
RUNTIME_DIRS = [
    ROOT / "lucky" / "files",
    ROOT / "root",
    ROOT / "htdocs",
]
DOWNLOAD_RE = re.compile(
    r"\b(wget|curl|uclient-fetch|aria2c|axel)\b|github\.com/.+/releases/download|release\.66666\.host",
    re.I,
)
errors: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        errors.append(msg)


core = CORE_MK.read_text(encoding="utf-8")
luci = LUCI_MK.read_text(encoding="utf-8")

# 1. The pin is explicit and reproducible.
check(re.search(r"^PKG_VERSION:=\d+\.\d+\.\d+$", core, re.M) is not None,
      "lucky/Makefile: PKG_VERSION is not an explicit x.y.z pin")
check("PKG_HASH:=skip" not in core,
      "lucky/Makefile: PKG_HASH:=skip is forbidden (no integrity check)")
check("PKG_SOURCE_URL:=" in core and "release.66666.host" in core,
      "lucky/Makefile: PKG_SOURCE_URL missing")
check(re.search(r"\$\(INSTALL_BIN\) \$\(PKG_BUILD_DIR\)/lucky \$\(1\)/usr/bin/lucky", core) is not None,
      "lucky/Makefile: core binary is not installed into the image")
check("# BEGIN AUTO-GENERATED" in core and "# END AUTO-GENERATED" in core,
      "lucky/Makefile: auto-generated pin block is missing")
check("test -x $(PKG_BUILD_DIR)/lucky" in core,
      "lucky/Makefile: Build/Prepare does not verify the extracted binary")

# 2. LuCI cannot be selected without the core.
check(re.search(r"^LUCI_DEPENDS:=.*\+lucky\b", luci, re.M) is not None,
      "Makefile: LUCI_DEPENDS must include +lucky")
check("+rpcd-mod-file" in luci,
      "Makefile: LUCI_DEPENDS must include +rpcd-mod-file (fs.exec ACL)")

# 3. Nothing in the installed runtime tree downloads anything.
for base in RUNTIME_DIRS:
    for path in base.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix in (".po", ".png", ".jpg"):
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for lineno, line in enumerate(content.splitlines(), 1):
            if DOWNLOAD_RE.search(line):
                # A link shown to the user is fine, executing a fetch is not.
                if "window.open(" in line or "href=" in line:
                    continue
                errors.append(
                    f"{path.relative_to(ROOT)}:{lineno}: runtime download reference: {line.strip()}"
                )

# 4. init.d must fail closed when the binary is missing.
init = (ROOT / "lucky" / "files" / "lucky.init").read_text(encoding="utf-8")
check("logger -t lucky" in init and "return 1" in init,
      "lucky.init: missing binary must log and return 1")

# 5. Pinned hashes in the Makefile must match assets.json.
if ASSETS.exists():
    data = json.loads(ASSETS.read_text(encoding="utf-8"))
    check(data.get("version") in core,
          "assets.json version differs from the pinned PKG_VERSION")
    pinned_arches = set(re.findall(r"^[ \t]*LUCKY_ARCH:=(\S+)[ \t]*$", core, re.M))
    for arch, meta in data["assets"].items():
        digest = meta["sha256"]
        check(re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
              f"assets.json: invalid sha256 for {arch}")
        # Assets recorded for auditing only (e.g. armv6, hardfloat variants)
        # need not appear in the Makefile; every architecture the Makefile can
        # actually select MUST have its hash pinned there.
        if arch in pinned_arches and digest not in core:
            errors.append(f"assets.json: hash for {arch} is not pinned in the Makefile")
    check(pinned_arches <= set(data["assets"]),
          "Makefile references an architecture that assets.json does not cover")
else:
    errors.append("lucky/assets.json is missing (run scripts/bump-version.py)")

if errors:
    print("[verify] FAILED:", file=sys.stderr)
    for err in errors:
        print("  - " + err, file=sys.stderr)
    sys.exit(1)

print("[verify] OK: core is pinned, sha256-verified, installed into the image,")
print("         LuCI depends on +lucky, and no runtime download path exists.")
