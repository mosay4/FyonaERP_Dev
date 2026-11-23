# Release APK packaging validation — 2026-10-24

Status: packaging candidate built and verified; **real-device boot validation
is still pending**. Do not treat this as a fully device-tested release.

## Artifact

- Output: `build/app/outputs/flutter-apk/app-release.apk`
- Original: **51,988,537 bytes**
- Original SHA-256: `3a56f4108b8295d93e1c128a5c28c940b461548f29219235e2a28ceede805697`
- New: **31,773,473 bytes**
- New SHA-256: `518580ea384ca7a8118ff0590070a2b4c3696ed5fcb376c07aa6049c652523e0`
- Reduction: **20,215,064 bytes (38.88%)**
- Before and after builds both used Flutter **3.47.6**, framework `5fc346839b`,
  Dart **3.13.5**, and the existing hardened build script as `abdulrhman2`.
  The fresh before build reproduced the supplied APK's exact size and SHA-256.
- Baseline copies and detailed validation logs:
  `/tmp/fyona-apk.sNMnkw/` (temporary storage, not a permanent backup).

## Exact changes

1. `android/app/build.gradle.kts`: set `packaging.jniLibs.useLegacyPackaging`
   to `true`. Native libraries are DEFLATE-compressed in the APK and extracted
   unchanged by Android at installation.
2. `android/gradle.properties`: explicitly set `android.enableR8.fullMode=true`.
   Full mode was already AGP 8's default; minification and resource shrinking
   were already enabled and remain enabled.
3. `android/verify_release_packaging.py`: reproducible acceptance check for ZIP
   integrity, identical entry sets, byte-identical payloads, ABI preservation,
   native compression, manifest equivalence except the extraction flag, smaller
   size, and identical verified APK signing certificates.

No Dart/native application code, assets, fonts, media, dependencies, locale
filters, signing configuration, SDK levels, ABI filters, or build-script
behavior changed. Release icon tree-shaking was already enabled, confirmed in
both builds. Existing Arabic PDF and API URL build defines were retained.
The supported locale list is exactly Arabic and English; the existing `ar`/`en`
Android resource configuration was left untouched.

Obfuscation was deliberately skipped: application source uses `runtimeType`
in visible error text and string-based binding checks, and no device was
available to thoroughly validate obfuscation. No asset/license removal,
font subsetting, image conversion, quality reduction, or transitive-asset
exclusion was attempted without sufficient safety evidence.

## Composition and compatibility

Compressed ZIP entry bytes (excluding ZIP headers, alignment and signing block):

| Category | Before | After |
| --- | ---: | ---: |
| arm64-v8a native libraries | 33,320,752 | 14,202,575 |
| armeabi-v7a native libraries | 475,772 | 219,576 |
| x86_64 native libraries | 939,200 | 297,921 |
| DEX | 9,617,435 | 9,617,435 |
| Assets | 5,203,402 | 5,203,402 |
| Android resources | 1,900,775 | 1,900,775 |
| Other entries | 123,317 | 123,318 |

All **1,536 checked payload entries are byte-identical**, including every native
library, DEX file, Flutter asset, font, image, audio/video file and resource.
Only the manifest extraction flag, signing material and ZIP representation
differ. The native library bytes total 34,735,724 before and after; their
compressed total is now 14,720,072 bytes. Remaining savings are largely reduced
uncompressed-native ZIP alignment overhead.

The complete archive ABI set is unchanged: **arm64-v8a, armeabi-v7a, x86_64**.
Important pre-existing limitation: the baseline only contains Flutter's
`libapp.so` and `libflutter.so` for **arm64-v8a**; the other two ABI directories
contain plugin libraries. There is no x86 directory in the original APK.
This task did not remove any ABI/library, add unsupported architectures, or
claim to broaden the baseline's actual runnable-device compatibility. The
existing ARM64 Flutter build target and filter were intentionally preserved.

Minimum Android SDK remains **24**, target SDK **36**, package/version remains
`com.fyona.erp.fyona_flutter` / `1.4.127+6187`.
Android now extracts the native libraries at install time: APK/download size
decreases, but this is **not** an installed-storage reduction; installation
requires extraction work and storage. Executed native code is unchanged.
Identical installed footprint, installation time, startup time, or plugin
performance is **not guaranteed**: native extraction changes installation work
and storage layout, and device performance has not been measured.

## Checks executed

- Before and after: `bash /home/abdulrhman2/fyona-erp-build.sh`, exit **0** each.
  Logs: `build-20261024-195343.log` and `build-20261024-195840.log` under
  `/home/abdulrhman2/fyona-build-logs/`.
- `python3 android/verify_release_packaging.py /tmp/fyona-apk.sNMnkw/before.apk build/app/outputs/flutter-apk/app-release.apk /opt/sdk/android/build-tools/36.0.0`,
  exit **0**; detailed composition in
  `/tmp/fyona-apk.sNMnkw/packaging-verification.json`.
- `/opt/sdk/android/build-tools/36.0.0/apksigner verify --verbose --print-certs build/app/outputs/flutter-apk/app-release.apk`,
  exit **0**, APK Signature Scheme v2 verified, same signer as baseline.
  Signer certificate SHA-256:
  `2b8f0fb30a608053ff4d22eca0e2d5604080d1f02cf5b26ea3b8de4e554db288`.
- `/opt/sdk/android/build-tools/36.0.0/zipalign -c -P 16 -v 4 build/app/outputs/flutter-apk/app-release.apk`,
  exit **0**.
