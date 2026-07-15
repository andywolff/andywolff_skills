---
name: led-staging-run
description: Start a staging run on LUCI of a new or existing test shard using the led tool.
---

# Led Staging Run

Use this skill whenever you need to trigger a staging run on LUCI (swarming) for a new or existing test shard in a Flutter PR.

---

## Step 1: LUCI Authentication
Before using the `led` tool, ensure you are logged in to LUCI services:
```bash
led auth-login
```

## Step 2: Running a Framework PR Staging Test
For Framework PRs (changes under the `flutter/flutter` repository):

### Scenario A: The test/builder already exists on `main`
If the builder is already registered on `main`, run:
```bash
led get-builder 'luci.flutter.staging:<BUILDER_NAME>' \
  | led edit -pa git_ref='refs/pull/<PR_NUMBER>/head' \
  | led edit -pa git_url='https://github.com/flutter/flutter' \
  | led launch
```

> [!NOTE]
> `led edit-recipe-bundle` is only required if you are actively editing recipe code inside a checkout of the `recipes` repository. When running standard staging tests from the `flutter` repository, omit this step.

### Scenario B: The test/builder is brand new (only exists in the PR's `.ci.yaml`)
If the builder does not yet exist on `main`, you must clone the definition of an existing builder of the same type/recipe (e.g., `Linux_mokey cubic_bezier_perf__e2e_summary` for `Linux_mokey` tests) and override the target task name using the `task_name` property:
```bash
led get-builder 'luci.flutter.staging:<EXISTING_BUILDER_NAME>' \
  | led edit -pa git_ref='refs/pull/<PR_NUMBER>/head' \
  | led edit -pa git_url='https://github.com/flutter/flutter' \
  | led edit -pa task_name='<NEW_TASK_NAME>' \
  | led launch
```

## Step 3: Running an Engine PR Staging Test
For Engine PRs (changes under the `flutter/engine` repository):
1. Wait for infrastructure to build the engine artifacts for the PR (verify that the PR has built host/engine artifacts).
2. Retrieve the `COMMIT_HASH` of the engine PR commit.
3. Run the following to target the prebuilt engine version:
```bash
led get-builder 'luci.flutter.staging:<PRESUBMIT_TEST>' \
  | led edit -pa git_ref='refs/pull/<PR_NUMBER>/head' \
  | led edit -pa git_url='https://github.com/flutter/flutter' \
  | led edit -pa flutter_prebuilt_engine_version='<COMMIT_HASH>' \
  | led edit -pa flutter_realm='flutter_archives_v2' \
  | led launch
```
