---
name: ktlint-runner
description: Runs Kotlin code style analysis and formatting (ktlint) with automatic version resolution and setup. Use this skill whenever Kotlin files (.kt, .kts) are created, modified, or whenever asked to run or format using ktlint.
---

# ktlint-runner Workflow

You must strictly follow this workflow to run or format Kotlin files.

## Prerequisites
1. The **Dart SDK** must be installed and available in your shell's `PATH`.
2. Active internet access (only required on the first execution to download the specified `ktlint` version).

---

## Workflow Steps

### Step 1: Resolve Dependencies
Before running the linter for the first time, resolve its local package dependencies:

```bash
dart pub get --directory=<path_to_skills_repo>/.agents/skills/ktlint-runner
```

### Step 2: Execute
Run the Kotlin linter/formatter script from the target Flutter repository root, passing any specific target files or flags:

```sh
dart <path_to_skills_repo>/.agents/skills/ktlint-runner/scripts/run_ktlint.dart [args]
```

#### Supported Arguments:
* **`-F` or `--format`**: Automatically formats and fixes Kotlin files in-place.
* **`--cleanup`**: Deletes the downloaded linter executable and cache directory immediately after completion.
* **File paths/patterns**: Direct target patterns (e.g., `"dev/integration_tests/android_hardware_smoke_test/**/*.kt"`). If omitted, it defaults to checking the entire repository.

### Step 3: Verification & Output Handling
* If the script succeeds with **0 errors**, print: "**Kotlin lint checks passed successfully!**"
* If style violations are found, report them clearly and help the user resolve them.
