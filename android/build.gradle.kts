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
