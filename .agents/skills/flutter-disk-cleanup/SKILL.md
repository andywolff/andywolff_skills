---
name: flutter-disk-cleanup
description: >-
  Use this skill when the user encounters low disk space warnings or wants to
  audit and clean up Flutter engine builds, framework integration test builds,
  snapshot variants, and developer caches across multiple worktrees.
---

# Flutter Disk Cleanup

Use this skill to diagnose disk exhaustion and safely reclaim space across
parallel Flutter worktrees, local engine output directories, framework test
builds, and developer tool caches.

## 1. Run a Read-Only Disk Audit

Execute `audit_disk.dart` with no cleanup flags to generate a categorized report
of reclaimable disk usage across sibling workspaces and global caches:

```sh
# From central skills repository:
dart .agents/skills/flutter-disk-cleanup/scripts/audit_disk.dart

# Or from a target Flutter worktree:
dart .agents/skills/personal-flutter-disk-cleanup/scripts/audit_disk.dart
```

The script automatically:
- Reports free and used capacity on `/System/Volumes/Data` (or `/`).
- Measures `engine/src/out/*` targets across all sibling workspaces and flags
  snapshot copies (`[SNAPSHOT]`) and active Jetski agent workspaces
  (`[ACTIVE SESSION]`).
- Totals `build/` directories (>= 10 MiB) inside `dev/integration_tests`,
  `dev/benchmarks`, and `examples`.
- Checks developer caches (`vscode-cpptools`, `Xcode iOS DeviceSupport`,
  `Xcode DerivedData`, `~/.dartServer`, and `~/.gradle`) plus informational
  footprints like `~/.android/avd`.

For machine-readable output, pass `--json`.

---

## 2. Reclaim Space Safely

Always confirm destructive cleanup targets with the user before deleting
directories, unless the user explicitly requested deletion.

> [!IMPORTANT]
> **Active Session Protection:**
> By default, `audit_disk.dart` skips cleaning `engine/src/out` and framework
> `build/` directories in workspaces that have an active Jetski agent session
> locked. Only pass `--include-active` if the user explicitly wants to clean an
> active workspace.

### Targeted Cleanup Flags

```sh
# Remove only engine snapshot variants (*_baseline, *_patched):
dart .agents/skills/personal-flutter-disk-cleanup/scripts/audit_disk.dart \
  --clean-snapshots

# Remove engine/src/out/* builds across inactive workspaces:
dart .agents/skills/personal-flutter-disk-cleanup/scripts/audit_disk.dart \
  --clean-engine-out

# Scope cleanup to a single named workspace:
dart .agents/skills/personal-flutter-disk-cleanup/scripts/audit_disk.dart \
  --workspace sqfix --clean-engine-out

# Remove dev/integration_tests, dev/benchmarks, and examples build/ folders:
dart .agents/skills/personal-flutter-disk-cleanup/scripts/audit_disk.dart \
  --clean-framework-builds

# Clear regenerable IDE/Xcode/Dart caches (vscode-cpptools, DeviceSupport, etc.):
dart .agents/skills/personal-flutter-disk-cleanup/scripts/audit_disk.dart \
  --clean-caches

# Clear ~/.gradle/caches and ~/.gradle/wrapper (requires network to re-fetch):
dart .agents/skills/personal-flutter-disk-cleanup/scripts/audit_disk.dart \
  --clean-gradle
```

---

## 3. Retiring Merged Worktrees

Clearing `engine/src/out` leaves the ~26 GB synced `engine/src` tree on disk.
If a worktree's PR has already landed and is no longer needed, retire the entire
worktree using the [git-worktree-management](../git-worktree-management/SKILL.md)
skill:

```sh
dart .agents/skills/personal-git-worktree-management/scripts/check_worktrees.dart
```
