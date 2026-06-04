---
name: run-flutter-driver-test
description: General-purpose skill to run host-driven Flutter Driver integration tests with dynamic backend configuration, target paths, and baseline management.
---

# Flutter Driver Test Orchestrator

Use this skill whenever you need to run, compile, or capture goldens for any `flutter drive`-based integration test.

## Step 1: Execute test target
Run the generalized Dart runner script with appropriate parameter arguments:

```sh
dart .agents/skills/run-flutter-driver-test/scripts/run_driver_test.dart \
  --package-dir "dev/integration_tests/android_hardware_smoke_test" \
  --driver "test_driver/driver_test.dart" \
  --target "integration_test/integration_test_wrapper.dart" \
  [optional-flags]
```

### Required Arguments:
* **`--package-dir <path>`**: The relative path to the Flutter project root (e.g. `dev/integration_tests/android_engine_test`).
* **`--driver <path>`**: Relative path to the test driver file (e.g. `test_driver/engine_handle_test.dart`).
* **`--target <path>`**: Relative path to the target dart application entrypoint (e.g. `lib/engine_handle.dart`).

### Optional Arguments:
* **`--recreate-platform <platforms>`**: A comma-separated list of platforms to recreate before compilation (e.g., `android` or `android,ios`). Runs `flutter create --platform=<platform> --no-overwrite .` inside the package directory.
* **`--update-goldens`**: Prepend environment variables `UPDATE_GOLDENS=1` to update local reference screenshots.
* **`--android-impeller-backend [vulkan|opengles]`**: Finds and rewrites the `AndroidManifest.xml` backend configurations in the nested Android project prior to execution.
* **`--no-dds`**: Disables the Dart Development Service (adds `--no-dds` flag).

