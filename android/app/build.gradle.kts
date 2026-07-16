import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val captureCoreNdkVersion = "28.2.13676358"
val captureCoreJniLibs = layout.buildDirectory.dir("generated/captureCore/jniLibs")
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use(::load)
    }
}

android {
    namespace = "com.lumiaiq.MotionCapture"
    compileSdk = 36
    // Match plugins (camera_android_camerax, jni, gal, path_provider_android, etc.)
    ndkVersion = captureCoreNdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.lumiaiq.MotionCapture"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // CI creates android/key.properties from GitHub Secrets. Keep the
            // debug fallback so local release-mode development still works.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    sourceSets.getByName("main").jniLibs.srcDir(captureCoreJniLibs)
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.github.pedroSG94.RootEncoder:library:2.7.2")
    implementation("com.github.pedroSG94.RootEncoder:extra-sources:2.7.2")
    implementation("androidx.camera:camera-camera2:1.6.0")
    implementation("androidx.camera:camera-core:1.6.0")
    implementation("androidx.camera:camera-lifecycle:1.6.0")
    implementation("androidx.camera:camera-video:1.6.0")
    implementation("androidx.camera:camera-view:1.6.0")
    implementation("com.google.mlkit:pose-detection:18.0.0-beta5")
    implementation("com.google.mlkit:pose-detection-accurate:18.0.0-beta5")
    implementation("com.google.guava:guava:33.3.1-android")
    testImplementation("junit:junit:4.13.2")
}

val localProperties = Properties().apply {
    val propertiesFile = rootProject.file("local.properties")
    if (propertiesFile.exists()) {
        propertiesFile.inputStream().use(::load)
    }
}
val androidSdkRoot = providers.environmentVariable("ANDROID_SDK_ROOT")
    .orElse(providers.environmentVariable("ANDROID_HOME"))
    .orElse(localProperties.getProperty("sdk.dir") ?: "")
val captureCoreNdkDir = androidSdkRoot.map { sdkRoot ->
    file("$sdkRoot/ndk/$captureCoreNdkVersion").absolutePath
}

val buildCaptureCore by tasks.registering(Exec::class) {
    group = "build"
    description = "Builds capture_core Rust JNI libraries for Android."
    val workspaceRoot = rootProject.projectDir.parentFile
    val crateRoot = workspaceRoot.resolve("native/capture_core")
    val buildScript = crateRoot.resolve("scripts/build-android.sh")
    workingDir(workspaceRoot)
    commandLine(
        "bash",
        buildScript.absolutePath,
        captureCoreNdkDir.get(),
        captureCoreJniLibs.get().asFile.absolutePath,
        "release",
    )
    inputs.file(crateRoot.resolve("Cargo.toml"))
    inputs.file(crateRoot.resolve("Cargo.lock"))
    inputs.dir(crateRoot.resolve("src"))
    inputs.file(buildScript)
    outputs.dir(captureCoreJniLibs)
}

tasks.configureEach {
    if (
        name == "mergeDebugJniLibFolders" ||
        name == "mergeReleaseJniLibFolders" ||
        name == "mergeProfileJniLibFolders" ||
        name == "mergeDebugNativeLibs" ||
        name == "mergeReleaseNativeLibs" ||
        name == "mergeProfileNativeLibs"
    ) {
        dependsOn(buildCaptureCore)
    }
}
