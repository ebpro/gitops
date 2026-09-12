# Execution order for the fresh session

1. `cd /mnt/hdd/home/bruno/gitops && git checkout main && git pull --ff-only`
   → `git status --short` + `ls kubernetes/arc/` to confirm no partial change-set exists yet.
2. Create the 2 new files + make the 4 code edits + 2 doc edits per FILES.md.
   - For Kyverno values (edit #6): verify the chart hook via the vendored/remote chart or docs; if no
     hook, use the comment-block fallback. Never invent a schema.
3. Validate offline before committing:
   - `kustomize build kubernetes/arc` (or `kubectl kustomize`) renders policy + RBAC cleanly.
   - `helm template` / `argocd` diff the ARC values change if tooling is available.
4. Commit with the exact message in FILES.md and push to `origin main`.
5. Trigger reconcile if needed:
   `kubectl annotate application gitops-platform -n argocd argocd.argoproj.io/refresh=hard --overwrite`
   then wait for the chain (gitops-platform → AppSets → apps → live).
6. Apply the one-off Kyverno CM patch (FILES.md "AFTER PUSH") — read-only verify webhook first.
7. Run CHECKLIST.md verifications.
8. If the ARM runner still won't schedule: read `kubectl describe pod <arm runner> -n arc-runners`
   (events should no longer mention the taint) and the Kyverno policy logs.
9. Multi-agent note: if operating as lead orchestrator, delegate the write steps to `builders/implement`
   with a **compact, git-only, no-media** prompt that points at this folder. Do the cluster verification
   yourself read-only. The one-off CM patch is a data-level exception — keep it to the single documented
   command.
10. Revalidate PR #2 only after PR #3 merges.
