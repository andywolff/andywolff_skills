---
name: git-worktree-management
description: >-
  Use this skill when the user wants to create, analyze, clean up, or manage
  Git worktrees (including symlinking skills and bootstrapping gclient).
---

# Git Worktree Management

Use this skill to create, configure, analyze, and safely remove Git worktrees,
including symlinking agent skills and bootstrapping gclient.

## 0. Automated Worktree Analysis

You can execute the built-in Dart script to automatically evaluate all active
worktrees, including their branch names, merge status (detecting both
direct and squash/patch merges), dirty/clean files count, and pull request
status (via the `gh` CLI):

```sh
dart .agents/skills/personal-git-worktree-management/scripts/check_worktrees.dart
```

## 1. List Active Worktrees

List all active worktrees to find sibling directories and their associated
branches:
```sh
git worktree list
```

## 2. Check Merged Status

For each non-main branch checked out in a worktree, check if it has been
merged upstream (`upstream/master`):

1. **Direct Merge Check**:
   Check if the branch is a direct ancestor of upstream:
   ```sh
   git merge-base --is-ancestor <branch-name> upstream/master
   ```
   If this exit code is `0`, the branch is fully merged.

2. **Patch-Equivalent (Squash Merge) Check**:
   If the branch is not a direct ancestor, check if the commits have been
   squashed and merged under different commit hashes:
   ```sh
   git cherry upstream/master <branch-name>
   ```
   - Commits prefixed with `-` are already present upstream.
   - Commits prefixed with `+` are not present upstream.
   If all commits are prefixed with `-`, the changes are fully merged.

   > [!NOTE]
   > `git cherry` may report `+` (not merged) even if the changes *are* merged
   > upstream, if the local branch was never rebased to include overlapping/
   > conflicting changes from another parallel branch that has also merged.
   > If this occurs:
   > 1. Search the upstream/master commit log (e.g., using
   >    `git log upstream/master --grep="PR-number-or-title"`) to confirm the
   >    PR was merged.
   > 2. Determine which files were modified on the branch:
   >    `git diff --name-only upstream/master...<branch-name>`.
   > 3. Diff only those files against master:
   >    `git diff upstream/master <branch-name> -- <changed-files>`.
   >    If the diff is empty or only contains changes introduced by other
   >    merged PRs, the branch has been successfully merged.

3. **Identify New/Fresh Branches**:
   If a branch has no commits ahead of upstream
   (`git log upstream/master..<branch-name> --oneline` is empty), it is
   identical to upstream.
   > [!IMPORTANT]
   > A branch identical to `upstream/master` with zero commits ahead may be a
   > newly created branch for upcoming work rather than a merged branch.
   > Always verify with the user or check the branch's reflog before
   > cleaning it up.

## 3. Safe Removal

To clean up a worktree:

1. **Check Status**:
   Verify there are no uncommitted or modified tracked files in the worktree:
   ```sh
   git -C <worktree-path> status --short
   ```

2. **Remove the Worktree**:
   ```sh
   git worktree remove <worktree-path>
   ```

3. **Prune Deleted Worktrees**:
   If you manually deleted any worktree directories without using git commands,
   prune their metadata:
   ```sh
   git worktree prune
   ```

4. **Delete the Local Branch**:
   If the branch is fully merged and no longer needed:
   ```sh
   git branch -D <branch-name>
   ```

## 4. Creating a New Worktree & Symlinking Skills

When switching branches or running multiple agents concurrently, use Git
worktrees to prevent concurrent access conflicts. Each active branch/agent runs
in its own dedicated worktree sibling directory.

### Naming Preference
* **Naming**: The checkout worktree directory name should match the Git branch
  name (e.g., branch `my-feature` should be checked out in a directory named
  `my-feature` under the project sibling folder). This makes it easy to
  associate/map directories to active branches.

### Symlinked Skills Setup

When checking out a new git worktree, local untracked symlinks in
`.agents/skills/` (pointing to `andywolff_skills` or `kevmoo_skills`) are
not automatically created in the new worktree directory. 

To resolve this, run the symlinking script from the
`personal-manage-personal-skills` skill:
```sh
.agents/skills/personal-manage-personal-skills/scripts/symlink_all.sh <worktree-path>
```
For more details, see the [manage-personal-skills](file:///Users/awolff/Projects/andywolff/andywolff_skills/.agents/skills/manage-personal-skills) skill.

## 5. Bootstrapping gclient in a Worktree

When using Git worktrees for engine/framework development, the `.gclient`
configuration file must be present at the root of the new worktree directory
to ensure `gclient` can locate the solution root.

- If a `.gclient` file exists in the master or sibling checkout, copy it
  to the root of the new worktree.
- If no `.gclient` file is available, refer to the official
  [Setting up the Engine development environment](https://github.com/flutter/flutter/wiki/Setting-up-the-Engine-development-environment#getting-the-source)
  guide on the Flutter Wiki for how to configure and bootstrap `gclient`.
