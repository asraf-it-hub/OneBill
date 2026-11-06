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

    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(
                if (project.name == "sentry_flutter") {
                    org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8
                } else {
                    org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
                },
            )
            if (project.name == "sentry_flutter") {
                languageVersion.set(
                    org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_0,
                )
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
