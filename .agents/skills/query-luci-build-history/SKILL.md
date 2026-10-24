---
name: query-luci-build-history
description: >-
  Use this skill when the user asks to query LUCI build history or check
  builder stability using the Buildbucket CLI (bb).
---

# Query LUCI Build History and Stability

Use this skill when you need to inspect the status, success rates, and
execution history of builders on LUCI (staging or production).

Because the dashboard pages at `ci.chromium.org/ui/` are client-side rendered
Single Page Applications (SPAs) that require JavaScript, you cannot extract
their history using simple HTTP/HTML scrapers. Instead, use the Buildbucket
CLI (`bb`) to query build data.

## Prerequisites
1. The Buildbucket CLI (`bb`) must be installed (typically distributed as part of `depot_tools`).
2. You must be authenticated to LUCI. Run the following command to log in:
   ```bash
   bb auth-login
   ```

---

## Usage

### 1. Listing Builds
To list the most recent `N` builds for a builder, use the `bb ls` command with the path format `"<project>/<bucket>/<builder>"`. Wrap the path in quotes if the builder name contains spaces.

#### Standard Flutter Paths:
* **Production (Prod)**: `flutter/prod/<builder_name>`
* **Staging (Bringup)**: `flutter/staging/<builder_name>`
* **PR Presubmit (Try)**: `flutter/try/<builder_name>`

```sh
bb ls -n <limit> "<project>/<bucket>/<builder>"
```

**Example:**
```sh
bb ls -n 50 "flutter/staging/Linux_android_emu android_hardware_smoke_opengles_tests"
```

### 2. Checking Builder Stability (Failures Query)
To determine if a builder is stable enough to be promoted out of bringup (meaning it can run in presubmit and block PR merge without introducing flakes), you need to check for regular failures (`FAILURE`), infrastructure failures (`INFRA_FAILURE`), and timeouts/hangs (`CANCELED`).

> [!WARNING]
> **Go Flag Overwrite Limitation**: Because the `bb` CLI is written in Go, passing the `-status` flag multiple times (e.g. `-status failure -status infra_failure`) does **NOT** append them; instead, the later occurrence completely overwrites the earlier one.

To query for all failure statuses safely, use one of the following methods:

#### Method A: Filter using grep (Recommended)
Query the recent builds with minimal fields and grep for failing statuses. This is the most reliable way to inspect the recent runs window:
```sh
bb ls -n <limit> -fields "id,status" "<project>/<bucket>/<builder>" | grep -E "FAILURE|INFRA_FAILURE|CANCELED"
```

#### Method B: Run separate queries
Run distinct commands to verify each status separately:
```sh
bb ls -n <limit> -status failure "<project>/<bucket>/<builder>"
bb ls -n <limit> -status infra_failure "<project>/<bucket>/<builder>"
bb ls -n <limit> -status canceled "<project>/<bucket>/<builder>"
```

* **Interpreting Results**: If no matching builds are returned by these commands, the builder has a **100% success rate** over the queried limit.

### 3. Automated Flakiness & Baseline Analysis

To perform a comprehensive flakiness analysis automatically across all shards
(Vulkan and OpenGLES, both host-driven and instrumented) and environments
(Staging, Prod, and Try), run the packaged analysis script:

```sh
dart .agents/skills/personal-query-luci-build-history/scripts/analyze_flakiness.dart <output_report.md>
```

#### Key Capabilities:
1. **Multi-Environment Coverage**: Analyzes Staging, Prod, and Try buckets
   for all target shards.
2. **Commit/Build Date Tracking**: Identifies the creation timestamps of the
   earliest and latest valid runs in the window, and reports specific failure
   timestamps.
3. **Bringup-Removal Warnings**: Detects if Staging results are older than 7
   days (indicating the shard has been promoted to production by removing
   `bringup: true` from `.ci.yaml`) and posts a warning in the report.
4. **AGP Mitigation Exclusion**: Automatically parses build summaries to identify
   and filter out compile-time errors caused by AGP 9 migration, establishing
   a clean baseline of actual test failures.
5. **CANCELED & VM Outage Filtering**: Automatically excludes presubmit
   developer cancellations (`CANCELED`) and host bot provisioning outages
   (`INFRA_FAILURE` / package download timeouts), extending the search window
   up to 300 builds to measure the true pass rate across 100 completed test runs.


### 4. Printing Clean Status Summaries
If you want to quickly see the status of all builds without dumping verbose build parameters, filter the fields:

```sh
bb ls -n <limit> -fields "id,status" "<project>/<bucket>/<builder>"
```
This prints a list of URLs and their corresponding statuses (e.g. `SUCCESS` or `FAILURE`).


### 5. Querying Average Builder Execution Time
To calculate the average execution time (in minutes) of successful builds for a specific builder, query the recent builds with JSON output enabled and parse using `jq`:

