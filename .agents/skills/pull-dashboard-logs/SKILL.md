---
name: pull-dashboard-logs
description: >-
  Use this skill when the user asks to inspect, pull, or diagnose failing
  presubmit checks or dashboard logs for a Flutter PR or commit.
---

# Pull Dashboard Logs

Use this skill when you need to inspect, pull, or diagnose failures from Flutter PR presubmit checks or dashboard builds.

This skill ensures that all verbose outputs from the Buildbucket CLI (`bb`) are saved locally to a file first before analyzing, preventing terminal truncation, context overflow, and permission blocks.

> [!IMPORTANT]
> **Always Confirm Target PR**: Do not guess or auto-detect the PR. If the user does not explicitly specify a PR number or commit, ask the user which PR they want to inspect before running commands.

## Automated Triage via `triage_build.dart`

The skill includes a dedicated Dart triage script that resolves the PR commit SHA, identifies failing builders, dumps step hierarchies and logs locally, and extracts high-signal failure excerpts (native crashes, ninja build errors, Dart test diffs, and timeouts).

### Usage:

1. **Triage a Pull Request** (primary entrypoint):
   ```bash
   dart .agents/skills/personal-pull-dashboard-logs/scripts/triage_build.dart --pr <PR_NUMBER>
   ```

2. **Filter by Specific Builder on a PR**:
   ```bash
   dart .agents/skills/personal-pull-dashboard-logs/scripts/triage_build.dart --pr <PR_NUMBER> --builder "Mac mac_unopt"
   ```

3. **Triage a Specific Commit SHA**:
   ```bash
   dart .agents/skills/personal-pull-dashboard-logs/scripts/triage_build.dart --sha <COMMIT_SHA>
   ```

4. **Triage a Specific Build ID**:
   ```bash
   dart .agents/skills/personal-pull-dashboard-logs/scripts/triage_build.dart --build <BUILD_ID>
   ```

All logs and step traces are saved locally to `/tmp/dashboard_logs/` (or `--output-dir <path>`).

---

## Manual Workflow via `bb`

If manual inspection is required, always follow this discipline:

### 1. Identify Failing Check / Commit
Find the commit SHA and failing builders from GitHub check-runs:
```bash
gh api repos/flutter/flutter/commits/<SHA>/check-runs \
  --jq '.check_runs[] | select(.name == "Dashboard Checks" or .conclusion == "failure") | {name, text: .output.text}'
```

### 2. Dump Build List to File
Dump all builds for the commit to a local scratch file:
```bash
bb ls -t "buildset:sha/git/<SHA>" > /tmp/dashboard_logs/builds.txt
grep -i "<builder_name>" /tmp/dashboard_logs/builds.txt
```

### 3. Dump Build Steps
Fetch the step hierarchy for the failing build ID to a local file:
```bash
bb get <BUILD_ID> -steps > /tmp/dashboard_logs/steps_<BUILD_ID>.txt
grep "FAILURE" /tmp/dashboard_logs/steps_<BUILD_ID>.txt
```
*Note on Orchestrator Builds (e.g. `engine_v2` like `mac_unopt` or `windows_arm_host_engine`)*:
If the failure is inside `Step "display builds"` or links to a sub-build drone (e.g. `[Mac Engine Drone for ...](https://cr-buildbucket.appspot.com/build/<SUB_BUILD_ID>)`), fetch the sub-build's steps:
```bash
bb get <SUB_BUILD_ID> -steps > /tmp/dashboard_logs/steps_<SUB_BUILD_ID>.txt
```

### 4. Fetch the Failing Step Log
Once the leaf failing step is identified (e.g., `test: Host Tests for host_debug` or `run test.dart for ...`), pull the full raw step log to a file:
```bash
bb log <BUILD_ID> "<STEP_NAME>" > /tmp/dashboard_logs/log.txt
```

### 5. Efficiently Extract Failure Signals
Avoid loading entire massive logs into context. Search for high-signal patterns or tail the log:
```bash
# C++ crashes and assertion failures
grep -E "(\[  FAILED  \]|Caught signal SIG|Assertion failed)" /tmp/dashboard_logs/log.txt

# Ninja compiler errors
grep -B 5 -A 10 "FAILED:" /tmp/dashboard_logs/log.txt

# Python tracebacks
grep -B 5 -A 20 "Traceback (most recent call last):" /tmp/dashboard_logs/log.txt

# Dart test failures
grep -B 5 -A 25 "Expected:" /tmp/dashboard_logs/log.txt
grep -C 5 "╔═╡ERROR #" /tmp/dashboard_logs/log.txt

# Timeouts
grep -E "(did not complete|timed out)" /tmp/dashboard_logs/log.txt

# Tail last 150 lines if unformatted
tail -n 150 /tmp/dashboard_logs/log.txt
```
