import java.util.Properties
import java.util.Base64
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release-Signatur aus android/key.properties (liegt NICHT im Repo). Fehlt die
// Datei (z. B. in der GitHub-CI), wird mit dem Debug-Key signiert, damit die
// Builds dort weiter durchlaufen.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Sicherheitsnetz gegen einen Play-Build mit eingeschaltetem In-App-Updater:
// Flavor und --dart-define muessen zusammenpassen. Flutter reicht die
// dart-defines als Property "dart-defines" (base64, kommagetrennt) an Gradle
// weiter; fehlt sie oder aendert Flutter das Format, entfaellt die Pruefung.
val dartDefines: List<String>? = (project.findProperty("dart-defines") as String?)?.let { raw ->
    try {
        raw.split(",")
            .filter { it.isNotBlank() }
            .map { String(Base64.getDecoder().decode(it.trim()), Charsets.UTF_8) }
    } catch (e: Exception) {
        null
    }
}
if (dartDefines != null) {
    val requestedTasks = gradle.startParameter.taskNames.joinToString(" ")
    val flavor = when {
        requestedTasks.contains("Play") -> "play"
        requestedTasks.contains("Github") -> "github"
        else -> null
    }
    val channel = dartDefines
        .firstOrNull { it.startsWith("APP_CHANNEL=") }
        ?.substringAfter("=") ?: "github"
    if (flavor != null && flavor != channel) {
        throw GradleException(
            "Flavor '$flavor' passt nicht zu APP_CHANNEL='$channel'. " +
            "Bitte mit  --flavor $flavor --dart-define=APP_CHANNEL=$flavor  bauen."
        )
    }
}

android {
    namespace = "com.example.fuellstand_app"
    compileSdk = 36   // aktuelle Plugins verlangen 36; wird an die Plugin-Module weitergereicht
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.levelsense.fluid"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Zwei Verteilungskanaele mit derselben applicationId:
    //   github - APK fuer die GitHub-Releases, mit In-App-Updater
    //            (src/github/AndroidManifest.xml bringt REQUEST_INSTALL_PACKAGES)
    //   play   - AAB fuer den Play Store, ohne In-App-Updater
    // Der passende Dart-Schalter steckt in lib/build_config.dart und wird ueber
    // --dart-define=APP_CHANNEL=... gesetzt.
    flavorDimensions += "channel"
    productFlavors {
        create("github") { dimension = "channel" }
        create("play") { dimension = "channel" }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            // Mit echtem Release-Key signieren, sobald key.properties vorhanden ist;
            // sonst Debug-Key (CI / lokale Schnellbuilds).
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }

    // APK-Dateiname mit Versionsnummer, z. B. Fuellstandsensor-v1.3.3-release.apk
    applicationVariants.all {
        val variant = this
        outputs.all {
            (this as com.android.build.gradle.internal.api.BaseVariantOutputImpl).outputFileName =
                "Fuellstandsensor-v${variant.versionName}-${variant.name}.apk"
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
    // Für FileProvider (In-App-Update: heruntergeladene APK dem Installer geben)
    implementation("androidx.core:core-ktx:1.13.1")
}
