---
name: configure-android-impeller-backend
description: Configure Impeller graphics rendering backend (Vulkan or OpenGLES) in Android Manifest files.
---

# Configure Android Impeller Backend

Use this skill to configure or toggle the active Impeller rendering backend (`vulkan` or `opengles`) across the Android application manifests, or to restore them to their original configuration.

## Usage

### 1. Set Backend
Configure all target manifest files to use a specific graphics backend:

```sh
dart .agents/skills/personal-configure-android-impeller-backend/scripts/configure_impeller_backend.dart \
  --package-dir "dev/integration_tests/android_hardware_smoke_test" \
  --action set \
  --backend "opengles"
```

This returns a JSON backup string on `stdout` which is required to restore the files later.

### 2. Restore Manifests
Restore all manifest files to their original states using the backup JSON string:

```sh
dart .agents/skills/personal-configure-android-impeller-backend/scripts/configure_impeller_backend.dart \
  --package-dir "dev/integration_tests/android_hardware_smoke_test" \
  --action restore \
  --backup-data '<json-backup-string>'
```

### Arguments:
* **`--package-dir <path>`**: Relative path to the target Flutter project root.
* **`--action [set|restore]`**: The action to perform.
* **`--backend [vulkan|opengles]`**: The backend option to configure (required for `set`).
* **`--backup-data <json>`**: The JSON backup mapping string returned during `set` (required for `restore`).
