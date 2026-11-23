"""Verify a new Phase 1 trial APK against the installed 1230 build."""

import argparse
import json
from pathlib import Path
import re
import subprocess
from zipfile import ZipFile

import verify_slim_directory_apk as slim


OLD_HASHES = {
    "arm64": "736960b543f698315eaee3d7bf11174cb6ddfc14a8760c04bde288556e585b09",
    "x64": "2bf1e77c2bed739102735e55c6622f4478b4a437cc3080b8bd04b74609694815",
}

# These belong to reachable client paths/migrations, not fixture-only APIs
# which are intentionally removed by Dart's release tree shaking.
MARKERS = {
    b"qa_business_ledger",
    b"/customers/detail",
    b"/suppliers/detail",
    b"/banks/account/local",
    b"business_local_bank_legs",
    b"business_debt_payment_history",
    b"business_opening_debt_edits",
    b"business_imported_opening_payments",
    b"business_commerce_projection_receipts",
    b"business_commerce_stock_movements",
}
STORAGE_NAMES = {
    b"business_directory_v1",
    b"fyona_business_directory_v1",
    b"directory-key-",
    b"grant-v1-",
}
BADGES = ("package:", "sdkVersion:", "targetSdkVersion:", "application-label:",
          "launchable-activity:")
NEW_LOCALE_KEYS = {
    "bizCashWithdrawalReversed",
    "bizCashConflictReference",
    # Offline-commerce round: one new Falcon message; every old translation
    # must remain byte-identical to the 1230 reference.
    "falconLocalAccessRequired",
}
APP_LOCALES = {f"assets/flutter_assets/assets/l10n/app_{lang}.arb" for lang in ("ar", "en")}


def require(value, message):
    if not value:
        raise ValueError(message)


def dex(archive):
    return {entry: archive.read(entry) for entry in archive.namelist()
            if slim.DEX.fullmatch(entry)}


def compare_emulator(phone, emulator):
    with ZipFile(phone) as arm, ZipFile(emulator) as x64:
        require(dex(arm) == dex(x64) and
                arm.read("AndroidManifest.xml") == x64.read("AndroidManifest.xml"),
                "Emulator and phone Android runtime code differ")
        manifest = "assets/flutter_assets/NativeAssetsManifest.json"
        assets = lambda a: {e for e in a.namelist() if e.startswith("assets/flutter_assets/")}
        left, right = assets(arm), assets(x64)
        require(left == right and all(arm.read(e) == x64.read(e) for e in left - {manifest}),
                "Emulator and phone Flutter assets differ")
        for archive, target in ((arm, "android_arm64"), (x64, "android_x64")):
            native = json.loads(archive.read(manifest))
            require(native.get("native-assets") == {
                target: {"package:sqlite3/src/ffi/libsqlite3.g.dart": ["absolute", "libsqlcipher.so"]},
            }, "Flutter native SQLite does not select SQLCipher for the chosen target")


