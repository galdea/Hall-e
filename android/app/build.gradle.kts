import java.net.URI
import java.util.Locale

plugins { id("com.android.application") }

val packagedAccountOrigin = providers.environmentVariable("HALLE_ACCOUNT_ORIGIN").orNull.orEmpty().let { raw ->
    if (raw.isEmpty()) return@let ""
    val uri = runCatching { URI(raw) }.getOrNull()
    require(uri != null && uri.scheme == "https" && uri.host != null && uri.userInfo == null &&
        uri.rawQuery == null && uri.rawFragment == null &&
        uri.rawPath in listOf("", "/", "/account/v1", "/account/v1/") &&
        (uri.port == -1 || uri.port in 1..65535) && !uri.rawAuthority.endsWith(':')) {
        "HALLE_ACCOUNT_ORIGIN must be an HTTPS origin without credentials, query or fragment"
    }
    URI("https", null, uri.host.lowercase(Locale.ROOT), if (uri.port == 443) -1 else uri.port,
        null, null, null).toASCIIString()
}

android {
    namespace = "app.halle.companion"
    compileSdk = 36
    buildFeatures { buildConfig = true }
    defaultConfig {
        applicationId = "app.halle.companion"
        minSdk = 31
        targetSdk = 36
        versionCode = 3
        versionName = "0.2.0"
        buildConfigField("String", "ACCOUNT_ORIGIN", "\"$packagedAccountOrigin\"")
        testInstrumentationRunner = "android.test.runner.AndroidJUnitRunner"
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
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
