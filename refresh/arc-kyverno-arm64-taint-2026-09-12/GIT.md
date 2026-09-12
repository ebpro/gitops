# Git preservation

## What was saved and where
- This handoff package is preserved on a **dedicated, non-main branch** of the GitOps repo so
  ArgoCD never reconciles it:
  - branch: `preservation/arc-kyverno-arm64-taint-2026-09-12`
  - remote: `git@github.com:ebpro/gitops.git`
  - repo path: `refresh/arc-kyverno-arm64-taint-2026-09-12/`
- Created from `origin/main` (`7a05f7bdcbd3949847a8c78eb0bbcd5772d002e2`) via an **isolated
  `git worktree`**, NOT by switching the shared checkout. Reason: at handoff time the main working
  tree `/mnt/hdd/home/bruno/gitops` was on ANOTHER parallel session's branch
  (`preservation/opencode-sota-7a05f7b-...`) with stray untracked files. A worktree left that
  session untouched.

## Retrieve it (fresh session)
```
git -C /mnt/hdd/home/bruno/gitops fetch origin
git -C /mnt/hdd/home/bruno/gitops show origin/preservation/arc-kyverno-arm64-taint-2026-09-12:refresh/arc-kyverno-arm64-taint-2026-09-12/SITREP.md
# or check out the whole folder to a scratch worktree:
git -C /mnt/hdd/home/bruno/gitops worktree add /tmp/arc-handoff preservation/arc-kyverno-arm64-taint-2026-09-12
```

## Redaction status
- **No plaintext secrets/tokens are present** in any file here.
  - `resourceFilters`, RBAC, policy YAML, cache-bust lines: infra descriptors, not credentials.
  - `githubConfigSecret: arc-github-creds` is a Kubernetes Secret **name**, not a value.
  - Vault paths (e.g. `secret/data/...`) are references only.
- The sanctioned one-off Kyverno ConfigMap patch command contains **no secret** (only a filter string).
- If the fresh session adds anything token-bearing (e.g. a Keycloak client secret) to a handoff doc,
  redact it before committing.

## NOT committed (deliberately excluded)
- `arm-test.yaml` — stray throwaway Pod (nodeSelector arm64, nginx) from a prior manual test; superseded by the toleration change-set.
- `helm/releases/pact-broker/values.yaml.backup`, `kubernetes/keycloak-realm/platform-realm-setup-job.yaml.bak` — unrelated to this job, left for their owner session.
