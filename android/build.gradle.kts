allprojects {
    repositories {
        // A verified copy of the Kotlin compiler artifact is kept with the
        // project so first builds remain deterministic on restricted links.
        maven { url = uri(rootProject.file("../.tooling/m2")) }
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

    configurations.configureEach {
        // AndroidX Collection 1.4 moved the KTX classes into collection-jvm.
        // Align old transitive requests so both pre- and post-migration jars
        // are never packaged together.
        resolutionStrategy.force("androidx.collection:collection-ktx:1.4.2")
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
