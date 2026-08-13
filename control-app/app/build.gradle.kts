plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.str_adblocker.control"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.str_adblocker.control"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // 无第三方依赖：纯平台 API
}

// 构建时把模块 webroot 同步进 assets（应用内自托管 WebUI 的资源来源）
val copyWebroot by tasks.registering(Copy::class) {
    from(rootProject.file("../webroot"))
    into("src/main/assets/webroot")
    doFirst {
        delete("src/main/assets/webroot")
    }
}

tasks.named("preBuild") {
    dependsOn(copyWebroot)
}
