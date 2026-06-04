---
name: create-personal-skill
description: Guide and automate the creation of new personal agent skills, maintaining the repository placement and symlinking conventions.
---

# Create Personal Skill

Use this skill whenever you need to define, scaffold, or install a new custom/personal agent skill for this workspace.

This skill ensures all custom developer-defined skills are placed in the central skills repository (`andywolff_skills`) and correctly symlinked into the `flutter` repository with a `personal-` prefix.

## Usage

Run the automated Dart creation script from the `flutter` root directory:

```sh
dart .agents/skills/personal-create-personal-skill/scripts/create_skill.dart \
  --name "my-new-skill" \
  --description "A brief human-readable description of what this skill does."
```

### Required Arguments:
* **`--name <skill-name>`**: The kebab-case name of the new skill (e.g. `check-android-logs`).
* **`--description <description>`**: A brief summary of when the agent should use this skill.
