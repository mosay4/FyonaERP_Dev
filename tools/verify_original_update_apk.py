"""Fail closed if an APK is not an in-place update of the original FYONA build."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from zipfile import ZipFile


PACKAGE = "com.fyona.erp.fyona_flutter"
FIREBASE_RESOURCES = {
    "default_web_client_id", "firebase_database_url", "gcm_defaultSenderId",
    "google_api_key", "google_app_id", "google_crash_reporting_api_key",
    "google_storage_bucket", "project_id",
}
AUTH_ROUTES = (
    b"/auth/register", b"/auth/verify-registration", b"/auth/login",
    b"/auth/firebase",
)
API_URL = re.compile(rb"https?://[A-Za-z0-9.:-]+/api/v1")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_apk(path, tools):
    def android(executable, *args):
        result = subprocess.run([tools / executable, *args, path], text=True,
                                capture_output=True, check=True)
        return result.stdout

    badges = android("aapt", "dump", "badging")
    match = re.search(r"^package: name='([^']+)' versionCode='(\d+)' "
                      r"versionName='([^']+)'", badges, re.M)
    require(match is not None, "No Android package metadata.")
    require(match[1] == PACKAGE, "The APK is not the original FYONA package.")
    signature = android("apksigner", "verify", "--print-certs")
    signers = re.findall(r"^Signer #(\d+) certificate (SHA-1|SHA-256) digest: "
                         r"([a-fA-F0-9]+)$", signature, re.M)
    require({(i, algorithm) for i, algorithm, _ in signers} ==
            {("1", "SHA-1"), ("1", "SHA-256")}, "Expected a single verified signer.")
    fingerprints = {algorithm: value.lower() for _, algorithm, value in signers}

    values = android("aapt", "dump", "--values", "resources")
    google = {}
    for key, value in re.findall(
        r'^\s*resource 0x[0-9a-f]+ \S+:string/(\w+):[^\n]*\n'
        r'\s+\(string\d+\) "([^"\n]+)"', values, re.M
    ):
        if key in FIREBASE_RESOURCES:
            google[key] = value
    require({"default_web_client_id", "project_id", "google_app_id", "google_api_key"}
            <= google.keys(), "Required original Firebase/OAuth resources are missing.")
    with ZipFile(path) as apk:
        require(apk.testzip() is None, "Corrupt APK archive.")
        binaries = {name for name in apk.namelist() if name.startswith("lib/") and
                    name.endswith(("/libapp.so", "/libflutter.so"))}
        require(binaries == {"lib/arm64-v8a/libapp.so", "lib/arm64-v8a/libflutter.so"},
                "The APK does not contain the expected ARM64 Flutter binaries.")
        app = apk.read("lib/arm64-v8a/libapp.so")
        immutable = {
            name: hashlib.sha256(apk.read(name)).hexdigest()
            for name in apk.namelist() if not name.endswith("/") and (
                name.startswith(("assets/", "res/")) or
                name in {"AndroidManifest.xml", "resources.arsc"} or
                name.endswith(".dex")
            )
        }
    require(all(route in app for route in AUTH_ROUTES), "A legacy auth route is missing.")
    require(google["default_web_client_id"].encode() in app,
            "Compiled Google OAuth client does not match the bundled Firebase settings.")
    require(not any(x in app for x in (b"qa.fyonacompany.com:18443",
                                     b"127.0.0.1:18083/api/v1")),
            "The production-profile APK contains a directory pilot origin.")
    return {
        "release": (match[3], int(match[2])),
        "sdk": re.findall(r"^(?:sdkVersion|targetSdkVersion):'(\d+)'", badges, re.M),
        "permissions": set(android("aapt", "dump", "permissions").splitlines()),
        "Android resources, DEX, and app assets": immutable,
        "certificates": fingerprints,
        "firebase": google,
        "bases": {m.decode() for m in API_URL.findall(app)},
    }


def inspect(args):
    sdk = Path(os.environ.get("ANDROID_HOME", "/opt/fyona/android-sdk"))
    tools = sdk / "build-tools" / "36.0.0"
    before = load_apk(args.reference, tools)
    after = load_apk(args.candidate, tools)
    require(before["bases"] == after["bases"] == {args.api_base},
            "The compiled API origin is not the one in the original APK.")
    for key in ("release", "sdk", "permissions", "certificates", "firebase",
                "Android resources, DEX, and app assets"):
        require(before[key] == after[key], f"Original APK mismatch: {key}.")

    config = json.loads(args.google_services.read_text())
    client = next((c for c in config["client"] if c["client_info"]
                   ["android_client_info"]["package_name"] == PACKAGE), None)
    require(client is not None, "The source Firebase config has no original Android app.")
    require(config["project_info"]["project_id"] == after["firebase"]["project_id"] and
            client["client_info"]["mobilesdk_app_id"] == after["firebase"]["google_app_id"],
            "Source Firebase and APK project/app IDs differ.")
    records = client.get("oauth_client", [])
    require(any(x.get("client_type") == 3 and
                x.get("client_id") == after["firebase"]["default_web_client_id"]
                for x in records), "Source OAuth and APK web client IDs differ.")
    sha1 = after["certificates"]["SHA-1"]
    has_android_oauth = any(
        x.get("client_type") == 1 and
        x.get("android_info", {}).get("package_name") == PACKAGE and
        x.get("android_info", {}).get("certificate_hash", "").replace(":", "").lower() == sha1
        for x in records
    )
    print(f"{PACKAGE}, {after['release'][0]}+{after['release'][1]}")
    print("Verified same signers (SHA-1/SHA-256), SDK levels, permissions, Firebase resources, "
          "original HTTPS origin and auth paths; Android manifests/resources, DEX and assets "
          "match the reference.")
    print("Signed Android OAuth tuple in local Firebase JSON:",
          "present" if has_android_oauth else "not shown; verify the live Google project.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--google-services", type=Path, required=True)
    parser.add_argument("--api-base", required=True)
    try:
        inspect(parser.parse_args())
    except subprocess.CalledProcessError as exc:
        parser.exit(1, f"Android verification command failed ({exc.returncode}).\n")
    except (KeyError, OSError, ValueError) as exc:
        parser.exit(1, f"{exc}\n")
