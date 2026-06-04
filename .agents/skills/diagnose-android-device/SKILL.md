---
name: diagnose-android-device
description: Check connected Android device model, GPU rendering driver, and graphics version compatibility.
---

# Diagnose Android Device

Use this skill to assess the graphics hardware profile, OpenGL ES version, and Vulkan driver compatibility of the connected Android device or emulator prior to executing test runs or to triage graphics failures.

## Usage

Execute the diagnostic script from the `flutter` repository root:

```sh
dart .agents/skills/personal-diagnose-android-device/scripts/device_diagnostics.dart
```

### Diagnostics Performed:
* Reads device model via `getprop ro.product.model`.
* Queries Vulkan hardware driver name via `getprop ro.hardware.vulkan`.
* Queries and decodes OpenGL ES version via `getprop ro.opengles.version`.
* Warns if it detects the standard Android Emulator (`ranchu` driver) where Vulkan is known to fail, recommending OpenGLES instead.
