// Android implementation of maplibre_flutter.
//
// AGP 9+ compliant (CLAUDE.md §9):
//  - `namespace` declared here (manifest `package` attr is gone in AGP 8/9).
//  - No `org.jetbrains.kotlin.android` plugin — AGP 9 ships built-in Kotlin and
//    applying kotlin-android fails the build. The example app's
//    `android.builtInKotlin=false` escape hatch is removed (do not depend on it).
//  - Java 17 / Kotlin jvmTarget 17.
plugins {
    id("com.android.library")
}

group = "dev.maplibreflutter.maplibre_flutter_android"
version = "1.0"

android {
    namespace = "dev.maplibreflutter.maplibre_flutter_android"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 21 // MapLibre Android SDK floor.
        consumerProguardFiles("consumer-rules.pro")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.annotation:annotation:1.9.1") // @Keep for jnigen-bound classes.
    implementation("org.maplibre.gl:android-sdk:11.11.0")
}
