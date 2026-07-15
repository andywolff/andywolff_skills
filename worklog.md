# Global Agent Worklog

Records broadly applicable insights, design patterns, and engineering guidelines discovered across workspaces. Document project-specific details directly in commit messages or PR descriptions instead.

* **Organization**: Group items under their domain headings (`###`) and separate with `---`. Update the **Quick Reference Checklist** to match any changes.
* **Skills vs. Worklog**: Use this worklog for design rules, caching rules, and pitfalls. Use **Personal Skills** (managed/updated via `manage-personal-skills`) for step-by-step procedures or scripts, placing only a brief link and summary here.

## Quick Reference Checklist
- [ ] **JNI API Design**: Retain legacy JNI/embedder method signatures as fallbacks to avoid breaking Mockito unit test stubs.
- [ ] **Platform Views Testing**: Always synchronize screenshots by awaiting a native draw event (e.g., overriding `onDraw(Canvas)`) rather than a simple frame-delay loop.
- [ ] **Workspace Isolation**: Use Git worktrees when running concurrent agents; copy untracked `.agents/skills/personal-*` symlinks to new worktrees.
- [ ] **CLI Outputs**: Redirect verbose command outputs (e.g. log queries) to a file to prevent console truncation.
- [ ] **Asynchronous Monitoring**: Prefer blocking watch/wait commands over polling loops for background tasks, or justify why polling is necessary.
- [ ] **Warning & Lint Suppression**: Prioritize resolving compiler/linter warnings at code level; obtain confirmation before using suppression annotations (e.g. `@Suppress`, ignores).
- [ ] **Gradle Commands workingDirectory**: Run `./gradlew` (or `gradlew.bat`) commands with `workingDirectory` set to the `android/` subdirectory where `settings.gradle` resides, using an absolute path to the executable.

---

## Android Embedder & Graphics Engine

### API Design & Mock Compatibility
* **Rule**: When changing native embedder (JNI/Obj-C) signatures, retain legacy signatures as fallbacks.
* **Rationale**: Modifying signatures breaks existing unit test mock stubs (like Mockito) and downstream plugin dependencies that rely on the legacy signature.

---

## Android Testing & Verification

