import java.net.URI
import java.util.Locale

plugins { id("com.android.application") }

val staging = when (providers.environmentVariable("HALLE_STAGING").orNull ?: "0") {
    "0" -> false
    "1" -> true
    else -> error("HALLE_STAGING must be 0 or 1")
}

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
if (staging) {
    require(packagedAccountOrigin.isNotEmpty()) {
        "HALLE_STAGING=1 requires HALLE_ACCOUNT_ORIGIN to be set to the staging HTTPS origin."
    }
}

android {
    namespace = "app.halle.companion"
    compileSdk = 36
    buildFeatures { buildConfig = true }
    defaultConfig {
        applicationId = if (staging) "app.halle.companion.staging" else "app.halle.companion"
        manifestPlaceholders["appLabel"] = if (staging) "Hall-e Staging" else "Hall-e"
        manifestPlaceholders["exportPairing"] = (!staging).toString()
        minSdk = 31
        targetSdk = 36
        // Above Órbita's 0.3.0/code 4 preview so this build installs over it without clearing app data.
        versionCode = 6
        versionName = "0.4.0"
        buildConfigField("boolean", "STAGING", staging.toString())
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
        // Staging debug gets its own suffix so it installs beside the staging release build.
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

/** Copies the synthetic staging tone into a variant's generated asset directory. */
abstract class PrepareStagingTone : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val tone: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val directory = outputDir.get().asFile
        directory.deleteRecursively()
        check(directory.mkdirs()) { "Could not create $directory" }
        tone.get().asFile.copyTo(directory.resolve("phone-tone.mp4"))
    }
}

if (staging) {
    val stagingTone = rootProject.layout.projectDirectory.file("../coordinator/test-support/phone-tone.mp4")
    androidComponents {
        onVariants { variant ->
            val task = tasks.register<PrepareStagingTone>(
                "prepare${variant.name.replaceFirstChar { it.uppercase() }}StagingTone") { tone.set(stagingTone) }
            // AGP wires asset merging to the task output, so no preBuild dependency is needed.
            variant.sources.assets?.addGeneratedSourceDirectory(task, PrepareStagingTone::outputDir)
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    // QR scanning for pairing invitations (Órbita "Escanear QR del Mac").
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
