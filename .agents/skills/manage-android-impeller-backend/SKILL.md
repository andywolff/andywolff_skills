---
name: manage-android-impeller-backend
description: Manage Android Impeller graphics rendering backend configurations (detection, configuration, and restoration).
---

# Manage Android Impeller Backend

Use this skill to detect, configure, or toggle the active Impeller rendering backend (`vulkan` or `opengles`) across the Android application manifests, or to restore them to their original configuration.

## Usage

### 1. Detect Configured Backends
Scan the Android project manifests and report the Impeller graphics backend configured for each build variant:

```sh
dart .agents/skills/personal-manage-android-impeller-backend/scripts/manage_impeller_backend.dart \
  --package-dir "dev/integration_tests/android_hardware_smoke_test" \
  --action detect
```

### 2. Set Backend
Configure all target manifest files to use a specific graphics backend:

```sh
dart .agents/skills/personal-manage-android-impeller-backend/scripts/manage_impeller_backend.dart \
  --package-dir "dev/integration_tests/android_hardware_smoke_test" \
  --action set \
  --backend "opengles"
```

This returns a JSON backup string on `stdout` which is required to restore the files later.

### 3. Restore Manifests
Restore all manifest files to their original states using the backup JSON string:

```sh
dart .agents/skills/personal-manage-android-impeller-backend/scripts/manage_impeller_backend.dart \
  --package-dir "dev/integration_tests/android_hardware_smoke_test" \
  --action restore \
  --backup-data '<json-backup-string>'
```

### Arguments:
* **`--package-dir <path>`**: Relative path to the target Flutter project root.
* **`--action [detect|set|restore]`**: The action to perform.
* **`--backend [vulkan|opengles]`**: The backend option to configure (required for `set`).
* **`--backup-data <json>`**: The JSON backup mapping string returned during `set` (required for `restore`).
