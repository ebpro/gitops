# Git preservation

## Where this is saved
- Dedicated NON-main branch (inert to ArgoCD):
  - repo:   git@github.com:ebpro/gitops.git
  - branch: preservation/sonarqube-267-empty-projects-2026-09-12
  - path:   refresh/sonarqube-267-empty-projects-2026-09-12/
  - base:   origin/main @ 01039ae (created via isolated `git worktree`, shared checkout untouched)
- Discoverable copy (unversioned): /home/bruno/REFRESH/sonarqube-267-empty-projects-2026-09-12/
- Claimed via the shared /home/bruno/REFRESH/claim.sh; a row was auto-appended to /home/bruno/REFRESH/INDEX.md.

## Retrieve it (fresh session)
```
git -C /mnt/hdd/home/bruno/gitops fetch origin
git -C /mnt/hdd/home/bruno/gitops show \
  origin/preservation/sonarqube-267-empty-projects-2026-09-12:refresh/sonarqube-267-empty-projects-2026-09-12/SITREP.md
# or check the whole folder out to a scratch worktree:
git -C /mnt/hdd/home/bruno/gitops worktree add /tmp/sq-handoff preservation/sonarqube-267-empty-projects-2026-09-12
```

## Why a worktree, not main
At handoff time a CONCURRENT session held a registered worktree
(`/tmp/wt-open-webui-sso-remediation-2026-09-12`) on the same repo. Per
/home/bruno/REFRESH/CONCURRENCY.md, the shared primary tree is a race condition — so this job was
claimed on its own branch/worktree and will publish by PR, never by pushing to main directly.

## Redaction status
- No plaintext secrets/tokens. `Gap-Auth` is a header NAME; the admin break-glass value is not stored.
- jdbcSecretName / account.adminPasswordSecretName are Kubernetes Secret NAMES, not values.
- Vault paths are references only.

## NOT committed (deliberately excluded — foreign to this job)
- arm-test.yaml, helm/releases/pact-broker/values.yaml.backup,
  kubernetes/keycloak-realm/platform-realm-setup-job.yaml.bak  -> left for their owner session.
