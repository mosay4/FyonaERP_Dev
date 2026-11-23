"""Verify a compression-only APK change against a same-SDK baseline.

Usage: python3 android/verify_release_packaging.py BEFORE AFTER BUILD_TOOLS
This is a packaging check, not a substitute for a real-device boot test.
"""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import zipfile


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def inspect(path):
    with zipfile.ZipFile(path) as apk:
        require(apk.testzip() is None, f"Corrupt ZIP: {path}")
        entries = {entry.filename: entry for entry in apk.infolist()}
        require(len(entries) == len(apk.infolist()), "Duplicate ZIP entries")
        composition = {}
        for entry in entries.values():
            name = entry.filename
            category = (
                "/".join(name.split("/")[:2]) if name.startswith("lib/")
                else "assets" if name.startswith("assets/")
                else "dex" if re.fullmatch(r"classes\d*\.dex", name)
                else "resources" if name.startswith("res/") or name == "resources.arsc"
                else "other"
            )
            totals = composition.setdefault(category, {"raw": 0, "compressed": 0})
            totals["raw"] += entry.file_size
            totals["compressed"] += entry.compress_size
        return {
            "bytes": Path(path).stat().st_size,
            "sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest(),
            "abis": sorted({name.split("/")[1] for name in entries if name.startswith("lib/")}),
            "composition": composition,
        }


def tool(build_tools, name, *arguments):
    return subprocess.check_output(
        [str(Path(build_tools) / name), *map(str, arguments)], text=True
    )


def verify(before, after, build_tools):
    old, new = inspect(before), inspect(after)
    require(new["bytes"] < old["bytes"], "APK did not get smaller")
    require(new["abis"] == old["abis"], "ABI set changed")
    with zipfile.ZipFile(before) as baseline, zipfile.ZipFile(after) as candidate:
        require(set(baseline.namelist()) == set(candidate.namelist()), "APK entry set changed")
        unchanged = 0
        for name in baseline.namelist():
            if name.startswith("lib/") and name.endswith(".so"):
                require(candidate.getinfo(name).compress_type == zipfile.ZIP_DEFLATED,
                        f"Uncompressed native library: {name}")
            # APK signatures and the extraction flag legitimately change.
            if name == "AndroidManifest.xml" or re.fullmatch(
                r"META-INF/[^/]+\.(SF|RSA|DSA|EC|MF)", name, re.IGNORECASE
            ):
                continue
            require(baseline.read(name) == candidate.read(name), f"Payload changed: {name}")
            unchanged += 1

    manifests = []
    certificates = []
    for path in (before, after):
        manifest = tool(build_tools, "aapt", "dump", "xmltree", path, "AndroidManifest.xml")
        manifests.append("\n".join(
            line for line in manifest.splitlines() if "android:extractNativeLibs(" not in line
        ))
        signing = tool(build_tools, "apksigner", "verify", "--verbose", "--print-certs", path)
        certificate = re.search(r"Signer #1 certificate SHA-256 digest: ([a-f0-9]+)", signing)
        require(certificate is not None, f"Signing certificate missing: {path}")
        certificates.append(certificate.group(1))
    require(manifests[0] == manifests[1], "Manifest changed beyond native extraction flag")
    require(certificates[0] == certificates[1], "APK signing certificate changed")
    require("android:extractNativeLibs(" in manifest and
            re.search(r"android:extractNativeLibs\([^\n]+0xffffffff", manifest),
            "Native library extraction is not enabled")
    return {
        "before": old,
        "after": new,
        "saved_bytes": old["bytes"] - new["bytes"],
        "saved_percent": round(100 * (old["bytes"] - new["bytes"]) / old["bytes"], 2),
        "byte_identical_payload_entries": unchanged,
        "signing_certificate_sha256": certificates[0],
        "boot_verified": False,
    }


if __name__ == "__main__":
    require(len(sys.argv) == 4, "Expected BEFORE AFTER BUILD_TOOLS")
    print(json.dumps(verify(*sys.argv[1:]), indent=2))
