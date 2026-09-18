plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "ai.openclaw.mobile"
    compileSdk = 35

    defaultConfig {
        applicationId = "ai.openclaw.mobile"
        minSdk = 24
        targetSdk = 35
        versionCode = 8
        versionName = "0.8.0-dev"
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    packaging {
        resources.excludes += setOf(
            "META-INF/DEPENDENCIES", "META-INF/LICENSE*", "META-INF/NOTICE*",
            "META-INF/*.kotlin_module", "**/*.version"
        )
    }
}

dependencies {
    // Keep Android deliberately small: no AppCompat, Activity-KTX, Core-KTX,
    // Compose, WebView/Chromium, or AndroidX Security runtime.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")
}
