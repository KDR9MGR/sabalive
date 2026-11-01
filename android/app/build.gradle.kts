import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

// All signing secrets live outside the repo in one dedicated folder, never
// inside the project tree. Falls back to the old in-repo location so a
// clone without access to that folder still builds (debug-signed).
val keystoreProperties = Properties()
val externalKeystorePropertiesFile = File("/Users/abdulrazak/sabalive-secrets/android/key.properties")
val keystorePropertiesFile = if (externalKeystorePropertiesFile.exists()) {
    externalKeystorePropertiesFile
} else {
    rootProject.file("key.properties")
}
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.sabalive.in"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (used for local
        // notifications when a push arrives while the app is foregrounded)
        // even though we don't schedule anything — see its own README.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.sabalive.in"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // The Flutter plugin only brings the Java crash reporter; this one adds crashes inside native code (the video / audio
    // engine, the renderer, the animation decoders), which is where a phone that just "closes" usually dies. Same BOM
    // version the FlutterFire plugins use (firebase_core 3.15.2), so every Firebase library stays on one release.
    implementation(platform("com.google.firebase:firebase-bom:33.16.0"))
    implementation("com.google.firebase:firebase-crashlytics-ndk")
}
