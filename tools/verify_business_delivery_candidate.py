"""Compare internal ARM64 candidate with the four previously sent QA packages.

Static package compatibility only. This verifies neither running the candidate
on ARM64 nor preserving an installed account. It never sends an APK.
"""

import argparse
import json
from pathlib import Path
import re
from zipfile import ZipFile

import verify_slim_directory_apk as apk
from verify_directory_pilot_update import BADGES, STORAGE_NAMES, dex


REFERENCES = {
    "1230": ("Phase1-QA-35MB-ARM64", "736960b543f698315eaee3d7bf11174cb6ddfc14a8760c04bde288556e585b09"),
    "1238": ("QA-1230-Detail-Fix-ARM64", "415b3f2d0f72be86eba358e75ef6421e5da0fe88944b17cf6b3bb8206a0ac540"),
    "1242": ("Trial-Business-Local-ARM64", "de938ea6a9242a9e8f003d9a312fc6b102aa496df3611f9b2608c34fc6713256"),
    "1244": ("Offline-Commerce-Trial-ARM64", "8a2aeeb41850364dd06a518d60dc6aa99364c77a7d493f3d123f8a00a7a60fda"),
}
APP = "lib/arm64-v8a/libapp.so"
ASSET_PREFIX = "assets/flutter_assets/"
LOCALES = {f"{ASSET_PREFIX}assets/l10n/app_{lang}.arb" for lang in ("ar", "en")}
ICONS = f"{ASSET_PREFIX}fonts/MaterialIcons-Regular.otf"


def badges(path):
    return [line for line in apk.android("aapt", "dump", "badging", path).splitlines()
            if line.startswith(BADGES)]


def signer(path):
    cert = apk.android("apksigner", "verify", "--print-certs", path)
    return re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([a-f0-9]+)$", cert, re.M)


def permissions(path):
    return sorted(apk.android("aapt", "dump", "permissions", path).splitlines())


def assets(archive):
    return {name for name in archive.namelist() if name.startswith(ASSET_PREFIX)}


def libs(archive):
    return {name for name in archive.namelist() if name.startswith("lib/") and name.endswith(".so")}


def verify(candidate, references):
    size = candidate.stat().st_size
    apk.require(0 < size < apk.LIMIT, "ARM64 candidate exceeds the size budget")
    identity = badges(candidate)
    apk.require(identity[0].startswith(
        f"package: name='{apk.PACKAGE}' versionCode='6193' versionName='1.4.133'"),
        "Unexpected QA application ID or version")
    apk.require(signer(candidate) == [apk.SIGNER], "QA signer mismatch")
    apk.check_arm64_alignment(candidate)
    expected_permissions = permissions(candidate)
    resources = apk.runtime_resources(candidate)
    apk.require(resources.keys() == apk.RUNTIME_RESOURCES, "Missing platform notification resources")
    counts = {}
    with ZipFile(candidate) as built:
        apk.require(built.testzip() is None, "APK ZIP integrity failed")
        code = built.read(APP)
        apk.require(set(apk.API_URL.findall(code)) == {apk.QA, apk.USB_QA}
                    and b"api.jeetak-lounge.com" not in code, "Compiled API origin outside the QA lab")
        am = built.read("AndroidManifest.xml")
        apk.require(bool(dex(built)), "No Android runtime bytecode")
        apk.require({n for n in libs(built) if n.rsplit("/", 1)[1] in apk.REQUIRED_LIBS} ==
                    {f"lib/arm64-v8a/{n}" for n in apk.REQUIRED_LIBS}, "Flutter native ABI mismatch")
        apk.require(all(marker in code for marker in STORAGE_NAMES | {
            b"/business/employee-finance", b"/business/party-sharing",
        }), "Missing device storage or Business transport")
        # The link build composes an origin, relay prefix and versioned path
        # separately in Dart AOT. Require all negotiation and storage markers;
        # the live tests prove these fragments are used on the right requests.
        link_build = b"business_cash_link_preparations" in code
        cash_markers = ({b"/business/cash-relay", b"/v2/", b"/v3/", b"/link/prepared",
                         b"qa_writer_session", b"business_cash_link_preparations"}
                        if link_build else {b"/business/cash-relay/v"})
        apk.require(all(marker in code for marker in cash_markers), "Missing cash link or relay")
        for msg, (label, digest) in REFERENCES.items():
            older = references / f"FYONA-1.4.133-6193-{label}.apk"
            apk.require(apk.digest(older) == digest, f"Wrong reference for {msg}")
            apk.require(badges(older) == identity and permissions(older) == expected_permissions
                        and signer(older) == [apk.SIGNER], f"Install contract changed vs {msg}")
            previous_resources = apk.runtime_resources(older)
            apk.require(all(previous_resources[k] == resources[k] for k in resources if k.startswith("string/")),
                        f"Platform notification identity changed vs {msg}")
            apk.check_notification_sounds(older, candidate, previous_resources, resources)
            with ZipFile(older) as old:
                apk.require(old.read("AndroidManifest.xml") == am, f"Manifest changed vs {msg}")
                apk.require(libs(old) == libs(built) and all(
                    old.read(n) == built.read(n) for n in libs(built) - {APP}),
                    f"Native libraries changed vs {msg}")
                apk.require(assets(old) == assets(built) and all(
                    old.read(n) == built.read(n) for n in assets(built) - LOCALES - {ICONS}),
                    f"Unexpected Flutter asset change vs {msg}")
                # The icon font is generated by Flutter tree shaking. The
                # localized additions are allowed; old entries must survive.
                for locale in sorted(LOCALES):
                    before, after = (json.loads(z.read(locale)) for z in (old, built))
                    apk.require(all(after.get(k) == v for k, v in before.items()),
                                f"An existing translation changed vs {msg}")
                    if msg == "1244":
                        counts[Path(locale).stem] = len(after.keys() - before.keys())
    return {"apk": candidate.name, "bytes": size, "sha256": apk.digest(candidate),
            "cash_link_build": link_build,
            "static_compatibility_only": list(REFERENCES), "new_translations_vs_1244": counts}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("references", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.candidate, args.references)))


if __name__ == "__main__":
    main()
