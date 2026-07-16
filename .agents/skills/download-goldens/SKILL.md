---
name: download-goldens
description: Download master-approved golden files for the android_hardware_smoke_test suite directly from Skia Gold's public REST APIs.
---

# Download Goldens

Use this skill to fetch master-approved reference screenshots from Skia Gold to bootstrap or restore the `test_driver/goldens/` assets directory. 

This enables running and debugging the native Android JUnit instrumented tests directly (via Android Studio, VS Code, or Gradle `connectedDebugAndroidTest` tasks) without needing to run the slow host-driven `flutter drive` tests first.

## Prerequisites
1. The **Dart SDK** must be installed and available in your shell's `PATH`.
2. Internet access to `https://flutter-gold.skia.org`.

---

## Usage

### 1. Resolve Dependencies
Before running the script for the first time, fetch the required dependencies (such as `package:crypto`) locally within the skill folder:

```bash
dart pub get --directory=<path_to_skills_repo>/.agents/skills/download-goldens
```

### 2. Run the Downloader
Execute the Dart script, specifying the target output directory using the `--output` parameter.

* **Example command (run from the target Flutter repository root)**:
```bash
dart <path_to_skills_repo>/.agents/skills/download-goldens/scripts/download_goldens.dart \
  --output dev/integration_tests/android_hardware_smoke_test/test_driver/goldens
```

### Script Arguments:
* **`--output <directory_path>`** (Required): The path to the directory where the reference PNG images should be written. For `android_hardware_smoke_test`, this must be the `test_driver/goldens` subdirectory (relative or absolute).

---

### Policy: Fail Loudly
If Skia Gold is down, the API contracts drift, or an expectation digest fails to resolve, the script will print the failure details and exit with code `1` immediately to prevent silent CI or developer workflow corruption.
