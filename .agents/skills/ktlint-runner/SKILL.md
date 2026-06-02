---
name: ktlint-runner
description: Runs Kotlin code style analysis and formatting (ktlint) with automatic version resolution and setup. Use this skill whenever Kotlin files (.kt, .kts) are created, modified, or whenever asked to run or format using ktlint.
---

# ktlint-runner Workflow

You must strictly follow this workflow to run or format Kotlin files.

## Step 1: Execute
Run the Kotlin linter/formatter script, passing any specific target files or flags:

```sh
dart .agents/skills/ktlint-runner/scripts/run_ktlint.dart [args]
```

### Supported Arguments:
* **`-F` or `--format`**: Automatically formats and fixes Kotlin files in-place.
* **`--cleanup`**: Deletes the downloaded linter executable and cache directory immediately after completion.
* **File paths/patterns**: Direct target patterns (e.g. `"dev/integration_tests/android_hardware_smoke_test/**/*.kt"`). If omitted, it defaults to checking the entire repository.

## Step 2: Verification & Output Handling
* If the script succeeds with **0 errors**, print: "**Kotlin lint checks passed successfully!**"
* If style violations are found, report them clearly and help the user resolve them.
