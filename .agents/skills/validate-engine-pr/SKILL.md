---
name: validate-engine-pr
description: A systematic skill to check out, compile, and validate Flutter Engine PRs and C++/Dart engine tests locally on macOS/Linux across Metal and OpenGLES backends.
---

# Flutter Engine Autonomous PR & Test Validation Guide

When tasked with validating a Flutter Engine PR or running local C++/Dart engine tests, agents and developers must navigate specific mono-repo build dependencies, graphics backend translation layers (ANGLE), and headless execution flags. 

Follow this definitive, chronological protocol to ensure completely hermetic, non-skipped test execution.

---

## Step 1: Upstream Checkout & Dependency Sync
Always check out the PR explicitly targeting the official upstream repository (`flutter/flutter`) to prevent fork remote mismatches. Immediately fetch dependencies to update `DEPS` and toolchains.

```bash
# 1. Check out the PR branch:
gh pr checkout <PR_NUMBER> -R flutter/flutter

# 2. Sync dependencies using the modern Engine Tool (et):
et fetch
# (Classic GN fallback: gclient sync -D)
```

> [!IMPORTANT]
> If shader compilation fails on macOS with `cannot execute tool 'metal' due to missing Metal Toolchain`, proactively run `xcodebuild -downloadComponent MetalToolchain` to install the required command-line Metal compiler.

---

## Step 2: GN Build Preparation
Generate Ninja build files for the host architecture. On Apple Silicon Macs (`arm64`), explicitly request unoptimized builds and include software/ANGLE OpenGL ES translation layers.

```bash
python3 flutter/tools/gn --unoptimized --mac-cpu=arm64 --use-glfw-swiftshader
```

> [!NOTE]
> **Build Directories and Working Directory Context:**
> Build artifacts and output files reside under `engine/src/out/` when running commands from the repository root (e.g. `/Users/awolff/Projects/andywolff/flutter`).
> * Root directory references: `engine/src/out/host_debug_unopt_arm64/...`
> * Engine directory references (if commands run in `engine/src`): `out/host_debug_unopt_arm64/...`

---

## Step 3: Compiling C++ and Dart Test Targets
Do not rely on automated scripts (`run_tests.py`) to compile C++ or specialized OpenGLES targets. Use `et build` (or Ninja) to explicitly compile precisely what is needed.

> [!TIP]
> **GN Target Types (Source Sets vs. Executables):**
> GN targets defined with `impeller_component` (such as `compiler_unittests`) are compiled as `source_set` targets. To compile and run them, build and execute the parent executable target (e.g., `//flutter/impeller:impeller_unittests` compiles to `impeller_unittests`).


```bash
# Compile C++ unittests, headless UI testers, ANGLE layers, and UI shader fixtures:
et build -c host_debug_unopt_arm64 --target impeller_dart_unittests --target flutter_tester --target flutter_tester_opengles --target libGLESv2.dylib --target libEGL.dylib

# Compile Dart test kernel files (.dill) and copy shader fixtures:
ninja -C out/host_debug_unopt_arm64 flutter/testing/dart flutter/lib/ui/fixtures/shaders:fixtures
```

---

## Step 4: Hermetic C++ Unittest Execution (Impeller)
When executing C++ engine unittests on macOS against OpenGL ES, you **must** inject `DYLD_LIBRARY_PATH` so `dlopen` can locate the compiled ANGLE translation dynamic libraries (`libGLESv2.dylib`).

```bash
# Run all C++ unittests across Metal and OpenGLES backends:
DYLD_LIBRARY_PATH=./out/host_debug_unopt_arm64 ./out/host_debug_unopt_arm64/impeller_dart_unittests

# (Optional) Restrict to Metal only to bypass GL translation errors:
./out/host_debug_unopt_arm64/impeller_dart_unittests --gtest_filter="*Metal*"
```

---

## Step 5: Hermetic Dart GPU Test Execution (`flutter_tester`)
Dart API tests (like `gpu_test.dart`) will **silently skip** all test cases if specific feature flags are omitted. You must invoke the headless runner manually with explicit feature enablement and pre-compiled fixture paths:

### Metal Backend Execution:
```bash
./out/host_debug_unopt_arm64/flutter_tester \
  --disable-vm-service \
  --enable-impeller \
  --impeller-backend=metal \
  --enable-flutter-gpu \
  --use-test-fonts \
  --icu-data-file-path=./out/host_debug_unopt_arm64/icudtl.dat \
  --flutter-assets-dir=./out/host_debug_unopt_arm64/gen/flutter/lib/ui/assets \
  --disable-asset-fonts \
  ./out/host_debug_unopt_arm64/gen/gpu_test.dart.dill
```

### OpenGL ES Backend Execution (via ANGLE):
```bash
DYLD_LIBRARY_PATH=./out/host_debug_unopt_arm64 ./out/host_debug_unopt_arm64/flutter_tester_opengles \
  --disable-vm-service \
  --enable-impeller \
  --impeller-backend=opengles \
  --enable-flutter-gpu \
  --use-test-fonts \
  --icu-data-file-path=./out/host_debug_unopt_arm64/icudtl.dat \
  --flutter-assets-dir=./out/host_debug_unopt_arm64/gen/flutter/lib/ui/assets \
  --disable-asset-fonts \
  ./out/host_debug_unopt_arm64/gen/gpu_test.dart.dill
```

> [!WARNING]
> Always verify that the Dart test output prints actual numerical results (e.g., `00:00 +70: All tests passed!`). If it prints `~66` or similar tildes, the tests were skipped due to missing `--enable-flutter-gpu` or `--enable-impeller` flags.

---

## Step 6: C++ Formatting and Linting Checks
If you have modified C++, Objective-C, or GN files, verify they adhere to style guidelines using the engine tools:

```bash
# Check formatting of all modified files:
engine/src/flutter/bin/et format --dry-run

# Run clang-tidy lints:
engine/src/flutter/bin/et lint
```

> [!IMPORTANT]
> If `et lint` fails with `runtime_stage_types_flatbuffers.h file not found`, compile the default configuration targets first to generate the missing header files:
> `engine/src/flutter/bin/et build -c host_debug`

---

## Summary of Modern Tooling (`et`)
* **Use `et fetch`** and **`et build`** as your primary, ergonomic build management tools. They automatically handle GN flag generation and take full advantage of Remote Build Execution (RBE) caching.
* **Avoid `et test`** when you need to pass custom runtime flags (like `--gtest_filter` or `DYLD_LIBRARY_PATH`), as its argument parser treats unflagged trailing arguments as target patterns.

