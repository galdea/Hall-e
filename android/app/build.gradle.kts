plugins { id("com.android.application") }

android {
    namespace = "app.halle.companion"
    compileSdk = 36
    buildFeatures { buildConfig = true }
    val requestedTestBuildType = providers.gradleProperty("halleTestBuildType").orElse("debug").get()
    if (requestedTestBuildType !in setOf("debug", "e2e")) {
        throw GradleException("halleTestBuildType must be either 'debug' or 'e2e'.")
    }
    testBuildType = requestedTestBuildType
    defaultConfig {
        applicationId = "app.halle.companion"
        minSdk = 31
        targetSdk = 36
        versionCode = 4
        versionName = "0.3.0"
        testInstrumentationRunner = "app.halle.companion.MobileStoreInstrumentation"
    }

    val releaseStorePath = System.getenv("ANDROID_KEYSTORE")
    val releaseStorePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
    val releaseKeyAlias = System.getenv("ANDROID_KEY_ALIAS")
    val releaseKeyPassword = System.getenv("ANDROID_KEY_PASSWORD")
    val releaseRequested = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
    if (releaseRequested && listOf(releaseStorePath, releaseStorePassword, releaseKeyAlias, releaseKeyPassword).any { it.isNullOrBlank() }) {
        throw GradleException("Release signing requires ANDROID_KEYSTORE, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, and ANDROID_KEY_PASSWORD.")
    }
    signingConfigs {
        if (!releaseStorePath.isNullOrBlank() && !releaseStorePassword.isNullOrBlank()
            && !releaseKeyAlias.isNullOrBlank() && !releaseKeyPassword.isNullOrBlank()) {
            create("release") {
                storeFile = file(releaseStorePath)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        debug { applicationIdSuffix = ".preview" }
        // Isolated device data for the real coordinator + QR + phone-to-Mac E2E. Never shares
        // the installed preview app's meeting store or transfer queue.
        create("e2e") {
            initWith(getByName("debug"))
            applicationIdSuffix = ".e2e"
            matchingFallbacks += listOf("debug")
        }
        release {
            isMinifyEnabled = false
            if (signingConfigs.names.contains("release")) signingConfig = signingConfigs.getByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
