group = "com.example.wiseplug_alarm"
version = "1.0"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.example.wiseplug_alarm"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // The app's Firebase plugins already ship these (Firebase BoM 35.2.0,
    // firebase_core 5.2.0): the backup alarm reads the outlet with them.
    compileOnly(platform("com.google.firebase:firebase-bom:35.2.0"))
    compileOnly("com.google.firebase:firebase-database")
    compileOnly("com.google.firebase:firebase-auth")
    implementation("androidx.core:core:1.13.1")
}
