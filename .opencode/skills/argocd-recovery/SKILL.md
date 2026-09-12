---
name: argocd-recovery
description: Diagnosing and resolving ArgoCD application sync failures, including OutOfSync and Progressing states
---

## What I do
1. Check app status: `kubectl get app <name> -n argocd -o yaml`
2. Identify failure type:
   - **OutOfSync**: `kubectl diff -f <manifest>` — drift detected, fix in git
   - **Progressing**: long-running, check deployments and pods
   - **Degraded**: expected resources missing, check `prune`
   - **Unknown**: API server issue or ArgoCD itself unhealthy
3. For long-running apps, check `kubectl get deployments -n <namespace>`
4. For pod issues, check `kubectl get pods -n <namespace>` then logs
5. ArgoCD console commands that may fix: `kubectl argocd app <name> sync`
6. For frozen apps, remove `argocd.argoproj.io/freeze` annotation

## Key commands
- App logs: `kubectl logs -l app.kubernetes.io/name=<app-name> -n <namespace> --tail=100`
- Resource diff: `kubectl argocd app <name> diff`
- Force sync (git-push only): edit, commit, push
- Reconcile: `kubectl get app <name> -n argocd -o json | jq '.spec.annotations["argocd.argoproj.io/refresh"] = "normal"' | kubectl apply -f -`
- Check overall health: `kubectl get app -A`

## When to use me
Use when an ArgoCD app is not in Synced+Healthy state or sync is stuck.
