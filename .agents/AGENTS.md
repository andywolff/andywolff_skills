# Project Customization Rules

## Ongoing Agent Worklog
* **Read**: Read the project worklog file at the workspace root `worklog.md` during the planning phase of any task. Use it to recall previous insights, solutions, and user course-corrections.
* **Update**: Before declaring any task completed, append new interesting insights, user course-corrections, or complex workflows solved during the session to the workspace root `worklog.md` file. Keep updates concise.

## Authentication & Tooling Blockers
* **Authentication Failures Are Hard Stops**: If any command, sync operation, or build tool (`gclient`, `et`, CIPD, `git`, `gh`, `bb`) fails due to missing or expired credentials (e.g., prompting for `gcert`, OAuth, or SSO):
  1. **Stop immediately**: Do NOT attempt any workaround.
  2. **Never switch branches or worktrees**: Never check out another branch, worktree, or existing engine build to avoid an authentication error.
  3. **Ask the user**: Quote the authentication error and prompt the user to run the required auth command (e.g., `gcert`).