def verify(reference, candidate, architecture):
    require(slim.digest(reference) == OLD_HASHES[architecture],
            "Reference does not match the verified 1230 build")
    size = candidate.stat().st_size
    require(size > 0 and (architecture != "arm64" or size <= slim.LIMIT),
            "APK exceeds the trial size limit")

    def badges(path):
        return [line for line in slim.android("aapt", "dump", "badging", path).splitlines()
                if line.startswith(BADGES)]

    new_badges = badges(candidate)
    require(new_badges == badges(reference) and new_badges[0].startswith(
        f"package: name='{slim.PACKAGE}' versionCode='6193' versionName='1.4.133'"),
        "Package, version, SDK, launcher or label changed")
    cert = slim.android("apksigner", "verify", "--print-certs", candidate)
    require(re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([a-f0-9]+)$", cert,
                       re.M) == [slim.SIGNER], "Signer differs from 1230")
    permissions = lambda p: set(slim.android("aapt", "dump", "permissions", p).splitlines())
    require(permissions(candidate) == permissions(reference), "Permissions changed")
    manifest = slim.android("aapt", "dump", "xmltree", candidate, "AndroidManifest.xml")
    for flag in ("allowBackup", "usesCleartextTraffic"):
        require(re.search(rf"android:{flag}\([^)]+\)=\(type 0x12\)0x0$", manifest, re.M),
                f"Manifest safety flag not false: {flag}")
    require(not re.search(r"android:debuggable\([^)]+\)=\(type 0x12\)0x[fF]+$", manifest, re.M),
            "Trial must not be debuggable")
    before, after = map(slim.runtime_resources, (reference, candidate))
    require(after.keys() == slim.RUNTIME_RESOURCES and
            all(before.get(k) == after[k] for k in after if k.startswith("string/")),
            "Notification or Firebase runtime resources changed")
    slim.check_notification_sounds(reference, candidate, before, after)

    abi = slim.ABIS[architecture]
    with ZipFile(reference) as original, ZipFile(candidate) as trial:
        require(trial.testzip() is None, "ZIP CRC check failed")
        require(original.read("AndroidManifest.xml") == trial.read("AndroidManifest.xml"),
                "Manifest bytes differ from 1230")
        prefix = f"lib/{abi}/"
        app = prefix + "libapp.so"
        lib_names = lambda z: {x for x in z.namelist() if x.startswith("lib/") and x.endswith(".so")}
        libs = lib_names(trial)
        # The same Android plugins ship helper libraries in several ABIs.
        # Make sure only the chosen ABI contains a runnable Flutter engine,
        # Dart program and SQLCipher, while preserving the original helpers.
        require(libs == lib_names(original) and
                {x for x in libs if x.rsplit("/", 1)[1] in slim.REQUIRED_LIBS} ==
                {prefix + x for x in slim.REQUIRED_LIBS}, "Native library inventory changed")
        require(all(original.read(x) == trial.read(x) for x in libs - {app}),
                "A native library other than compiled Dart changed")
        assets = lambda z: {x for x in z.namelist() if x.startswith("assets/flutter_assets/")}
        old_assets, new_assets = assets(original), assets(trial)
        require(old_assets == new_assets and APP_LOCALES <= new_assets and
                all(original.read(x) == trial.read(x) for x in new_assets - APP_LOCALES),
                "Flutter assets changed")
        for locale in APP_LOCALES:
            old_messages = json.loads(original.read(locale))
            new_messages = json.loads(trial.read(locale))
            require(new_messages.keys() - old_messages.keys() == NEW_LOCALE_KEYS and
                    all(new_messages.get(key) == text for key, text in old_messages.items()) and
                    all(x in new_messages for x in NEW_LOCALE_KEYS),
                    "Existing translations changed or Business conflict text missing")
        aot, old_aot = trial.read(app), original.read(app)
        require(aot != old_aot, "Compiled Dart is still the old build")
        require(all(name in old_aot and name in aot for name in STORAGE_NAMES),
                "Existing encrypted directory or grant namespace changed")
        require(b"api.jeetak-lounge.com" not in aot, "Production host in trial program")
        require(all(marker in aot for marker in MARKERS), "Missing compiled application paths")
        require(set(slim.API_URL.findall(aot)) == {slim.QA, slim.USB_QA},
                "Unexpected compiled API origin")
        require(bool(dex(trial)), "Android runtime code missing")

    if architecture == "arm64":
        slim.check_arm64_alignment(candidate)
    return {"apk": candidate.name, "abi": abi, "bytes": size, "sha256": slim.digest(candidate),
            "reference_sha256": OLD_HASHES[architecture], "signer_sha256": slim.SIGNER}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("arch", choices=slim.ABIS)
    parser.add_argument("--compare-dex", type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.reference, args.candidate, args.arch)
        if args.compare_dex is not None:
            compare_emulator(
                args.candidate if args.arch == "arm64" else args.compare_dex,
                args.compare_dex if args.arch == "arm64" else args.candidate,
            )
            result["same_dex_as_internal_emulator_build"] = True
        print(json.dumps(result))
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Trial APK failed verification: {exc}\n")


if __name__ == "__main__":
    main()
