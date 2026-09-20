allprojects {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri(File(rootProject.projectDir, "../packages/flutter_torrent_server/android/repo"))
        }
    }
}

/**
 * Centralized Project Settings
 * These versions are enforced across the app and all plugins.
 */
// A platform hash rather than an API level: Google publishes API 37 only as
// `android-37.0` (and 37.1, 37.2 ...), and AGP 8.13 turns a bare 37 into
// `android-37`, a package that no longer exists - locally or for CI to fetch.
extra["projectCompileSdk"] = "android-37.0"
extra["projectTargetSdk"] = 36
// Pinned rather than inherited from `flutter.ndkVersion` (28.2.13676358).
// GitHub removes NDK 28 from every runner image on 2026-10-01; r29 is what they
// keep alongside r27. r29 also emits 16 KB-aligned LOAD segments by default,
// which r27 does not - hence the explicit max-page-size linker flags this repo
// carries for the libraries it compiles itself.
//
// It is set on every subproject below, not just :app, because AGP otherwise
// gives each plugin its own default: before this pin, :app and :jni built
// against r28 while 21 other subprojects - including :vlc_player, :flutter_js
// and :flutter_torrent_server - built against r27.
extra["projectNdk"] = "29.0.14206865"
val projectJvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    // Standardize subproject build directories
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Ensure :app is evaluated first for dependency resolution
    project.evaluationDependsOn(":app")

    /**
     * Unified SDK & Toolchain Enforcement
     * This logic forces all subprojects (including plugins) to use consistent SDKs.
     */
    val configureAction: (Project) -> Unit = { project ->
        if (project.hasProperty("android")) {
            project.extensions.configure<com.android.build.gradle.BaseExtension>("android") {
                // Force API 37 to satisfy permission_handler_android and modern AndroidX dependencies
                val wanted = rootProject.extra["projectCompileSdk"] as String
                // Only where it differs: :app has already set this and been
                // configured by the time this runs for it, and AGP refuses a
                // second write of a platform hash once it has been read.
                if (compileSdkVersion != wanted) compileSdkVersion(wanted)
                ndkVersion = rootProject.extra["projectNdk"] as String
                defaultConfig {
                    @Suppress("DEPRECATION")
                    targetSdkVersion(rootProject.extra["projectTargetSdk"] as Int)
                }
            }
        }

        // Standardize Kotlin JVM Target to 17
        project.tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(projectJvmTarget)
            }
        }
    }

    /**
     * Resilient Configuration Hook
     * We use afterEvaluate to ensure we have the "last word" on versions, 
     * while checking state.executed to avoid "already evaluated" crashes.
     */
    if (state.executed) {
        configureAction(this)
    } else {
        afterEvaluate { configureAction(this) }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
