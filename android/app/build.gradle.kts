import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Keystore-aware signing config. key.properties is gitignored; when present
// the release build signs with the upload key, otherwise it falls back to the
// debug key so `flutter run --release` / CI without the keystore still work.
val keystoreProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) load(FileInputStream(f))
}
val hasUploadKeystore =
    keystoreProps.containsKey("storeFile") &&
        file(keystoreProps.getProperty("storeFile")).isFile

android {
    packaging {
        jniLibs {
            // Custom libmpv (libplacebo/gpu-next, Phase 3) overrides media_kit's
            // stock .so from the AAR. Keep media_kit's libmediakitandroidhelper.so.
            // FFmpeg is statically linked into this libmpv — do NOT ship shared
            // libav*.so (nextlib Media3 also NEEDs those; pickFirst would break it).
            pickFirsts +=("**/libmpv.so")
            pickFirsts +=("**/libc++_shared.so")
        }
    }
    signingConfigs {
        if (hasUploadKeystore) {
            create("release") {
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
            }
        }
    }
    namespace = "com.dreamplayer.app"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // JVM unit tests for the pure subtitle-format logic (issue #44). These are
    // plain JUnit, no Robolectric: they exercise SubtitleFormats' format
    // sniffing and VobSub pairing against real VobSub bytes.
    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    defaultConfig {
        applicationId = "com.dreamplayer.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // NOTE: this is intentionally NOT flutter.versionCode.
        //
        // The "+N" in pubspec.yaml drives two different numbers with two
        // different rules:
        //   - iOS CFBundleVersion — per marketing version, so it can restart
        //     at any value and Apple treats it as opaque (we're on 0.5.0 (4)).
        //   - Android versionCode — GLOBAL and must always increase, or Android
        //     refuses the APK as a downgrade. The published v0.5.0 release
        //     shipped 37.
        //
        // Keeping them in one pubspec value would force the iOS build number
        // just to keep Android upgradeable. So Android's versionCode is pinned
        // here and must be bumped BY HAND, always above the last published
        // release.
        //
        // The SHIPPED number is not this value verbatim. `flutter build apk
        // --split-per-abi` applies Flutter's per-ABI scheme
        // (FlutterPlugin.kt: `abiVersionCode * 1000 + base`, ARCH_ARM64 -> 2),
        // so as of v0.5.1 the published codes are:
        //     universal 40   |   arm64-v8a 2040
        // Read the real one off an APK with:
        //     aapt2 dump badging <apk> | grep versionCode
        //
        // TRAP: because arm64 (2000+base) always beats universal (base), a user
        // who installed the arm64 split APK CANNOT later install a universal
        // build -- Android reads the lower code as a downgrade and refuses.
        // Pick one flavour per user and stay on it (issue #43).
        //
        // Last published: v0.5.1 -> universal 40 / arm64 2040.
        versionCode = 41
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Sign with the upload keystore when key.properties exists
            // (gitignored); fall back to the debug key otherwise so local
            // `flutter run --release` and CI keep working without it.
            signingConfig = if (hasUploadKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8 shrinks+obfuscates by default. BouncyCastle registers its
            // algorithms by string reflection (Provider.put -> class name), so
            // we keep it unminified in proguard-rules.pro.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.media3:media3-exoplayer:1.10.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.10.1")
    implementation("androidx.media3:media3-ui:1.10.1")
    implementation("androidx.media3:media3-common:1.10.1")
    // MediaSessionCompat + MediaStyle notification for background playback
    // (notification transport controls, lock screen, headset/Bluetooth keys).
    implementation("androidx.media:media:1.7.0")
    // OkHttp-backed HTTP DataSource so playback can use a permissive TLS client
    // for WebDAV servers with self-signed certificates. DefaultHttpDataSource
    // uses HttpURLConnection internally, which cannot accept custom certs.
    implementation("androidx.media3:media3-datasource-okhttp:1.10.1")
    // WebDAV PROPFIND: Android's HttpURLConnection only allows the standard
    // RFC 2616 verbs, so it cannot send PROPFIND. OkHttp permits arbitrary
    // methods and is used for browsing; playback uses it via the module above.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // SAF DocumentFile wrapper used to browse folders picked via
    // ACTION_OPEN_DOCUMENT_TREE (SD cards, USB drives, cloud providers).
    implementation("androidx.documentfile:documentfile:1.0.1")
    // EncryptedSharedPreferences (Android Keystore-backed) for WebDAV server
    // passwords: server metadata stays in plain SharedPreferences, secrets go
    // in an AES-256-GCM encrypted prefs file so a backup or file dump of the
    // app data cannot expose credentials.
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    // Prebuilt Media3 FFmpeg extension (GPLv3): software decode for
    // DTS/DTS-HD, TrueHD/MLP, E-AC3, AC3 where MediaCodec has no decoder.
    implementation("io.github.anilbeesetti:nextlib-media3ext:1.10.1-0.13.0")

    // SubtitleFormats format-sniffing tests (issue #44). JUnit only -- the
    // logic under test is pure and needs no Android runtime.
    testImplementation("junit:junit:4.13.2")
    // SMB2/3 client (jcifs-ng) — Nova and CX File Explorer's SMB library;
    // measured ~75 MB/s on the real NAS vs ~4-6 MB/s for smbj.
    // jcifs-ng 2.1.10's ASN.1 SPNEGO parsing requires BouncyCastle 1.78+
    // (BC <1.77 has a broken DLApplicationSpecific cast that crashes share
    // listing). Upgrade the transitive BC to 1.79 — the community-verified
    // combo (AgNO3/jcifs-ng#365). Keep it pinned so nothing downgrades.
    implementation("eu.agno3.jcifs:jcifs-ng:2.1.10") {
        exclude(group = "org.bouncycastle", module = "bcprov-jdk18on")
    }
    implementation("org.bouncycastle:bcprov-jdk18on:1.79") { version { strictly("1.79") } }
    // slf4j-nop: jcifs-ng requires an SLF4J binding at runtime; the no-op
    // binding avoids pulling in a logging framework.
    implementation("org.slf4j:slf4j-nop:2.0.13")
    // FTP/SFTP: Apache Commons Net (FTP) + JSch (SFTP/SSH). Mirrors the
    // WebDAV/SMB pattern: browsing + streaming DataSource (FtpDataSource).
    implementation("commons-net:commons-net:3.11.1")
    implementation("com.jcraft:jsch:0.1.55")
}
