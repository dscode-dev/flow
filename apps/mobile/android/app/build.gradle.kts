import java.util.Base64
import java.net.URI

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Native progressive playback must reach the private development API as Dio does.
// Production keeps cleartext disabled. Never log decoded dart-defines.
val flowDefines = (project.findProperty("dart-defines") as? String).orEmpty()
    .split(",").filter { it.isNotEmpty() }.mapNotNull {
        runCatching { String(Base64.getDecoder().decode(it)).split("=", limit = 2) }
            .getOrNull()?.takeIf { parts -> parts.size == 2 }
    }.associate { it[0] to it[1] }
val flowApiUri = runCatching { URI(flowDefines["API_BASE_URL"].orEmpty()) }.getOrNull()
val flowLocalHost = flowApiUri?.host.orEmpty().matches(
    Regex("^(localhost|127\\..*|10\\..*|192\\.168\\..*|172\\.(1[6-9]|2[0-9]|3[01])\\..*)$")
)

android {
    namespace = "com.example.flow_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        manifestPlaceholders["flowCleartextTraffic"] = (
            flowDefines["FLOW_ENV"] != "production" && flowApiUri?.scheme == "http" && flowLocalHost
        ).toString()
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.flow_mobile"
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Release signing será configurado com os valores aprovados do produto.
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
