import java.util.Properties
import java.io.FileInputStream
import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// Load the signing keystore only when key.properties + the keystore file
// actually exist (they are git-ignored). Otherwise fall back to debug signing
// so `flutter build apk --release` still works locally. A missing keystore is
// not a secret: the keystore and its passwords must never be committed.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
val keystorePath = keystoreProperties.getProperty("storeFile")?.let {
    rootProject.file(it).absolutePath
}
val hasReleaseKeystore = System.getenv("FYONA_LOCAL_ANDROID_SIGNING") != "1" &&
    keystorePropertiesFile.exists() &&
    keystoreProperties.getProperty("storeFile") != null &&
    keystoreProperties.getProperty("storePassword") != null &&
    keystoreProperties.getProperty("keyAlias") != null &&
    keystoreProperties.getProperty("keyPassword") != null &&
    keystorePath != null &&
    File(keystorePath).exists()
val directoryPilot = System.getenv("FYONA_DIRECTORY_PILOT_APK") == "1"
val directoryPilotEmulator =
    directoryPilot && System.getenv("FYONA_DIRECTORY_PILOT_EMULATOR") == "1"

android {
    namespace = "com.fyona.erp.fyona_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = if (directoryPilot) {
            "com.fyona.erp.fyona_flutter.directorypilot"
        } else {
            "com.fyona.erp.fyona_flutter"
        }
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["fyonaCleartext"] =
            if (directoryPilot && System.getenv("FYONA_DIRECTORY_PILOT_HTTPS") == "1") "false" else "true"
        resourceConfigurations.addAll(listOf("ar", "en"))
        // Release ships arm64 only (smaller APK, fits Telegram's 50MB limit).
        ndk {
            abiFilters.addAll(listOf(if (directoryPilotEmulator) "x86_64" else "arm64-v8a"))
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = File(keystorePath!!)
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            val quickTestBuild = System.getenv("FYONA_QUICK_TEST_APK") == "1"
            isMinifyEnabled = !quickTestBuild
            isShrinkResources = !quickTestBuild
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Sign with the release keystore when one is configured (see
            // key.properties). Falls back to the debug key otherwise, which is
            // fine for local builds but will NOT be accepted by Google Play.
            signingConfig = if (hasReleaseKeystore && !directoryPilot) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            // Compress native libraries in the APK; Android extracts the same
            // bytes on install. Do not filter or exclude any packaged ABI.
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Required by Flutter engine when minification is enabled (SplitCompat);
    // feature-delivery is the modern replacement for the discontinued play:core
    implementation("com.google.android.play:feature-delivery:2.1.0")
    // Kept (harmless): previously required by the removed AlarmActivity.
    implementation("androidx.appcompat:appcompat:1.7.0")
    // Required for BiometricPrompt (fingerprint authentication)
    implementation("androidx.biometric:biometric:1.1.0")
}

flutter {
    source = "../.."
}
