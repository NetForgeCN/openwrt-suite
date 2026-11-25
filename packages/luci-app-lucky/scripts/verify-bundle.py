#!/usr/bin/env python3
"""Enforce the "core is in the firmware, never fetched at first boot" contract.

Run locally or in CI:  python3 scripts/verify-bundle.py
"""

from __future__ import annotations

import ast
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE_MK = ROOT / "lucky" / "Makefile"
LUCI_MK = ROOT / "Makefile"
ASSETS = ROOT / "lucky" / "assets.json"
BUMP = ROOT / "scripts" / "bump-version.py"
ACL = ROOT / "root" / "usr" / "share" / "rpcd" / "acl.d" / "luci-app-lucky.json"
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


def read_text(path: pathlib.Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        errors.append(f"{path.relative_to(ROOT)}: cannot read as UTF-8: {exc}")
        return ""


core = read_text(CORE_MK)
luci = read_text(LUCI_MK)

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
check("--no-same-owner" in core and "--no-same-permissions" in core,
      "lucky/Makefile: tar extraction should not inherit attacker-controlled metadata")
check((ROOT / "lucky" / "LICENSE").is_file(),
      "lucky/LICENSE is missing (MIT packaging/core license)")

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
init = read_text(ROOT / "lucky" / "files" / "lucky.init")
check("logger -t lucky" in init and "return 1" in init,
      "lucky.init: missing binary must log and return 1")
check("valid_confdir" in init,
      "lucky.init: UCI configdir must be validated before use")

# 5. rpcd ACL must not grant unrestricted argv to the core binary.
acl = read_text(ACL)
if acl:
    try:
        acls = json.loads(acl)
        group = acls.get("luci-app-lucky", {})
        for perm in ("read", "write"):
            files = group.get(perm, {}).get("file", {})
            methods = files.get("/usr/bin/lucky", [])
            check("exec" not in methods,
                  f"ACL {perm}.file['/usr/bin/lucky'] must not grant unrestricted exec")
        check("exec" in group.get("read", {}).get("file", {}).get(
            "/usr/bin/lucky -info", []),
            "ACL read must allow '/usr/bin/lucky -info' exec")
        check(any(k.startswith("/usr/bin/lucky -setconf ")
                  for k in group.get("write", {}).get("file", {})),
              "ACL write must allow only the exact '/usr/bin/lucky -setconf ...' command")
    except (ValueError, AttributeError) as exc:
        errors.append(f"ACL JSON is invalid: {exc}")

# 6. Pinned hashes in the Makefile must match assets.json and the bump helper.
data: dict = {}
if ASSETS.exists():
    try:
        data = json.loads(ASSETS.read_text(encoding="utf-8"))
    except (ValueError, OSError, UnicodeDecodeError) as exc:
        errors.append(f"lucky/assets.json is invalid: {exc}")
else:
    errors.append("lucky/assets.json is missing (run scripts/bump-version.py)")

if data:
    check(data.get("version") in core,
          "assets.json version differs from the pinned PKG_VERSION")
    release_dir = data.get("release_dir")
    check(isinstance(release_dir, str) and
          re.search(r"^LUCKY_RELEASE_DIR:=" + re.escape(release_dir or "") + r"$", core, re.M) is not None,
          "assets.json release_dir differs from the pinned LUCKY_RELEASE_DIR")
    assets = data.get("assets", {})
    check(isinstance(assets, dict) and len(assets) > 0,
          "assets.json has no assets")
    pinned_arches = set(re.findall(r"^[ \t]*LUCKY_ARCH:=(\S+)[ \t]*$", core, re.M))
    runtime_arch = read_text(ROOT / "root" / "usr" / "bin" / "luckyarch")
    for arch in sorted(pinned_arches):
        check(f'"{arch}"' in runtime_arch,
              f"root/usr/bin/luckyarch: no mapping for Makefile LUCKY_ARCH {arch}")
    for arch, meta in assets.items():
        digest = meta.get("sha256", "") if isinstance(meta, dict) else ""
        check(re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
              f"assets.json: invalid sha256 for {arch}")
        # Assets recorded for auditing only (e.g. armv6, hardfloat variants)
        # need not appear in the Makefile; every architecture the Makefile can
        # actually select MUST have its hash pinned there.
        if arch in pinned_arches and digest not in core:
            errors.append(f"assets.json: hash for {arch} is not pinned in the Makefile")
    check(pinned_arches <= set(assets),
          "Makefile references an architecture that assets.json does not cover")

    # Keep the helper's architecture list in sync with the recorded assets.
    bump_src = read_text(BUMP)
    if bump_src:
        try:
            tree = ast.parse(bump_src)
            all_arches = None
            for node in tree.body:
                if isinstance(node, ast.Assign) and any(
                        isinstance(t, ast.Name) and t.id == "ALL_ARCHES" for t in node.targets):
                    all_arches = ast.literal_eval(node.value)
                    break
            check(all_arches is not None,
                  "scripts/bump-version.py: ALL_ARCHES not found")
            if all_arches is not None:
                check(set(all_arches) == set(assets),
                      "scripts/bump-version.py ALL_ARCHES is out of sync with assets.json")
        except (SyntaxError, ValueError) as exc:
            errors.append(f"scripts/bump-version.py cannot be parsed: {exc}")
        check('m.name in ("lucky", "./lucky")' in bump_src and '.lstrip(' not in bump_src,
              "scripts/bump-version.py must validate tarball member names strictly")

if errors:
    print("[verify] FAILED:", file=sys.stderr)
    for err in errors:
        print("  - " + err, file=sys.stderr)
    sys.exit(1)

print("[verify] OK: core is pinned, sha256-verified, installed into the image,")
print("         LuCI depends on +lucky, ACLs are least-privilege, and no")
print("         runtime download path exists.")