- `flutter analyze --no-pub`, exit **1**, **0 errors**, 265 warnings and 3,797
  informational diagnostics. All 4,062 diagnostics are identical before/after;
  none were introduced by this packaging-only change. First warning:
  unused field `_pdfLogoChip`, `lib/core/pdf_engine.dart:75:21`.
- `flutter test --no-pub --concurrency=1 --reporter=expanded test/language_transition_test.dart test/notification_channels_test.dart test/invoice_pdf_test.dart`,
  exit **0**, **10 tests passed** (Arabic/English transitions, notification
  sounds/channels, invoice PDF). Dart and assets were unchanged afterward.
- From `backend/`:
  `venv/bin/python -m pytest -q tests/unit/test_phone_validation.py tests/unit/test_uploads_config.py`,
  exit **0**, **22 tests passed**. These are isolated, no-database tests;
  no production backend, data, Docker, or services were modified.
- `sha256sum --check /tmp/fyona-baseline.QNzSBI` identified exactly the two
  edited existing Gradle files; the existing hardened script stayed unchanged.
  This is checksum-based change protection, **not a Git diff** (no Git worktree).

## Remaining acceptance work

`adb devices -l` returned no connected device, and no Android emulator is
installed in the SDK. Therefore installation/boot and real-device plugin smoke
tests were **not run**. Connect an ARM64 Android test device, install/update the
candidate, launch `com.fyona.erp.fyona_flutter/.MainActivity`, and verify startup,
Arabic/English rendering, PDF generation, notifications, camera/biometrics and
background entry points. Do not install on a production device without approval.
No Telegram message, deployment, or production restart was performed.

## Final acceptance follow-up — existing candidate, no rebuild

Only this document was edited in the follow-up. All project commands below
were executed with explicit working directory
`/home/abdulrhman2/fyona-erp`. No additional size experiment, build, clean,
obfuscation, ABI change, source cleanup, daemon reset, backend operation,
credential access, or Telegram delivery was performed. Coordinator runs outside
the project are not used as evidence.

### Artifact and packaging reconfirmed

- `sha256sum build/app/outputs/flutter-apk/app-release.apk /tmp/fyona-apk.sNMnkw/before.apk`
  and `stat -c '%n %s bytes' build/app/outputs/flutter-apk/app-release.apk /tmp/fyona-apk.sNMnkw/before.apk`
  reconfirmed the original **51,988,537 bytes**, SHA-256
  `3a56f4108b8295d93e1c128a5c28c940b461548f29219235e2a28ceede805697`,
  and candidate **31,773,473 bytes**, SHA-256
  `518580ea384ca7a8118ff0590070a2b4c3696ed5fcb376c07aa6049c652523e0`.
  The reduction remains **20,215,064 bytes (38.88%)**.
- `python3 android/verify_release_packaging.py /tmp/fyona-apk.sNMnkw/before.apk build/app/outputs/flutter-apk/app-release.apk /opt/sdk/android/build-tools/36.0.0` | EXIT=0 | PASS
  — **1,536 byte-identical payload entries**, including all executable payloads;
  identical entry names and manifest except `extractNativeLibs`; compressed
  native libraries; unchanged ABI set **arm64-v8a, armeabi-v7a, x86_64**;
  unchanged verified signer. Detailed result:
  `/tmp/fyona-apk.sNMnkw/final-acceptance-packaging.json`.
- `/opt/sdk/android/build-tools/36.0.0/apksigner verify --verbose --print-certs build/app/outputs/flutter-apk/app-release.apk` | EXIT=0 | PASS
  — APK Signature Scheme v2 verified; signer certificate SHA-256 remains
  `2b8f0fb30a608053ff4d22eca0e2d5604080d1f02cf5b26ea3b8de4e554db288`.
- `/opt/sdk/android/build-tools/36.0.0/zipalign -c -P 16 4 build/app/outputs/flutter-apk/app-release.apk` | EXIT=0 | PASS

### Broader regression results

- `flutter test --no-pub --concurrency=1 test/employee_*test.dart test/notification_router_test.dart test/route_guard_test.dart test/business_routes_test.dart test/profile_split_test.dart test/section_access_test.dart test/premium_switch_transition_test.dart test/notification_channels_test.dart test/language_transition_test.dart test/invoice_pdf_test.dart test/app_pin_crypto_test.dart test/app_pin_pad_test.dart` | EXIT=0 | PASS
  — **159 tests passed**, final runner result `01:51 +159: All tests passed!`.
  Actual log: `/tmp/fyona-apk.sNMnkw/final-broad-flutter-tests.log`.
- `flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings` | EXIT=0 | PASS
  — **0 errors, 265 warnings, 3,797 informational diagnostics; 4,062 total
  issues**, not zero issues. Nonfatal warning/info flags do not suppress
  analyzer errors. First existing warning: unused field `_pdfLogoChip`,
  `lib/core/pdf_engine.dart:75:21`. Actual log:
  `/tmp/fyona-apk.sNMnkw/final-acceptance-analyze.log`.

### Remaining device acceptance blocker

- `adb devices -l` | EXIT=0 | PASS — command succeeded, but its device list
  was **empty**; this is not a boot-test pass.
- Device installation/boot, plugin smoke tests, and install/startup/plugin
  performance measurements | EXIT=NOT_RUN | NOT RUN — no connected Android
  test device. No claim of identical installed storage or performance is made.

All executable packaging acceptance checks and the broader regression run
passed. No packaging-caused defect was observed in these checks. Remaining
acceptance is an authorized ARM64 test-device installation/update, launch of
`com.fyona.erp.fyona_flutter/.MainActivity`, plugin smoke testing, and measurement
of installation/storage/startup/plugin effects. The candidate remains
**not device-validated** until that work is completed.
