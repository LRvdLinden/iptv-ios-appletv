import java.io.File

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// Zelfde versie/build als iOS (project.yml in de root van de repo)
val projectYml = File(rootDir.parentFile, "project.yml").takeIf { it.exists() }?.readText() ?: ""
val buildNumber = Regex("CURRENT_PROJECT_VERSION: \"(\\d+)\"").find(projectYml)?.groupValues?.get(1)?.toInt() ?: 1
val marketing = Regex("MARKETING_VERSION: \"([\\d.]+)\"").find(projectYml)?.groupValues?.get(1) ?: "1.0.0"

// App-sleutels: uit GitHub Secrets (CI) of local.properties
val localProps = java.util.Properties().apply {
    val f = File(rootDir, "local.properties"); if (f.exists()) f.inputStream().use { load(it) }
}
fun key(name: String): String = (System.getenv(name) ?: localProps.getProperty(name) ?: "").trim().replace("\"", "")

android {
    namespace = "nl.lrvdlinden.bingr"
    compileSdk = 35

    defaultConfig {
        applicationId = "nl.lrvdlinden.bingr"
        minSdk = 24
        targetSdk = 35
        versionCode = buildNumber
        versionName = marketing
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
        buildConfigField("String", "TRAKT_CLIENT_ID", "\"${key("TRAKT_CLIENT_ID")}\"")
        buildConfigField("String", "TRAKT_CLIENT_SECRET", "\"${key("TRAKT_CLIENT_SECRET")}\"")
        buildConfigField("String", "OPENSUBTITLES_API_KEY", "\"${key("OPENSUBTITLES_API_KEY")}\"")
        buildConfigField("String", "OMDB_API_KEY", "\"${key("OMDB_API_KEY")}\"")
        buildConfigField("String", "TMDB_API_KEY", "\"${key("TMDB_API_KEY").ifEmpty { key("TMDB_ACCESS_TOKEN") }}\"")
    }

    signingConfigs {
        create("bingr") {
            storeFile = file("bingr-release.jks")
            storePassword = "bingr-android"
            keyAlias = "bingr"
            keyPassword = "bingr-android"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("bingr")
        }
        debug {
            signingConfig = signingConfigs.getByName("bingr")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // Vertalingen gedeeld met iOS: Shared/Resources/Translations.json
    sourceSets["main"].assets.srcDirs("src/main/assets", File(rootDir.parentFile, "Shared/Resources"))

    packaging {
        resources { excludes += listOf("/META-INF/{AL2.0,LGPL2.1}", "META-INF/DEPENDENCIES") }
        jniLibs { useLegacyPackaging = true }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("io.coil-kt:coil-compose:2.7.0")

    // Spelers: Media3 (ExoPlayer) voor HLS/DASH/MP4/TS, VLC voor de rest
    val media3 = "1.5.1"
    implementation("androidx.media3:media3-exoplayer:$media3")
    implementation("androidx.media3:media3-exoplayer-hls:$media3")
    implementation("androidx.media3:media3-exoplayer-dash:$media3")
    implementation("androidx.media3:media3-ui:$media3")
    implementation("androidx.media3:media3-session:$media3")
    implementation("androidx.media3:media3-datasource-okhttp:$media3")
    implementation("org.videolan.android:libvlc-all:3.5.1")

    // Chromecast
    implementation("com.google.android.gms:play-services-cast-framework:21.5.0")
    implementation("androidx.mediarouter:mediarouter:1.7.0")

    // Profielfoto kiezen
    implementation("androidx.activity:activity-ktx:1.9.3")
}
