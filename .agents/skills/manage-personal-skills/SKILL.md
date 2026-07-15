---
name: manage-personal-skills
description: Guide and automate the creation, symlinking, and management of personal agent skills across workspaces and worktrees.
---

# Manage Personal Skills

Use this skill whenever you need to define, scaffold, or install a new custom/personal agent skill, or sync/symlink existing skills into a workspace or new Git worktree.

This skill ensures all custom developer-defined skills are placed in the central skills repository (`andywolff_skills`) and correctly symlinked into target repository worktrees (like `flutter`) with a `personal-` prefix.

## 1. Creating a New Skill

To define and scaffold a new custom skill:

```sh
dart .agents/skills/personal-manage-personal-skills/scripts/create_skill.dart \
  --name "my-new-skill" \
  --description "A brief human-readable description of what this skill does."
```

### Required Arguments:
* **`--name <skill-name>`**: The kebab-case name of the new skill (e.g. `check-android-logs`).
* **`--description <description>`**: A brief summary of when the agent should use this skill.

---

## 2. Symlinking All Skills (e.g. into a New Worktree)

When checking out a new Git worktree, local untracked symlinks in `.agents/skills/` (pointing to `andywolff_skills` or `kevmoo_skills`) are not automatically created.

To symlink (or re-symlink) all existing skills into a target repository worktree, run:

```sh
.agents/skills/personal-manage-personal-skills/scripts/symlink_all.sh [target_repo_path]
```

* `[target_repo_path]` is optional and defaults to `/Users/awolff/Projects/andywolff/flutter`.

---

## 3. Linking External Skills Directories

If you want to use existing skills from an external repository (such as `kevmoo_skills`) without copying them, create a symbolic link directly in `.agents/skills/` using the `personal-` prefix:

```sh
ln -s /path/to/external_skills/skills/some-skill .agents/skills/personal-some-skill
```
