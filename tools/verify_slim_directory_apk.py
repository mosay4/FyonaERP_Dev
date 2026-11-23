"""Check that size reduction is packaging-only for the signed Phase 1 APK."""

import argparse
from hashlib import file_digest
import json
import os
from pathlib import Path
import re
import struct
import subprocess
from zipfile import ZipFile


PACKAGE = "com.fyona.erp.fyona_flutter.directorypilot"
QA = b"https://qa.fyonacompany.com:18443/api/v1"
USB_QA = b"http://127.0.0.1:18083/api/v1"
LIMIT = 35_000_000
SIGNER = "d5cf41c2a4d13c12b85571bfbf7ed4541ba93c302036394731940504de59cb7e"
DEX = re.compile(r"classes(?:[0-9]+)?\.dex")
API_URL = re.compile(rb"https?://[a-zA-Z0-9.:-]+/api/v1")
ABIS = {"arm64": "arm64-v8a", "x64": "x86_64"}
REQUIRED_LIBS = {"libapp.so", "libflutter.so", "libsqlcipher.so"}
# The notification plugin looks these up by string rather than resource ID;
# Firebase can also load its options dynamically from Android resources.
RUNTIME_RESOURCES = {
    "drawable/ic_launcher", "raw/sound_1", "raw/sound_2", "string/gcm_defaultSenderId",
    "string/google_api_key", "string/google_app_id", "string/project_id",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def android(executable, *args):
    sdk = Path(os.environ.get("ANDROID_HOME", "/opt/fyona/android-sdk"))
    tool = sdk / "build-tools" / "36.0.0" / executable
    result = subprocess.run([tool, *args], check=True, text=True, capture_output=True)
    return result.stdout


def digest(path):
    with path.open("rb") as stream:
        return file_digest(stream, "sha256").hexdigest()


def compare_archives(reference, candidate, abi):
    with ZipFile(reference) as old, ZipFile(candidate) as new:
        require(new.testzip() is None, "APK ZIP checksum failed")
        require(old.read("AndroidManifest.xml") == new.read("AndroidManifest.xml"),
                "Compiled Android manifest changed")
        old_files, new_files = map(set, (old.namelist(), new.namelist()))
        assets = lambda names: {name for name in names if name.startswith("assets/flutter_assets/")}
        require(assets(old_files) == assets(new_files), "Flutter asset inventory changed")

        for name in assets(new_files):
            require(old.read(name) == new.read(name), f"Flutter asset changed: {name}")

        prefix = f"lib/{abi}/"
        libs = lambda names: {name for name in names
                              if name.startswith(prefix) and name.endswith(".so")}
        required = {prefix + name for name in REQUIRED_LIBS}
        require(libs(old_files) == libs(new_files) and required <= libs(new_files),
                "Target native library inventory changed")
        for name in libs(new_files) - {prefix + "libapp.so"}:
            require(old.read(name) == new.read(name), f"Native library changed: {name}")

        binary = new.read(prefix + "libapp.so")
        # The compact build should recompile the same Dart program, not use
        # a different set of runtime flags or a server from another flavor.
        require(old.read(prefix + "libapp.so") == binary, "Dart AOT program changed")
        require(set(API_URL.findall(binary)) == {QA, USB_QA},
                "Unexpected compiled API origin outside the QA lab")
        require({name for name in new_files if name.endswith("/libapp.so")} ==
                {prefix + "libapp.so"}, "Unexpected Flutter ABI")

        total_dex = lambda archive: sum(entry.compress_size for entry in archive.infolist()
                                        if DEX.fullmatch(entry.filename))
        old_dex, new_dex = total_dex(old), total_dex(new)
        require(0 < new_dex < old_dex, "Android runtime bytecode was not shrunk")
    return old_dex, new_dex


def check_arm64_alignment(apk):
    android("zipalign", "-P", "16", "-c", "4", apk)
    with ZipFile(apk) as archive:
        for entry in archive.namelist():
            if not re.fullmatch(r"lib/arm64-v8a/[^/]+\.so", entry):
                continue
            binary = archive.read(entry)
            require(binary[:6] == b"\x7fELF\x02\x01", f"Not a 64-bit ELF: {entry}")
            require(struct.unpack_from("<H", binary, 18)[0] == 183, f"Not ARM64: {entry}")
            offset, = struct.unpack_from("<Q", binary, 32)
            size, count = struct.unpack_from("<HH", binary, 54)
            segments = [struct.unpack_from("<IIQQQQQQ", binary, offset + index * size)
                        for index in range(count)]
            require(all(seg[-1] >= 0x4000 for seg in segments if seg[0] == 1),
                    f"Native 16 KiB alignment failed: {entry}")


def runtime_resources(path):
    dump = android("aapt", "dump", "--values", "resources", path)
    found = {}
    pattern = r"^\s*resource 0x[0-9a-f]+ \S+:(\w+/\w+):[^\n]*\n([^\n]+)"
    for name, value in re.findall(pattern, dump, re.M):
        if name in RUNTIME_RESOURCES:
            found[name] = value.strip()
    return found


def check_notification_sounds(reference, candidate, old_resources, new_resources):
    with ZipFile(reference) as old, ZipFile(candidate) as new:
        for name in ("raw/sound_1", "raw/sound_2"):
            old_path = re.search(r'\b(res/[^"\s]+)', old_resources[name])
            new_path = re.search(r'\b(res/[^"\s]+)', new_resources[name])
            require(old_path is not None and new_path is not None,
                    f"Could not locate packaged notification sound: {name}")
            require(old.read(old_path[1]) == new.read(new_path[1]),
                    f"Notification sound changed: {name}")


def verify(reference, candidate, arch):
    bytes_ = candidate.stat().st_size
    require(0 < bytes_ <= LIMIT if arch == "arm64" else bytes_ > 0,
            "ARM64 APK exceeds the 35,000,000-byte delivery limit")

    def badges(apk):
        result = android("aapt", "dump", "badging", apk)
        return [line for line in result.splitlines() if line.startswith((
            "package:", "sdkVersion:", "targetSdkVersion:",
            "launchable-activity:", "application-label:",
        ))]

    old_badges, new_badges = badges(reference), badges(candidate)
    require(old_badges == new_badges, "Android version, SDK, label, or launcher changed")
    require(new_badges and new_badges[0].startswith(
        f"package: name='{PACKAGE}' versionCode='6193' versionName='1.4.133'"),
        "Unexpected package or version")
    cert = android("apksigner", "verify", "--print-certs", candidate)
    require(re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([a-f0-9]+)$", cert,
                       re.M) == [SIGNER], "Invalid or changed Android signing certificate")
    require(set(android("aapt", "dump", "permissions", reference).splitlines()) ==
            set(android("aapt", "dump", "permissions", candidate).splitlines()),
            "Android permissions changed")
    manifest = android("aapt", "dump", "xmltree", candidate, "AndroidManifest.xml")
    for name in ("allowBackup", "usesCleartextTraffic"):
        require(re.search(rf"android:{name}\([^)]+\)=\(type 0x12\)0x0$", manifest, re.M),
                f"Manifest safety flag not false: {name}")
    require(not re.search(r"android:debuggable\([^)]+\)=\(type 0x12\)0x[fF]+$",
                          manifest, re.M), "APK is debuggable")
    old_resources, new_resources = runtime_resources(reference), runtime_resources(candidate)
    require(new_resources.keys() == RUNTIME_RESOURCES, "A runtime-looked-up resource is missing")
    strings = {name for name in RUNTIME_RESOURCES if name.startswith("string/")}
    require(all(old_resources.get(name) == new_resources[name] for name in strings),
            "Firebase resource values changed")
    check_notification_sounds(reference, candidate, old_resources, new_resources)

    old_dex, new_dex = compare_archives(reference, candidate, ABIS[arch])
    if arch == "arm64":
        check_arm64_alignment(candidate)
    return {"apk": candidate.name, "sha256": digest(candidate), "bytes": bytes_, "abi": ABIS[arch],
            "reference_sha256": digest(reference),
            "original_dex_bytes": old_dex, "shrunk_dex_bytes": new_dex}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("arch", choices=ABIS)
    try:
        args = parser.parse_args()
        print(json.dumps(verify(args.reference, args.candidate, args.arch)))
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Compact APK failed verification: {exc}\n")
