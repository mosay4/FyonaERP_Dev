# INSTALL Guide — FYONA ERP

## Prerequisites
- Flutter SDK 3.44.4+
- Dart SDK 3.12.2+
- Android SDK 35+

## Setup

```bash
# 1. Clone or navigate to project
cd C:\Users\ms522\Downloads\ms\fyona_flutter

# 2. Install dependencies
flutter pub get

# 3. Run in debug mode
flutter run

# 4. Build APK
flutter build apk --debug
```

## Release Build

```bash
# 1. Generate keystore (one-time)
keytool -genkey -v -keystore android/app/upload-keystore.jks \
  -storepass fyona_erp -alias upload -keypass fyona_erp \
  -keyalg RSA -keysize 2048 -validity 10000

# 2. Build release APK
flutter build apk --release

# APK location: build/app/outputs/flutter-apk/app-release.apk
```

## Environment Configuration
Edit `lib/core/config/app_config.dart`:
- `apiBaseUrl`: Your backend API URL
- `defaultPageSize`: Pagination size (default: 20)
