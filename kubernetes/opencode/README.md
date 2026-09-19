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

   > **9th key / gateway dependency:** `opencode-secrets` also sources one
   > **additional** key, `litellmMasterKey`, from Vault path
   > **`secret/llm-gateway`** via a cross-path `remoteRef` (see
   > `external-secret.yaml`). It is **NOT** part of `secret/opencode`, so
   > `opencode-secrets` ends up with **9 keys total** and the deployment
   > consumes it as `LITELLM_MASTER_KEY`. `secret/llm-gateway` is **shared
   > with the llm-gateway workload** and must also exist for a full sync —
   > until it does the ExternalSecret stays unsynced.

2. **Image** `harbor.ebruno.fr/bruno/opencode:b74ef1d` must exist in Harbor.
   It lives in the **PRIVATE `bruno`** Harbor project and is built by
   **Woodpecker** (gitea repo `bruno/opencode-image`); the tag is the **short
   commit SHA**.

3. **`harbor-registry-secret`** must exist in ns `opencode` (one-off copy from
   ns `ci`):

   ```sh
   kubectl get secret harbor-registry-secret -n ci -o json \
     | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.managedFields)' \
     | kubectl apply -f -
   ```

4. **`harbor-bruno-pull`** (HARD PREREQUISITE) must exist in ns `opencode`.
   The image `harbor.ebruno.fr/bruno/opencode:b74ef1d` lives in the **PRIVATE
   Harbor project `bruno`**, so the pod needs a pull secret with `bruno`
   access. The generic `harbor-registry-secret` robot is scoped to
   `link-shortener` and **CANNOT pull `bruno`** — without this secret the pod
   stays `ImagePullBackOff`. Credentials come from Vault
   `secret/data/harbor/bruno` (robot `robot$opencode-k3s`):

   ```sh
   kubectl -n opencode create secret docker-registry harbor-bruno-pull \
     --docker-server=https://harbor.ebruno.fr \
     --docker-username 'robot$opencode-k3s' \
     --docker-password '<vault secret/data/harbor/bruno:password>'
   ```

5. **Model endpoint** reaches vLLM on host `10.2.248.31:8001` via the existing
   autossh tunnel.

## Files

| File | Purpose |
|---|---|
| `external-secret.yaml` | ExternalSecret → 8 keys from Vault `secret/opencode` + `litellmMasterKey` from `secret/llm-gateway` (9 keys total) |
| `pvc.yaml` | 20Gi `local-path` PVC for agent data (`XDG_DATA_HOME=/data`) |
| `serviceaccount-rbac.yaml` | SA + read-only ClusterRole for the kubernetes MCP server |
| `deployment.yaml` | The `opencode web` server (Recreate strategy, RWO PVC) |
| `service.yaml` | ClusterIP :4096 |
| `ingress.yaml` | Traefik IngressRoute + oauth2-proxy ForwardAuth (SSO) |
