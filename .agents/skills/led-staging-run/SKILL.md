---
name: led-staging-run
description: Start a staging run on LUCI of a new or existing test shard using the led tool.
---

# Led Staging Run

Use this skill whenever you need to trigger a staging run on LUCI (swarming) for a new or existing test shard in a Flutter PR.

## Prerequisites
1. The `led` CLI tool must be installed (distributed as part of `depot_tools`).
2. Verify authentication status or login:
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

### Step 2: Running an Engine PR Staging Test
For Engine PRs (changes under the `flutter/engine` repository):

1. **Verify artifacts are built**: Ensure the PR has completed its compilation checks and built the engine artifacts:
   ```bash
   gh pr checks <ENGINE_PR_NUMBER> --repo flutter/engine
   ```
2. **Retrieve the Engine Commit Hash**: Get the target commit hash of the engine PR:
   ```bash
   gh pr view <ENGINE_PR_NUMBER> --repo flutter/engine --json headRefOid -q .headRefOid
   ```
3. **Launch the staging test**: Run `led get-builder` targeting the prebuilt engine version.
   * *If there is no accompanying framework PR*, set the framework `git_ref` to the main branch (`refs/heads/main` or `refs/heads/master` depending on the active main branch):

```bash
led get-builder 'luci.flutter.staging:<PRESUBMIT_TEST_NAME>' \
  | led edit -pa git_ref='refs/heads/main' \
  | led edit -pa git_url='https://github.com/flutter/flutter' \
  | led edit -pa flutter_prebuilt_engine_version='<COMMIT_HASH>' \
  | led edit -pa flutter_realm='flutter_archives_v2' \
  | led launch
```

### Step 3: Output & Task Monitoring
When `led launch` succeeds, it outputs JSON metadata containing a Swarming task URL (e.g., `https://chromium-swarm.appspot.com/task?id=...`). 

**You MUST extract this task URL and present it directly to the user in your final response** so they can easily click and monitor the build progress in their web browser.
