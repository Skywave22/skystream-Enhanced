pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.13.2" apply false
    // 2.4.20, not 2.2.20: 2.2.20 is exactly the version Flutter errors on, its
    // supported matrix tops out at Gradle 8.14 / AGP 8.11.1 (this build is
    // Gradle 9.1 + AGP 8.13), and it carries CVE-2026-53914 - code execution
    // through unsafe deserialization of build-cache metadata.
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")
