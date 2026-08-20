import java.io.FileInputStream
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Absent for every local/debug checkout; only a release CI run supplies it,
// so release signing silently falls back to the debug key without it.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val dartDefines =
    (project.findProperty("dart-defines") as String?)
        .orEmpty()
        .split(",")
        .mapNotNull { encoded ->
            runCatching { String(Base64.getDecoder().decode(encoded)) }.getOrNull()
        }
        .mapNotNull { value ->
            val separator = value.indexOf("=")
            if (separator <= 0) null else value.substring(0, separator) to value.substring(separator + 1)
        }
        .toMap()

android {
    namespace = "me.osholt.ride_relay"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.tailendcharlie"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (
            dartDefines["RIDE_RELAY_PUSH_ENABLED"] == "true" &&
            !dartDefines["RIDE_RELAY_FIREBASE_API_KEY"].isNullOrEmpty() &&
            !dartDefines["RIDE_RELAY_FIREBASE_PROJECT_ID"].isNullOrEmpty() &&
            !dartDefines["RIDE_RELAY_FIREBASE_MESSAGING_SENDER_ID"].isNullOrEmpty() &&
            !dartDefines["RIDE_RELAY_FIREBASE_ANDROID_APP_ID"].isNullOrEmpty()
        ) {
            resValue(
                "string",
                "google_api_key",
                dartDefines.getValue("RIDE_RELAY_FIREBASE_API_KEY"),
            )
            resValue(
                "string",
                "project_id",
                dartDefines.getValue("RIDE_RELAY_FIREBASE_PROJECT_ID"),
            )
            resValue(
                "string",
                "gcm_defaultSenderId",
                dartDefines.getValue("RIDE_RELAY_FIREBASE_MESSAGING_SENDER_ID"),
            )
            resValue(
                "string",
                "google_app_id",
                dartDefines.getValue("RIDE_RELAY_FIREBASE_ANDROID_APP_ID"),
            )
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
    implementation("org.bouncycastle:bcprov-jdk18on:1.84")

    // Guava arrives transitively through androidx.car.app, at 31.1-android, which
    // carries GHSA-7g45-4rm6-3mm3 and GHSA-5mg8-w23w-74h3 — both about
    // Files.createTempDir creating a world-readable directory. Both are fixed in
    // 32.0.0-android.
    //
    // A constraint rather than a dependency: this app does not use Guava and
    // should not start declaring it. A constraint raises the version wherever it
    // is already resolved and adds nothing where it is not.
    //
    // Pinned to the lowest version that fixes both rather than the newest
    // available. androidx.car.app is the Android Auto surface, its behaviour is
    // not covered by automated tests here, and the smallest bump is the one least
    // likely to change it. Dependabot will say if a later advisory applies.
    constraints {
        implementation("com.google.guava:guava:32.0.0-android") {
            because(
                "GHSA-7g45-4rm6-3mm3 and GHSA-5mg8-w23w-74h3: insecure " +
                    "temporary directory, fixed in 32.0.0-android (#421)",
            )
        }
    }

    implementation("androidx.car.app:app:1.7.0")
    implementation("androidx.car.app:app-projected:1.7.0")
    implementation("com.google.android.gms:play-services-nearby:19.3.0")
    implementation(platform("com.google.firebase:firebase-bom:34.16.0"))
    implementation("com.google.firebase:firebase-messaging")
    testImplementation("androidx.car.app:app-testing:1.7.0")
    testImplementation("junit:junit:4.13.2")
    // The car surface is `Canvas` code, and the head unit is hard to reach: the
    // Desktop Head Unit needs a real Android Auto host and the emulator image
    // ships only `AndroidAutoStubPrebuilt`. These let the surface be drawn at
    // head-unit sizes on real Android graphics and the pixels looked at (#602).
    // Real android.graphics on the JVM, so the car surface can be drawn and
    // looked at without a head unit. The Desktop Head Unit needs a real Android
    // Auto host and the emulator image ships only `AndroidAutoStubPrebuilt`, so
    // there is otherwise no way to see these pixels at all (#602).
    //
    // Robolectric rather than an instrumentation test: a Flutter plugin pins
    // androidx.test:runner to strictly 1.3.0, whose 2020-era manifest will not
    // merge against this app's minSdk.
    testImplementation("org.robolectric:robolectric:4.13")
}
