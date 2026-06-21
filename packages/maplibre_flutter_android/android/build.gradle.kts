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
        // 26, not the legacy 21 floor: mbgl-core's .so (built by the
        // maplibre_flutter_core hook) references pthread_getname_np, added to
        // bionic in API 26.
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
            }
        }
    }

    // Native present bridge (JNI → ANativeWindow): copies mbgl-core's frames into
    // the SurfaceProducer's Surface. Built separately from the maplibre_flutter_core
    // build hook (which produces libmaplibre_flutter_core.so).
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.annotation:annotation:1.9.1") // @Keep for JNI-called classes.
    // OkHttp backs mbgl-core's HTTP file source (system TLS + trust store),
    // bridged to the engine over JNI.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}
