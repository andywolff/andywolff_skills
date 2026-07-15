---
name: git-worktree-management
description: Identify merged or fresh git worktrees and clean them up safely.
---

# Git Worktree Management

Use this skill to determine which active Git worktrees can be cleaned up because they have been merged upstream, and how to safely remove them.

## 1. List Active Worktrees

List all active worktrees to find sibling directories and their associated branches:
```sh
git worktree list
```

## 2. Check Merged Status

For each non-main branch checked out in a worktree, check if it has been merged upstream (`upstream/main` or `upstream/master`):

1. **Direct Merge Check**:
   Check if the branch is a direct ancestor of upstream:
   ```sh
   git merge-base --is-ancestor <branch-name> upstream/main
   ```
   If this exit code is `0`, the branch is fully merged.

2. **Patch-Equivalent (Squash Merge) Check**:
   If the branch is not a direct ancestor, check if the commits have been squashed and merged under different commit hashes:
   ```sh
   git cherry upstream/main <branch-name>
   ```
   - Commits prefixed with `-` are already present upstream.
   - Commits prefixed with `+` are not present upstream.
   If all commits are prefixed with `-`, the changes are fully merged.

   > [!NOTE]
   > `git cherry` may report `+` (not merged) even if the changes *are* merged upstream, if the local branch was never rebased to include overlapping/conflicting changes from another parallel branch that has also merged.
   > If this occurs:
   > 1. Search the upstream/master commit log (e.g., using `git log upstream/main --grep="PR-number-or-title"`) to confirm the PR was merged.
   > 2. Determine which files were modified on the branch: `git diff --name-only upstream/main...<branch-name>`.
   > 3. Diff only those files against master: `git diff upstream/main <branch-name> -- <changed-files>`. If the diff is empty or only contains changes introduced by other merged PRs, the branch has been successfully merged.

3. **Identify New/Fresh Branches**:
   If a branch has no commits ahead of upstream (`git log upstream/main..<branch-name> --oneline` is empty), it is identical to upstream.
   > [!IMPORTANT]
   > A branch identical to `upstream/main` with zero commits ahead may be a newly created branch for upcoming work rather than a merged branch. Always verify with the user or check the branch's reflog before cleaning it up.

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

3. **Delete the Local Branch**:
   If the branch is fully merged and no longer needed:
   ```sh
   git branch -D <branch-name>
   ```

## 4. Creating a New Worktree & Symlinking Skills

When switching branches or running multiple agents concurrently, use Git worktrees to prevent concurrent access conflicts. Each active branch/agent runs in its own dedicated worktree sibling directory.

### Symlinked Skills Setup

When checking out a new git worktree, local untracked symlinks in `.agents/skills/` (pointing to `andywolff_skills` or `kevmoo_skills`) are not automatically created in the new worktree directory. 

To resolve this, run the symlinking script from the `personal-manage-personal-skills` skill:
```sh
.agents/skills/personal-manage-personal-skills/scripts/symlink_all.sh <worktree-path>
```
For more details, see the [manage-personal-skills](file:///Users/awolff/Projects/andywolff/andywolff_skills/.agents/skills/manage-personal-skills) skill.
