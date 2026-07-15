#!/bin/bash

# Exit on error
set -e

SKILLS_REPO_ROOT="/Users/awolff/Projects/andywolff/andywolff_skills"
PARENT_DIR="/Users/awolff/Projects/andywolff"

# Parse optional parameter or auto-detect all worktrees
TARGET_REPOS=()
if [ -n "$1" ]; then
  TARGET_REPOS+=("$1")
else
  for d in "$PARENT_DIR"/flutter*; do
    if [ -d "$d" ]; then
      TARGET_REPOS+=("$d")
    fi
  done
fi

# Resolve list of source directories containing skills
SOURCES=()
if [ -f "$SKILLS_REPO_ROOT/skills_sources.txt" ]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    if [[ -n "$line" && ! "$line" =~ ^# ]]; then
      trimmed=$(echo "$line" | xargs)
      if [ -d "$trimmed" ]; then
        SOURCES+=("$trimmed")
      else
        echo "Warning: Configured source directory not found: $trimmed"
      fi
    fi
  done < "$SKILLS_REPO_ROOT/skills_sources.txt"
else
  DEFAULT_DIR="$SKILLS_REPO_ROOT/.agents/skills"
  if [ -d "$DEFAULT_DIR" ]; then
    SOURCES+=("$DEFAULT_DIR")
  fi
fi

if [ ${#SOURCES[@]} -eq 0 ]; then
  echo "Error: No valid source directories found."
  exit 1
fi

for TARGET_REPO in "${TARGET_REPOS[@]}"; do
  # Resolve absolute path of TARGET_REPO
  TARGET_REPO_ABS=$(cd "$TARGET_REPO" && pwd -P)
  SKILLS_REPO_ROOT_ABS=$(cd "$SKILLS_REPO_ROOT" && pwd -P)

  if [ "$TARGET_REPO_ABS" = "$SKILLS_REPO_ROOT_ABS" ]; then
    echo "Skipping $TARGET_REPO (cannot symlink skills to the central skills repository itself)"
    continue
  fi

  FLUTTER_DIR="$TARGET_REPO/.agents/skills"
  
  # Check if target repository has .agents/skills directory
  if [ ! -d "$FLUTTER_DIR" ]; then
    echo "Skipping $TARGET_REPO (no .agents/skills folder)"
    continue
  fi
  
  for SOURCE_DIR in "${SOURCES[@]}"; do
    # Skip if source directory is identical to target directory to avoid self-linking
    SOURCE_DIR_ABS=$(cd "$SOURCE_DIR" && pwd -P)
    FLUTTER_DIR_ABS=$(cd "$FLUTTER_DIR" && pwd -P)
    if [ "$SOURCE_DIR_ABS" = "$FLUTTER_DIR_ABS" ]; then
      echo "Skipping source directory $SOURCE_DIR (source matches target directory)"
      continue
    fi
    echo ""
    echo "🔗 Symlinking skills from $SOURCE_DIR to $FLUTTER_DIR..."
    
    # Loop through each directory in SOURCE_DIR
    for skill_path in "$SOURCE_DIR"/*; do
      if [ -d "$skill_path" ]; then
        skill_name=$(basename "$skill_path")
        symlink_path="$FLUTTER_DIR/personal-$skill_name"
        
        echo "  - Creating symlink for: personal-$skill_name"
        ln -sf "$skill_path" "$symlink_path"
      fi
    done
  done
  
  echo "🔗 Symlinking worklog.md, AGENTS.md, and rules to $TARGET_REPO..."
  
  # Symlink worklog.md
  if [ -f "$SKILLS_REPO_ROOT/worklog.md" ]; then
    echo "  - Creating symlink for: worklog.md"
    ln -sf "$SKILLS_REPO_ROOT/worklog.md" "$TARGET_REPO/worklog.md"
  fi
  
  # Symlink .agents/AGENTS.md
  if [ -f "$SKILLS_REPO_ROOT/.agents/AGENTS.md" ]; then
    echo "  - Creating symlink for: .agents/AGENTS.md"
    mkdir -p "$TARGET_REPO/.agents"
    ln -sf "$SKILLS_REPO_ROOT/.agents/AGENTS.md" "$TARGET_REPO/.agents/AGENTS.md"
  fi

  # Symlink communication.md rule
  if [ -f "$SKILLS_REPO_ROOT/communication.md" ]; then
    echo "  - Creating symlink for: .agents/rules/communication.md"
    mkdir -p "$TARGET_REPO/.agents/rules"
    ln -sf "$SKILLS_REPO_ROOT/communication.md" "$TARGET_REPO/.agents/rules/communication.md"
  fi
  
  # Configure Git local exclusions
  if [ -e "$TARGET_REPO/.git" ]; then
    GIT_COMMON_RELATIVE=$(git -C "$TARGET_REPO" rev-parse --git-common-dir)
    if [[ "$GIT_COMMON_RELATIVE" != /* ]]; then
      GIT_COMMON_DIR="$TARGET_REPO/$GIT_COMMON_RELATIVE"
    else
      GIT_COMMON_DIR="$GIT_COMMON_RELATIVE"
    fi
    EXCLUDE_FILE="$GIT_COMMON_DIR/info/exclude"
    
    echo "⚙️ Configuring local Git exclusions in $EXCLUDE_FILE..."
    mkdir -p "$(dirname "$EXCLUDE_FILE")"
    
    if ! grep -q "/worklog.md" "$EXCLUDE_FILE"; then
      echo "/worklog.md" >> "$EXCLUDE_FILE"
    fi
    
    if ! grep -q "/.agents/AGENTS.md" "$EXCLUDE_FILE"; then
      echo "/.agents/AGENTS.md" >> "$EXCLUDE_FILE"
    fi

    if ! grep -q "/.agents/rules/communication.md" "$EXCLUDE_FILE"; then
      echo "/.agents/rules/communication.md" >> "$EXCLUDE_FILE"
    fi
  fi
done

echo ""
echo "✨ Done setting up worklogs, skills, and rules across all repositories!"