```sh
# Note: jq's fromdate requires stripping fractional seconds/nanoseconds (.123456Z -> Z)
bb ls -n <limit> -status success -json "<project>/<bucket>/<builder>" \
  | jq -s 'map(((.endTime | sub("\\.[0-9]+Z$"; "Z") | fromdate) - (.startTime | sub("\\.[0-9]+Z$"; "Z") | fromdate))) | add / length / 60'
```


### 6. Querying Build Step Durations / Breakdown
To inspect where time is spent during a build, fetch the build steps with JSON output enabled and parse step durations (in seconds) sorted by the longest steps:

```sh
# Note: jq's fromdate requires stripping fractional seconds/nanoseconds (.123456Z -> Z)
bb get -json -steps <BUILD_ID_OR_PATH> \
  | jq '.steps[] | select(.endTime != null) | {name: .name, duration: (((.endTime | sub("\\.[0-9]+Z$"; "Z") | fromdate) - (.startTime | sub("\\.[0-9]+Z$"; "Z") | fromdate)))}' \
  | jq -s 'sort_by(.duration) | reverse[]'
```


### 7. Avoiding Console Output Truncation
Because `bb ls` outputs verbose metadata (such as build tags and commit lists) by default, queries with large limits (e.g., `-n 50` or `-n 100`) will exceed the agent console's output limit. This triggers truncation at the top of the output, causing the agent to miss the most recent builds and failures.

To avoid truncation, always use one of the following strategies:

* **Use Field Filtering**: Always limit the output payload size by requesting only necessary fields (like `id` and `status`):
  ```sh
  bb ls -n 100 -fields "id,status" "<project>/<bucket>/<builder>"
  ```
* **Write to File and View**: If you need full build metadata, redirect the output of the `bb` command to a local file in the workspace, and then use `view_file` to read the file in slices:
  ```sh
  bb ls -n 100 "<project>/<bucket>/<builder>" > build_history.txt
  ```


### 8. Diagnosing Specific Build Failures
When a build has status `FAILURE`, you can use `bb` to locate the failing step, retrieve the logs, and diagnose the root cause:

#### A. List Build Steps
Identify which step failed by printing all build steps:
```sh
bb get -steps <BUILD_ID_OR_PATH>
```
Look for steps marked with `FAILURE` (e.g. `"run test.dart ..."`).

#### B. Fetch Step Logs
Retrieve the log output (stdout/stderr) for the failing step. To avoid console truncation, always write the log to a local file and read it incrementally:
```sh
bb log <BUILD_ID_OR_PATH> "<STEP_NAME>" stdout > step_log.txt
```

#### C. Analyzing Skia Gold Golden Mismatches & Untriaged Images
For graphics/golden image comparison failures, inspect the test stdout:
* **Untriaged Presubmit/Post-Submit Goldens**:
  * If a PR alters visual rendering or introduces a new test case without triaging the image digest in presubmit, Skia Gold will fail with:
    `SkiaException: Skia Gold received an unapproved image in post-submit testing.`
  * The log will contain links in the format:
    `https://flutter-gold.skia.org/detail?grouping=name%3D...&digest=...`
  * **Action**: You MUST extract and present these links directly to the user. In presubmit, images are triaged on the Flutter Gold web UI by the PR author. In post-submit, untriaged images require approval by a committer or revert.
* **Evaluating PR Outcomes & Test Value**:
  When investigating presubmit golden failures on a PR, determine how the PR was resolved:
  1. **Intentional Visual Change (Golden Approved)**: The PR author reviewed the visual diff on Skia Gold, approved the new digest as intended behavior, re-ran presubmit, and merged successfully.
  2. **Unintended Visual Regression (Fix Committed)**: The author noticed the golden failure, identified that their code introduced an unintended visual regression, committed a fix to restore the original rendering/golden match, and merged without updating goldens. **This demonstrates the smoke test suite successfully catching a real regression in presubmit.**
  3. **Inspection via `gh` CLI**: Run `gh pr view <PR_NUMBER> --comments` or `git log upstream/master --grep="<PR_NUMBER>"` to verify whether the author approved goldens or committed code remediations before landing.
* **Inspect Digest Size for Blank Screens**: A very small PNG output size (e.g., ~1.4 KB compared to the typical 10 KB–20 KB) indicates a completely blank or uniform (usually black) screenshot.
* **Identify System-Level Compositing Issues**: If multiple distinct test scenarios (e.g. different platform view composition modes) fail by producing the **exact same image digest**, this indicates a system-level rendering or compositing failure (such as an emulator GPU driver or Vulkan surface composition collapse) rather than a code defect.


### 9. Waiting for Builds to Complete (Watch/Collect Mode)
To wait for one or more builds to finish running before proceeding with further validation, use the `bb collect` command. It blocks until the specified builds terminate:

```sh
bb collect <BUILD_ID> [<BUILD_ID>...]
```

**Example:**
```sh
bb collect 8675453743800778209 8675453737898952849
```
This is the recommended watch method when monitoring staging runs launched via `led launch`.

