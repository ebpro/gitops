# Project OpenCode Configuration

Team-shared OpenCode configuration for this GitOps platform. Definition
files are version-controlled; local state is not.

## Tracked (committed)
- `agents/` — project subagents (cnpg-admin, gitops-debug, kyverno-auditor,
  platform-provisioner, sso-architect, vault-admin). Each file has YAML
  frontmatter (`description`, `mode`, `model`, `steps`, `temperature`,
  `top_p`, `permission`) followed by the role body.
- `skills/` — one directory per skill; `SKILL.md` requires `name`
  (matching the directory name) and `description` frontmatter.
- `.gitignore` — keeps local state out of git.

## Ignored (local only — never commit)
- `memory/`, `sessions/`, `PROJECT-STATE.md`, `STATUSES` — session state;
  may contain secrets.
- `index/`, `codebase-index.json` — semantic index cache.
- `node_modules/`, `package*.json`, `bun.lock` — plugin runtime.

## Conventions
- Global config lives in `~/.config/opencode/`; the project layer has the
  highest standard precedence and overrides it where set.
- Project agents: `mode: subagent`, model `ouranos1/qwen3.8-27b`,
  `webfetch: deny`, and no `task:` permission (only the lead orchestrates).
- Permission values: `allow` | `ask` | `deny`; `bash` may use pattern maps
  (most-specific first, `*` last).
- Golden rules (root `AGENTS.md`): git-push only — never patch live
  cluster resources. Enforced here via `kubectl apply/patch/edit` denies.
