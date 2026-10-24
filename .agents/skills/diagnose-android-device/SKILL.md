---
name: diagnose-android-device
description: >-
  Use this skill when the user wants to check the connected Android device
  model, GPU rendering driver, and graphics version compatibility.
---

# Diagnose Android Device

Use this skill to assess the graphics hardware profile, OpenGL ES version, and
Vulkan driver compatibility of the connected Android device or emulator prior
to executing test runs or to triage graphics failures.

## Usage

Execute the diagnostic script:

```sh
# Auto-detect single connected device:
dart .agents/skills/diagnose-android-device/scripts/device_diagnostics.dart

# Or target a specific device when multiple are connected:
dart .agents/skills/diagnose-android-device/scripts/device_diagnostics.dart -s <device-serial>
```

*(Note: In target repositories symlinked via `manage-personal-skills`, the directory path is `.agents/skills/personal-diagnose-android-device/...`)*

### Diagnostics Performed:
* Validates active `adb` connection and lists connected devices if multiple are present.
* Reads device model via `getprop ro.product.model`.
* Queries Android OS version and SDK level via `ro.build.version.release` and `ro.build.version.sdk`.
* Queries CPU architecture via `ro.product.cpu.abi` (for local engine target matching).
* Queries Vulkan hardware driver name via `getprop ro.hardware.vulkan`.
* Queries and decodes OpenGL ES version via `getprop ro.opengles.version`.
* Warns if it detects the standard Android Emulator (`ranchu` driver) where Vulkan is known to fail, recommending OpenGLES instead.
