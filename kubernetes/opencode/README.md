# OpenCode (in-cluster agent server)

Deploys the OpenCode AI coding agent (`opencode web`, port 4096) into the
`opencode` namespace, fronted by Traefik + oauth2-proxy (Keycloak SSO) at
`https://opencode.ebruno.fr`.

## One-off prerequisites (NOT in git)

The Deployment stays pending until **all** of these exist. They are data-level
operations and are intentionally not managed by ArgoCD:

1. **Vault path `secret/opencode`** must be created with the 8 keys below.
   Values come from `/etc/opencode/opencode.env` on the K3s host (root-only).
   Until it exists the `opencode-secrets` ExternalSecret stays unsynced.
   `serverPassword` is a **NEW random password** for the in-cluster server
   (do NOT reuse the host one) — it is also needed for `opencode attach -p`
   and the Woodpecker attach steps.

   ```sh
   vault kv put secret/opencode \
     serverPassword="<new random password>" \
     vllmApiKey="<from env file VLLM_API_KEY>" \
     lisLabApiKey="<LIS_LAB_API_KEY>" \
     sonarToken="<SONAR_TOKEN>" \
     githubToken="<GITHUB_TOKEN>" \
     giteaToken="<GITEA_TOKEN>" \
     woodpeckerToken="<WOODPECKER_TOKEN>" \
     gitopsGiteaToken="<token with write on ebpro/gitops>"
   ```

2. **Image** `harbor.ebruno.fr/library/opencode:1.18.29` must exist in Harbor,
   built from the `ebpro/opencode-config` repo Dockerfile.

3. **`harbor-registry-secret`** must exist in ns `opencode` (one-off copy from
   ns `ci`):

   ```sh
   kubectl get secret harbor-registry-secret -n ci -o json \
     | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.managedFields)' \
     | kubectl apply -f -
   ```

4. **Model endpoint** reaches vLLM on host `10.2.248.31:8001` via the existing
   autossh tunnel.

## Files

| File | Purpose |
|---|---|
| `external-secret.yaml` | ExternalSecret → Vault `secret/opencode` (8 keys) |
| `pvc.yaml` | 20Gi `local-path` PVC for agent data (`XDG_DATA_HOME=/data`) |
| `serviceaccount-rbac.yaml` | SA + read-only ClusterRole for the kubernetes MCP server |
| `deployment.yaml` | The `opencode web` server (Recreate strategy, RWO PVC) |
| `service.yaml` | ClusterIP :4096 |
| `ingress.yaml` | Traefik IngressRoute + oauth2-proxy ForwardAuth (SSO) |
