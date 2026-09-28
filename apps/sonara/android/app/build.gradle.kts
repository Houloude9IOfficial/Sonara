import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.sonara.sonara"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.sonara.sonara"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // Android 16's opt-in local-network gate is inconsistent on some OEM
        // builds even after NEARBY_WIFI_DEVICES is granted. Target 35 retains
        // Android's documented INTERNET-based compatibility grant. Move to 37
        // with ACCESS_LOCAL_NETWORK once that API is available in the toolchain.
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        externalNativeBuild {
            cmake {
                arguments("-DANDROID_STL=c++_shared")
            }
        }
    }

    buildFeatures {
        prefab = true
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    sourceSets.getByName("main").jniLibs.srcDir(
        layout.buildDirectory.dir("rustJniLibs").get().asFile,
    )

    val releasePropertiesFile = rootProject.file("key.properties")
    val releaseProperties = Properties().apply {
        if (releasePropertiesFile.exists()) {
            releasePropertiesFile.inputStream().use(::load)
        }
    }
    signingConfigs {
        if (releasePropertiesFile.exists()) {
            create("release") {
                storeFile = rootProject.file(releaseProperties.getProperty("storeFile"))
                storePassword = releaseProperties.getProperty("storePassword")
                keyAlias = releaseProperties.getProperty("keyAlias")
                keyPassword = releaseProperties.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            if (releasePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.oboe:oboe:1.10.0")
}

val cargoExecutable = System.getenv("USERPROFILE")?.let { "$it\\.cargo\\bin\\cargo.exe" } ?: "cargo"
val rustJniOutput = layout.buildDirectory.dir("rustJniLibs")
val buildRustAndroid by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.resolve("../../.."))
    commandLine(
        cargoExecutable,
        "ndk",
        "-t", "arm64-v8a",
        "-t", "x86_64",
        "-o", rustJniOutput.get().asFile.absolutePath,
        "build", "-p", "sonara-android", "--release"
    )
    inputs.files(
        fileTree(rootProject.projectDir.resolve("../../../crates/android-receiver/src")),
        fileTree(rootProject.projectDir.resolve("../../../crates/engine/src"))
    )
    outputs.dir(rustJniOutput)
}

tasks.configureEach {
    if (name.startsWith("merge") &&
        (name.endsWith("NativeLibs") || name.endsWith("JniLibFolders"))
    ) {
        dependsOn(buildRustAndroid)
    }
}
