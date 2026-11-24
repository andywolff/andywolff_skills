---
name: flutter-engine-build
description: >-
  Use this skill whenever running Flutter engine builds (et build, ninja) or
  gclient sync across parallel worktrees. Enforces a 40 GB free disk space
  floor via two-tier LRU eviction (engine/src/out then in-place gclient
  dehydration), protects hard-active workspaces (1-hour idle window), handles
  automatic rehydration with eviction notices, and supports lease release and
  cross-session handoff. Don't use for framework-only flutter test runs, pure
  Git branch operations, or general OS disk cleanup outside Flutter worktrees.
---

# Flutter Engine Build & Space Manager

Use `engine_build.dart` as the single entry point for `et build`, `ninja`, and
`gclient sync` so disk usage stays safely above the 40 GB free-space floor
without disrupting an actively used worktree.

## 1. Check Machine Status

Inspect free space, worktree hydration state (`HYDRATED` vs `DEHYDRATED`),
session leases (`HARD_ACTIVE`, `SOFT_ACTIVE`, `RELEASED`, `INACTIVE`), and
queued space waiters:

```sh
dart .agents/skills/flutter-engine-build/scripts/engine_build.dart --status

# Machine-readable JSON output:
dart .agents/skills/flutter-engine-build/scripts/engine_build.dart --status --json
```

## 2. Run Engine Builds Through the Admission Gate

Wrap `et build`, `ninja`, or `gclient sync` with `--`:

```sh
dart .agents/skills/flutter-engine-build/scripts/engine_build.dart \
  --workspace my-branch \
  --session-id <session-id> \
  -- et build -c host_debug_unopt
```

Before starting the build, `engine_build.dart` automatically:
1. Checks `<gitdir>/eviction_state.json` and notifies you if the worktree was
   dehydrated or had `engine/src/out` evicted since your last turn.
2. Rehydrates dehydrated worktrees automatically with `gclient sync -D` (pass
   `--no-rehydrate` to fail fast instead).
3. Enforces the **40 GB free disk floor** (plus 10 GB build headroom or 25 GB
   rehydration headroom) by evicting other worktrees in LRU order:
   - Tier 1a: Engine snapshots (`*_baseline`, `*_patched`) in non-hard-active worktrees.
   - Tier 1b: `engine/src/out/*` in `RELEASED` or `INACTIVE` worktrees.
   - Tier 2: In-place dehydration of `RELEASED` or `INACTIVE` worktrees (removes
     only untracked `.gclient_entries` paths verified via `git ls-files`, plus
     `engine/src/out`, while preserving `.gclient`, commits, and dirty files).
   - Tier 3: `engine/src/out/*` in `SOFT_ACTIVE` worktrees (idle > 1 hour).
4. Refuses to evict any `HARD_ACTIVE` worktree (live build PID or heartbeat
   within the last 60 minutes).

## 3. Release Leases Proactively (Own Worktree Only)

> [!CAUTION]
> **Lease Ownership Invariant:**
> NEVER run `--release`, `--dehydrate`, `--force`, or destructive cleanup on
> any worktree that you did not create or lease in the current session, and
> NEVER offer to release another session's workspace to free disk space. Only
> the owning session may release its own lease. Always pass `--session-id`
> when releasing or dehydrating your own worktree; `engine_build.dart` and the
> `PreToolUse` hook enforce ownership and reject foreign-lease mutations.

As soon as your build/test pass finishes (or a PR is pushed for review), release
your own worktree's lease so it stays cached while space is plentiful but becomes
immediately evictable if another session needs space:

```sh
dart .agents/skills/flutter-engine-build/scripts/engine_build.dart \
  --release --workspace my-branch --session-id <session-id> --notify-waiters
```

## 4. Coordinate When Blocked by Hard-Active Workspaces

If all available space is held by `HARD_ACTIVE` worktrees owned by other
sessions, `engine_build.dart` exits with code `2` and lists the blocking
worktrees and their owning session IDs. Do NOT attempt or offer to release or
dehydrate those workspaces. Your only valid responses are to wait/request
handoff via `--wait --request-handoff`, wait for an owning session to finish,
or report the blocking worktrees and session IDs to the user so they can decide
which other session to wind down:

```sh
dart .agents/skills/flutter-engine-build/scripts/engine_build.dart \
  --workspace my-branch \
  --session-id <session-id> \
  --wait --request-handoff \
  -- et build -c host_debug_unopt
```

Cross-session notifications use the optional `AGENT_NOTIFY_CMD` environment
variable (or `--notify-cmd <cmd>`), invoked as `<cmd> "<target-session-id>" "<message>"`.
When unset, handoff requests are logged without calling an external binary.

## 5. Manual In-Place Dehydration (Own Worktree Only)

To shrink your own worktree down to ~470 MB immediately while preserving its
branch and uncommitted edits:

```sh
dart .agents/skills/flutter-engine-build/scripts/engine_build.dart \
  --dehydrate --workspace my-branch --session-id <session-id>
```

## 6. Automatic Session Tracking Hook (Compiled Dart)

Compile [session_hook.dart](scripts/session_hook.dart) to a native binary once
for ~10-20 ms hook execution:

```sh
mkdir -p ~/.cache/flutter_engine_build
dart compile exe \
  .agents/skills/flutter-engine-build/scripts/session_hook.dart \
  -o ~/.cache/flutter_engine_build/session_hook
```

Then merge [hooks.json.example](hooks.json.example) into your agent's
`hooks.json` configuration. The hook runs on `PreInvocation` (surfacing
dehydration notices without interfering with tool permissions), `PreToolUse`
(blocking `--release`, `--dehydrate`, or destructive cleanup against worktrees
actively leased by another session, and blocking raw `ninja`/`et build` on
dehydrated worktrees), `PostToolUse` (stamping `<gitdir>/agent_session.json`
without stealing foreign active leases or claiming on read-only commands), and
`Stop` (flipping `busy` to `idle` and optionally notifying queued waiters via
`AGENT_NOTIFY_CMD`).

## 7. Verification

Preview the admission gate without deleting files, analyze the scripts, or run
the unit test suite:

```sh
# Dry-run eviction preview:
dart .agents/skills/flutter-engine-build/scripts/engine_build.dart \
  --workspace my-branch --dry-run -- et build -c host_debug_unopt

# Static analysis and unit tests:
dart analyze .agents/skills/flutter-engine-build/scripts/
dart .agents/skills/flutter-engine-build/scripts/test/flutter_engine_build_test.dart
```
