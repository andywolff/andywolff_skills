---
name: run-android-instrumented-tests-local-engine
description: Run Android instrumented tests using a local engine compile via Gradle.
---

# Run Android Instrumented Tests with Local Engine

Use this skill whenever you need to compile, resolve, and run native Android instrumented tests (e.g. `android_hardware_smoke_test`) against a local engine build on a connected Android device or emulator.

Since running directly via Gradle (`./gradlew`) bypasses the `flutter` CLI tool, you must manually set up the local engine dependencies and configuration.

## Prerequisites
1. You must have a compiled Android local engine (e.g. `android_debug_unopt_arm64`). If not compiled, build it first using the engine tool:
   ```sh
   # Run from the engine src root directory
   et build -c android_debug_unopt_arm64
   ```
2. A connected Android device or emulator matching the compiled architecture (e.g. `arm64-v8a`).

---

## Step-by-Step Execution Flow

### Step 1: Set Up Local Maven Repository Layout
Gradle resolves dependencies dynamically, so you must populate a local Maven directory structure with the engine's compilation artifacts (`.jar`, `.pom`, and `maven-metadata.xml`).

1. Define or create a local maven repo directory in the workspace (e.g. `local_maven_repo/`).
2. Populate the Maven metadata and engine JARs/POMs matching the version of the engine (e.g. `1.0.0-<SHA>`).
3. Add the local maven repo directory to your local `.gitignore` manually if needed, to avoid checking compiled binaries into Git:
   ```sh
   echo "/local_maven_repo/" >> android/.gitignore
   ```

### Step 2: Run Gradle Test Runner with Local Engine Arguments
Execute the instrumented tests task via `./gradlew` from the target project's `android` subdirectory. 

Pass the local maven repository, the path to the engine out directories, and specify the exact architecture (ABI) parameters:

```sh
./gradlew :app:connectedDebugAndroidTest \
  -Plocal-engine-repo=<ABSOLUTE_PATH_TO_LOCAL_MAVEN_REPO> \
  -Plocal-engine-out=<PATH_TO_ANDROID_OUT_DIR> \
  -Plocal-engine-host-out=<PATH_TO_HOST_OUT_DIR> \
  -Plocal-engine-build-mode=debug \
  -Ptarget-platform=android-arm64
```

> [!IMPORTANT]
> **ABI Restriction**: You **must** specify `-Ptarget-platform=android-arm64` (or the architecture matches your local engine compile). If omitted, Gradle will attempt to fetch engine dependency packages for other platforms (like `armeabi-v7a` or `x86_64`) which do not exist in your local Maven repository, causing resolution failures.

---

## Fast Local Iterations (Offline Mode)
To iterate locally without network latency or when offline, you can split the Gradle build and execution phases using the `--offline` flag:

1. **Pre-compile the test APK online** (resolves and caches Maven dependencies once):
   ```sh
   ./gradlew :app:assembleDebugAndroidTest \
     -Plocal-engine-repo=<ABSOLUTE_PATH_TO_LOCAL_MAVEN_REPO> \
     -Plocal-engine-out=<PATH_TO_ANDROID_OUT_DIR> \
     -Plocal-engine-host-out=<PATH_TO_HOST_OUT_DIR> \
     -Plocal-engine-build-mode=debug \
     -Ptarget-platform=android-arm64
   ```

2. **Execute tests offline** (bypasses all remote repository checks, significantly reducing execution latency):
   ```sh
   ./gradlew :app:connectedDebugAndroidTest --offline \
     -Plocal-engine-repo=<ABSOLUTE_PATH_TO_LOCAL_MAVEN_REPO> \
     -Plocal-engine-out=<PATH_TO_ANDROID_OUT_DIR> \
     -Plocal-engine-host-out=<PATH_TO_HOST_OUT_DIR> \
     -Plocal-engine-build-mode=debug \
     -Ptarget-platform=android-arm64
   ```