### Local Engine Gradle Resolution & Validation
Detailed instructions for running Android instrumented tests with a local engine build have been promoted to the personal skill: [run-android-instrumented-tests-local-engine](file:///Users/awolff/Projects/andywolff/andywolff_skills/.agents/skills/run-android-instrumented-tests-local-engine).

---

### Gradle Execution Path Resolution
* **Rule**: When running `./gradlew` programmatically:
  - Always set the working directory to the `android/` subdirectory (containing `settings.gradle`), NOT the Flutter package root, to prevent Gradle from aborting with `does not contain a Gradle build`.
  - Resolve the `./gradlew` executable path absolutely to prevent path mismatches relative to the working directory.

---

### Local Golden Test Validation
* **Rule**: To validate golden comparisons locally without Skia Gold, first generate reference baseline images in `test_driver/goldens/` by running `flutter drive` with `UPDATE_GOLDENS=true`, or the subsequent instrumented APK will fail to find and load comparator reference images.

---

### Google Play Protect ADB Verification Timeout
* **Rule**: If local ADB test installs fail with `INSTALL_FAILED_VERIFICATION_FAILURE: Verification timed out`, temporarily disable the package verifier:
  ```sh
  adb shell settings put global package_verifier_enable 0
  ```

---

### Testing Platform Views: Native Draw Synchronization
* **Best Practice**: When writing platform view integration/smoke tests, avoid using a simple frame-delay loop (`WidgetsBinding.instance.endOfFrame`) before screenshots as they are highly susceptible to race conditions (blank/black overlays). Instead, await a native draw event dispatched from the native view itself (e.g., by subclassing the native view and overriding `onDraw(Canvas)`).
* **Reference**: See the synchronized text view implementation in `android_hardware_smoke_test` (introduced in PR #189151).
* **Timeout Rule**: Never add localized/arbitrary timeouts (e.g., `future.timeout()`) to asynchronous test futures; let the global test/JUnit runner timeouts handle hangs (see [Style-guide-for-Flutter-repo.md](file:///Users/awolff/Projects/andywolff/flutter-sync_composition/docs/contributing/Style-guide-for-Flutter-repo.md#L876-L886)).

---

### EGL Config Prevention
* **Rule**: Explicitly set the window pixel format to `PixelFormat.RGBA_8888` in `MainActivity.onCreate` to prevent the OS from attempting to negotiate 10-bit wide-gamut formats (`101010-2`) that are unsupported or flaky on SwiftShader CPU-based graphics drivers. This is safe and does not reduce intended test coverage, as standard Android devices default to sRGB (`RGBA_8888`) and dedicated Display P3/wide gamut rendering coverage is verified by the `wide_gamut_test` suite instead.

---

## Git & Workspace Management

### Git Worktree Management
* **Preference**: Use Git worktrees when switching branches to prevent concurrent access conflicts.
* **Guidelines**: Refer to [git-worktree-management](file:///Users/awolff/Projects/andywolff/andywolff_skills/.agents/skills/git-worktree-management) for procedures on symlinking skills, checking merge status, and safely removing worktrees.

---

## CI & CLI Tools

### Engine Compilation with `et`
* **Engine Tool (`et`)**: Use the engine tool (`engine/src/flutter/bin/et`) to compile and build targets (e.g., `et build -c android_debug_unopt_arm64`). It automatically generates build files and handles target configurations, environment variables, and toolchains cleaner than raw GN and Ninja commands.

---

### Asynchronous Monitoring: Watch Mode over Polling
* **Rule**: When monitoring the status of any background process, PR build, or external resource, always prefer using a blocking "watch" mode (e.g., `gh pr checks <pr> --watch`, wait commands, or event-based listeners) in a background task over periodic polling loops.
* **Exceptions**: If polling is used, you must explicitly document the justification (e.g., watch mode is unsupported by the tool, or the resource lacks streamable event APIs).

---

### Querying LUCI Build History & Offline Validation
* **Build History Queries**: See [query-luci-build-history](file:///Users/awolff/Projects/andywolff/andywolff_skills/.agents/skills/query-luci-build-history) for builder stability and step duration checks.
* **Offline `.ci.yaml` Validation**: Run validation tests offline to bypass restricted CI network sandboxing:
  ```sh
  dart pub get --offline
  dart test dev/bots/test/ci_yaml_validation_test.dart
  ```

---

### Handling Verbose CLI Outputs
* **Pitfall**: Large CLI outputs (e.g., `git log`, `bb ls`) can exceed console limits and get truncated at the top, leading to silent omission of critical logs.
* **Mitigations**:
  - Request compact outputs (e.g., `git log -n 10` or filtering fields).
  - Redirect verbose output to a file and read it incrementally using `view_file` to prevent console truncation.

---

## Agent Guidelines & Steering

### Course Corrections & General Steering
* **Local-only `.gitignore`**: The agent assumed `android/.gitignore` was a tracked version-controlled file. The user corrected this, noting that it is generated/regenerated locally by `flutter create` and should not be committed. The README instructions were corrected to suggest adding the maven repo path locally.
* **PR Scope Isolation**: The agent initially included previous branch work (the Vulkan engine caching workaround) in the PR description draft. The user steered the agent to focus the description strictly on the current branch's dynamic backend override and parameterization changes.
* **Isolated Unit Test Execution**: When verifying a single new unit test, the agent initially attempted to run the full Robolectric test suite of 1,300+ tests. The user intervened to recommend running only the newly added test case directly via the Gradle task runner (`--tests`), saving significant time.
* **Reading Test Prerequisites**: When attempting to run tests in a specific directory (such as `android_hardware_smoke_test`), always read the local `README.md` or documentation first to verify any required setup or prerequisites (e.g. generating baseline images, restoring platform wrappers), rather than executing test commands directly.
* **Workspace File Output Preference**: When generating text files intended for copying and pasting (such as proposed review comment replies or other multiline blocks), write them directly to the workspace root directory (e.g. as a workspace file) rather than just as a private agent artifact or raw console block. This allows the user to easily open and copy them from the VS Code source control panel.
* **Warning & Lint Suppression**: Do not suppress compiler, linter, or static analyzer warnings (e.g. Kotlin unchecked casts, Dart lints) without first attempting to resolve them at a code level. Always ask the user for confirmation before using suppression annotations (like `@Suppress` or inline lint ignores).
* **Commit & PR Message Styles**: Keep proposed commit messages relatively short, high-level, and completely free of links/URLs. Detailed explanations and links to issue trackers/references are preferred in PR descriptions instead.
* **Safe Force Pushing**: Never recommend using `git push -f` or `git push --force`. Instead, always recommend using `git push --force-with-lease` to prevent overwriting other developers' remote changes.
* **PR Comment Simplification**: When writing PR comments with build performance tables, keep tables intact but keep surrounding explanations extremely simple, direct, and free of subheadings or bulleted notes, integrating any VM variance disclaimers naturally within the prose.
* **Triage Uncommitted Check**: When resolving comments, always verify code changes are committed and pushed before proposing to post responses or resolve threads on GitHub, to keep the remote branch in sync with review comments.

