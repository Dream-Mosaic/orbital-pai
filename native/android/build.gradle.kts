allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")

    // Some plugin AARs (flutter_voice_processor, pulled in transitively by
    // porcupine_flutter — planned wake-word work, unused so far) hardcode
    // compileSdkVersion 31 in their own android/build.gradle and haven't
    // been updated upstream (last release), so their own transitive androidx
    // deps now require compileSdk >= 34. Force every Android library
    // subproject to build against the app's compileSdk (36) so a stale
    // plugin config doesn't block the build; this only affects the
    // compile-time API surface, not minSdk/targetSdk.
    fun bumpCompileSdk() {
        extensions.findByName("android")?.let { ext ->
            if (ext is com.android.build.gradle.BaseExtension) {
                ext.compileSdkVersion(36)
            }
        }
    }
    if (project.state.executed) bumpCompileSdk() else afterEvaluate { bumpCompileSdk() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
