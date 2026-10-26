---
name: led-staging-run
description: >-
  Use this skill when the user wants to trigger a staging run on LUCI (swarming)
  for a new or existing test shard in a Flutter PR.
---

# Led Staging Run

Use this skill when you need to trigger a staging run on LUCI (swarming) for
a new or existing test shard in a Flutter PR. For additional context, see
[Running-Devicelab-Tests-For-PR.md](https://github.com/flutter/flutter/blob/main/docs/infra/Running-Devicelab-Tests-For-PR.md).

## Prerequisites
1. The `led` CLI tool must be installed (distributed as part of `depot_tools`).
2. (Internal/Googlers) Verify SSO / LOAS credentials if targeting internal builders (since `led` commands depend on these certificates):
   ```bash
   gcertstatus || gcert
   # or
   glogin status || glogin
   ```
3. Verify `led` authentication status or login:
   ```bash
   # Check authentication status
   led auth-info

   # Login if not authenticated
   led auth-login
   ```

---

## Step-by-Step Execution Flow

### Step 1: Running a Framework PR Staging Test
For Framework PRs (changes under the `flutter/flutter` repository):

#### Scenario A: The test/builder already exists on `main`
If the builder is already registered on `main`, run:
```bash
led get-builder 'luci.flutter.staging:<BUILDER_NAME>' \
  | led edit -pa git_ref='refs/pull/<PR_NUMBER>/head' \
  | led edit -pa git_url='https://github.com/flutter/flutter' \
  | led launch
```

> [!NOTE]
> `led edit-recipe-bundle` is only required if you are actively editing recipe code inside a checkout of the `recipes` repository. When running standard staging tests from the `flutter` repository, omit this step.

#### Scenario B: The test/builder is brand new (only exists in the PR's `.ci.yaml`)
If the builder does not yet exist on `main`, you must clone the definition of an existing builder of the same type/recipe (e.g., `Linux_mokey cubic_bezier_perf__e2e_summary` for `Linux_mokey` tests) and override the target task name using the `task_name` property:
```bash
led get-builder 'luci.flutter.staging:<EXISTING_BUILDER_NAME>' \
  | led edit -pa git_ref='refs/pull/<PR_NUMBER>/head' \
  | led edit -pa git_url='https://github.com/flutter/flutter' \
  | led edit -pa task_name='<NEW_TASK_NAME>' \
  | led launch
```

### Step 2: Running Staging Tests for PRs Modifying Engine Code
When a PR modifies files under `engine/`, `bin/internal/update_engine_version.sh` computes a content-aware hash representing the unreleased engine code. Standalone staging framework shards will fail at `flutter config` with a 404 from Google Cloud Storage unless directed to the prebuilt engine artifacts published by presubmit builders.

1. **Verify or Wait for Engine Artifacts**:
   Locate and monitor the host engine builders (such as `Mac mac_host_engine` or `Linux linux_host_engine`), which build and archive the engine binaries to `flutter_archives_v2`. Avoid tracking test-runner builders like `mac_unopt`, which execute unit tests after compilation:
   ```bash
   # Find engine builders for the commit
   bb ls -t "buildset:sha/git/<COMMIT_SHA>"

   # Wait for the host engine builder to complete
   bb collect <HOST_ENGINE_BUILD_ID>
   ```

2. **Launch Staging Shards with Prebuilt Engine and Explicit Shard**:
   Once the host engine builder completes, pass `flutter_prebuilt_engine_version`, `flutter_realm`, and the explicit `shard` (e.g., `shard='framework_tests'`) to prevent the drone recipe from defaulting to `build_tests`:
   ```bash
   led get-builder 'luci.flutter.staging:<BUILDER_NAME>' \
     | led edit -pa git_ref='refs/pull/<PR_NUMBER>/head' \
     | led edit -pa git_url='https://github.com/flutter/flutter' \
     | led edit -pa shard='<SHARD_NAME>' \
     | led edit -pa flutter_prebuilt_engine_version='<COMMIT_SHA>' \
     | led edit -pa flutter_realm='flutter_archives_v2' \
     | led launch
   ```

### Step 3: Output & Task Monitoring
When `led launch` succeeds, it outputs JSON metadata containing a Swarming/Buildbucket task URL and build ID.

1. **Watch the Build**: Use the `bb collect` command in a background task to block and wait for the builds to end:
   ```bash
   bb collect <BUILD_ID>
   ```
2. **Present Links**: Extract the Swarming task URL (e.g., `https://ci.chromium.org/b/...`) and present it directly to the user in your final response so they can easily click and monitor the build progress in their web browser.
