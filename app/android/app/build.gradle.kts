import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The upload key Google Play knows the app by: from android/key.properties on a computer, or from VITRINA_UPLOAD_*
// variables in the store release workflow. Without it a release build is signed with the debug key: fine for the demo
// APK, refused by Google Play. Neither the key nor its passwords are ever committed.
val keyProperties = Properties().apply {
    rootProject.file("key.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

fun uploadKey(name: String, env: String): String? =
    keyProperties.getProperty(name)?.takeIf { it.isNotEmpty() } ?: System.getenv(env)?.takeIf { it.isNotEmpty() }

val uploadStoreFile = uploadKey("storeFile", "VITRINA_UPLOAD_STORE_FILE")

// What `--dart-define` gave this build: Flutter hands them to Gradle base64-encoded, comma-separated.
val dartDefines: Map<String, String> = (project.findProperty("dart-defines") as String?).orEmpty()
    .split(",").filter { it.isNotEmpty() }
    .map { String(Base64.getDecoder().decode(it)).split("=", limit = 2) }
    .associate { it[0] to it.getOrElse(1) { "" } }

android {
    namespace = "kz.vitrina.vitrina"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Google Play knows the app by this forever: it cannot change after the first upload.
        applicationId = "kz.vitrina.vitrina"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (uploadStoreFile != null) {
            create("upload") {
                storeFile = file(uploadStoreFile)
                storePassword = uploadKey("storePassword", "VITRINA_UPLOAD_STORE_PASSWORD")
                keyAlias = uploadKey("keyAlias", "VITRINA_UPLOAD_KEY_ALIAS")
                keyPassword = uploadKey("keyPassword", "VITRINA_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (uploadStoreFile != null) "upload" else "debug")
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

// A build signed for the store must talk to the real server: without `--dart-define=API_BASE=https://...` the app would
// look for a server on the developer's own computer and every phone would see only "no connection". The demo APK
// carries its data inside and needs no server.
gradle.taskGraph.whenReady {
    val release = allTasks.any { it.project == project && it.name in setOf("assembleRelease", "bundleRelease") }
    val base = dartDefines["API_BASE"].orEmpty()
    if (release && uploadStoreFile != null && dartDefines["DEMO"] != "true" && !base.startsWith("https://")) {
        throw GradleException("A store build needs --dart-define=API_BASE=https://YOUR-DOMAIN/api/v1 (got \"$base\")")
    }
}
