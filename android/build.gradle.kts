allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// file_picker (8.x) baut hart gegen compileSdk 34; eine transitive Abhängigkeit
// verlangt aber 36. Deshalb für alle Plugin-Module compileSdk 36 erzwingen.
// Muss VOR dem evaluationDependsOn-Block stehen, sonst „already evaluated".
subprojects {
    val applySdk = {
        val android = extensions.findByName("android")
        if (android is com.android.build.gradle.BaseExtension) {
            android.compileSdkVersion(36)
        }
    }
    if (state.executed) applySdk() else afterEvaluate { applySdk() }
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
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
