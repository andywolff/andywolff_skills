---
name: pixel-diff-images
description: >-
  Use this skill when the user wants to compare two image files, crop regions
  of interest (ROI), calculate channel deltas, and generate visual difference heatmaps.
---

# Pixel Differential Image Analysis Guide

Use this skill when you need to programmatically compare two PNG images
(such as test goldens, screenshots, or local rendering artifacts), crop specific
regions of interest (ROI), measure pixel error percentages, and output a visual
diff heatmap.

---

## When to Use

* Verifying rendering fixes across Flutter/engine builds.
* Investigating golden file test failures without manual visual inspection.
* Isolating subtle rendering artifacts (such as edge antialiasing, clipping curves,
  or color shift) by cropping a specific sub-region.
* Note: This is a developer-facing diagnostics tool for local verification,
  investigation, and PR visual proof artifacts; it is not part of CI test runners.

---

## Running Differential Comparison

### Option A: Standalone CLI Runner (Recommended)

Fast, lightweight runner with no Flutter dependencies or compilation overhead:

```bash
python3 .agents/skills/pixel-diff-images/scripts/diff_images.py \
  --baseline /path/to/baseline.png \
  --candidate /path/to/candidate.png \
  --diff /path/to/diff_heatmap.png \
  --crop 0,0,100,100
```

### Option B: Flutter Test Runner

Run via `flutter test` within a Flutter package repository context:

```bash
flutter test \
  --dart-define=BASELINE_PNG=/path/to/baseline.png \
  --dart-define=CANDIDATE_PNG=/path/to/candidate.png \
  --dart-define=DIFF_PNG=/path/to/diff_heatmap.png \
  --dart-define=CROP_LTRB=0,0,100,100 \
  .agents/skills/pixel-diff-images/scripts/compare_images.dart
```

*(Note: In target repositories symlinked via `manage-personal-skills`, the directory path is `.agents/skills/personal-pixel-diff-images/...`)*

### Parameters:
* **`--baseline` / `BASELINE_PNG`** *(required)*: Absolute or relative path to the baseline reference image.
* **`--candidate` / `CANDIDATE_PNG`** *(required)*: Absolute or relative path to the candidate/new image to compare.
* **`--diff` / `DIFF_PNG`** *(optional)*: Output path to save the visual diff heatmap PNG.
* **`--crop` / `CROP_LTRB`** *(optional)*: Comma-separated Left, Top, Right, Bottom integer coordinates to crop a specific Region of Interest (e.g. `0,0,50,50`). If omitted, compares the full image. When crop coordinates and diff path are provided, the script automatically exports `${DIFF_PNG}_baseline_crop.png` and `${DIFF_PNG}_candidate_crop.png` alongside the diff heatmap.
* **`--threshold`** *(optional, CLI runner only)*: Maximum channel delta tolerance before marking a diff (default: 0).

---

## Output Metrics & Interpretation

The tool outputs the following structured diagnostics to stdout and asserts zero mismatched pixels:

```text
------------------------------------------------------------
Visual Diff Results:
  Region Size:       50x50 (2500 px)
  Mismatched Pixels: 0 / 2500 (0.00%)
  Max Channel Delta: 0
------------------------------------------------------------
```

* **Mismatched Pixels**: Count and percentage of pixels where any RGBA channel differs.
* **Max Channel Delta**: The largest color/alpha delta ($0..255$) across all evaluated pixels.
* **Diff Bounding Box**: Tightest rectangular bounding box enclosing all differing pixels.
* **Diff Heatmap (`DIFF_PNG`)**:
  * **Magenta (`#FF0080`)**: Highlighted pixels that differ between baseline and candidate.
  * **Dimmed Grayscale**: Matching background context for instant visual orientation.
* **Cropped Images**: When `CROP_LTRB` is set, isolated baseline and candidate crop PNGs are saved automatically for visual inspection.
