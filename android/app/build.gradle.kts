import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is configured via android/key.properties (kept out of git).
// When absent (e.g. a fresh checkout with no signing set up), release falls
// back to debug signing so `flutter run --release` still works locally.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasSigning = keystorePropertiesFile.exists()
if (hasSigning) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.optimumsage.papernote"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications for scheduled reminders.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.optimumsage.papernote"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Keep R8 off. ML Kit's document scanner resolves its internal
            // components (e.g. SharedPrefManager) via Firebase-components
            // reflection driven by class-name strings; shrinking/obfuscation
            // strips or renames those, so `GmsDocumentScanning.getClient()`
            // throws NullPointerException at runtime in a minified release.
            // The APK-size win is negligible for a Flutter app (the engine and
            // native libs dominate), so disabling minification is the safe,
            // reflection-proof choice.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Backport of newer Java APIs used by flutter_local_notifications.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
