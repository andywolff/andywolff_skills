---
name: query-luci-build-history
description: Query LUCI build history and check builder stability using the Buildbucket CLI (bb).
---

# Query LUCI Build History and Stability

Use this skill when you need to inspect the status, success rates, and execution history of builders on LUCI (staging or production).

Because the dashboard pages at `ci.chromium.org/ui/` are client-side rendered Single Page Applications (SPAs) that require JavaScript, you cannot extract their history using simple HTTP/HTML scrapers. Instead, use the Buildbucket CLI (`bb`) to query build data.

---

## Usage

### 1. Listing Builds
To list the most recent `N` builds for a builder, use the `bb ls` command with the path format `"<project>/<bucket>/<builder>"`. Wrap the path in quotes if the builder name contains spaces:

```sh
bb ls -n <limit> "<project>/<bucket>/<builder>"
```

**Example:**
```sh
bb ls -n 50 "flutter/staging/Linux_android_emu android_hardware_smoke_opengles_tests"
```

### 2. Checking Builder Stability (Failures Query)
To determine if a builder is stable enough to be promoted out of bringup (meaning it can run in presubmit and block PR merge without introducing flakes), you need to check for both regular failures (`FAILURE`) and infrastructure failures (`INFRA_FAILURE`).

> [!WARNING]
> **Go Flag Overwrite Limitation**: Because the `bb` CLI is written in Go, passing the `-status` flag multiple times (e.g. `-status failure -status infra_failure`) does **NOT** append them; instead, the later occurrence completely overwrites the earlier one.

To query for both statuses safely, use one of the following methods:

#### Method A: Filter using grep (Recommended)
Query the recent builds with minimal fields and grep for failing statuses. This is the most reliable way to inspect the recent runs window:
```sh
bb ls -n <limit> -fields "id,status" "<project>/<bucket>/<builder>" | grep -E "FAILURE|INFRA_FAILURE"
```

#### Method B: Run separate queries
Run two distinct commands to verify each status separately:
```sh
bb ls -n <limit> -status failure "<project>/<bucket>/<builder>"
bb ls -n <limit> -status infra_failure "<project>/<bucket>/<builder>"
```

* **Interpreting Results**: If no matching builds are returned by these commands, the builder has a **100% success rate** over the queried limit.


### 3. Printing Clean Status Summaries
If you want to quickly see the status of all builds without dumping verbose build parameters, filter the fields:

```sh
bb ls -n <limit> -fields "id,status" "<project>/<bucket>/<builder>"
```
This prints list of URLs and their corresponding statuses (e.g. `SUCCESS` or `FAILURE`).


### 4. Querying Average Builder Execution Time
To calculate the average execution time of successful builds for a specific builder, query the recent builds with JSON output enabled:

```sh
bb ls -n <limit> -status success -json "<project>/<bucket>/<builder>"
```

From each JSON line output, parse `startTime` and `endTime` (e.g. `"2026-07-09T20:41:20.631059664Z"`), convert to `DateTime`, subtract start from end to get the duration, and calculate the average across all successfully analyzed builds.


### 5. Querying Build Step Durations / Breakdown
To inspect where time is spent during a build, fetch the build steps with JSON output enabled:

```sh
bb get -json -steps <BUILD_ID_OR_PATH>
```

From the JSON output, locate the `steps` array. For each step, parse and compare the `startTime` and `endTime` fields to compute the individual step durations. This is useful for identifying setup/teardown overhead versus actual test execution runtime.


### 6. Avoiding Console Output Truncation
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


### 7. Diagnosing Specific Build Failures
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

#### C. Analyzing Skia Gold Golden Mismatches
For graphics/golden image comparison failures, inspect the test stdout:
* **Gold Triaging URLs**: Search the logs for `https://flutter-gold.skia.org/detail?...` URLs. **You MUST extract and present these links directly in your final response/diagnosis to the user** so they can easily click and view the mismatched images in their browser.
* **Inspect Digest Size**: A very small PNG output size (e.g., ~1.4 KB compared to the typical 10 KB–20 KB) is a strong indicator of a completely blank or uniform (usually black) screenshot.
* **Identify System-Level Compositing Issues**: If multiple distinct test scenarios (e.g. different platform view composition modes) fail by producing the **exact same image digest**, this indicates a system-level rendering or compositing failure (such as an emulator GPU driver or Vulkan surface composition flake) rather than a code defect.



