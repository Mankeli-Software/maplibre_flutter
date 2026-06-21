// Opt-in MapLibre Android SDK implementation of maplibre_flutter.
//
// AGP 9+ compliant (CLAUDE.md §9): `namespace` declared here; no
// `org.jetbrains.kotlin.android` plugin (AGP 9 ships built-in Kotlin); Java 17 /
// Kotlin jvmTarget 17.
//
// The jnigen-bound shim classes (MapRegistry, MapLibreController) and the moved
// view-factory/platform-view keep their original `dev.maplibreflutter.maplibre_flutter_android`
// source package so the committed jnigen bindings stay valid without a regen;
// only this module's gradle `namespace` differs (so it can coexist with the core
// package in an A/B build).
plugins {
    id("com.android.library")
}

group = "dev.maplibreflutter.maplibre_flutter_android_sdk"
version = "1.0"

android {
    namespace = "dev.maplibreflutter.maplibre_flutter_android_sdk"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 21 is the MapLibre Android SDK's floor (no mbgl-core .so here, so the
        // core's API-26 bionic requirement does not apply).
        minSdk = 21
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
