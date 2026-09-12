# OpenCode (in-cluster agent server)

Deploys the OpenCode AI coding agent (`opencode web`, port 4096) into the
`opencode` namespace, fronted by Traefik + oauth2-proxy (Keycloak SSO) at
`https://opencode.ebruno.fr`.

## Status / reconciliation gap (read first)

The `deployment.yaml` and `external-secret.yaml` still carry the **P1 values**
(image `harbor.ebruno.fr/library/opencode:1.18.29`, 8-key Vault secret, model
endpoint pointed straight at host vLLM). They are intentionally left unchanged
until the gating steps below complete. Once those land, reconcile the manifests
to the target design documented here:

| Item | Current (P1, in git) | Target (pending) |
|---|---|---|
| Image | `harbor.ebruno.fr/library/opencode:1.18.29` | `harbor.ebruno.fr/bruno/opencode:<short-sha>` (+ `:latest`), built by the `bruno/opencode-image` Gitea repo via Woodpecker |
| Model endpoint | host vLLM `10.2.248.31:8001` (autossh tunnel) | **LiteLLM gateway** `http://10.2.248.31:4000/v1` (deployed in ns `llm-gateway`), which fronts host vLLM + lislab |
| Vault keys | 8 | **9** — add `litellmMasterKey` (the gateway's admin/master key) |

> Do **not** point `deployment.yaml` at the `bruno/opencode:<short-sha>` image or
> add the 9th `litellmMasterKey` `remoteRef` until the image exists in Harbor and
> Vault `secret/opencode` actually has that key — otherwise ArgoCD renders an app
> that can never sync.

## One-off prerequisites (NOT in git)

The Deployment stays pending until **all** of these exist. They are data-level
operations and are intentionally not managed by ArgoCD:

1. **Vault path `secret/opencode`** must be created with the **9 keys** below.
   Values come from `/etc/opencode/opencode.env` on the K3s host (root-only)
   plus the LiteLLM gateway master key. Until it exists the `opencode-secrets`
   ExternalSecret stays unsynced. `serverPassword` is a **NEW random password**
   for the in-cluster server (do NOT reuse the host one) — it is also needed for
   `opencode attach -p` and the Woodpecker attach steps. `litellmMasterKey` is
   the gateway master key from Vault `secret/llm-gateway` (key `litellmMasterKey`).

   ```sh
   vault kv put secret/opencode \
     serverPassword="<new random password>" \
     litellmMasterKey="<gateway master key from secret/llm-gateway>" \
     vllmApiKey="<from env file VLLM_API_KEY>" \
     lisLabApiKey="<LIS_LAB_API_KEY>" \
     sonarToken="<SONAR_TOKEN>" \
     githubToken="<GITHUB_TOKEN>" \
     giteaToken="<GITEA_TOKEN>" \
     woodpeckerToken="<WOODPECKER_TOKEN>" \
     gitopsGiteaToken="<token with write on ebpro/gitops>"
   ```

2. **Image** `harbor.ebruno.fr/bruno/opencode:<short-sha>` (+ `:latest`) must
   exist in Harbor. It is built by the **`bruno/opencode-image`** Gitea repo
   (Woodpecker kaniko pipeline), which vendors the SonarQube MCP jar + plugin
   SDK and bakes the LiteLLM gateway `baseURL`. (Historically this was expected
   from the `ebpro/opencode-config` repo Dockerfile — that repo is now treated
   as read-only / byte-for-byte untouched.)

3. **`harbor-registry-secret`** must exist in ns `opencode` (one-off copy from
   ns `ci`):

   ```sh
   kubectl get secret harbor-registry-secret -n ci -o json \
     | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.managedFields)' \
     | kubectl apply -f -
   ```

4. **Model endpoint** goes through the **LiteLLM gateway** at
   `http://10.2.248.31:4000/v1` (deployed in ns `llm-gateway`, GitOps-managed,
   Synced/Healthy). The gateway itself reaches host vLLM (`10.2.248.31:8001`)
   over the existing autossh tunnel plus the lislab upstream; the OpenCode pod
   only needs egress to the gateway Service, not to vLLM directly.

## Files

| File | Purpose |
|---|---|
| `external-secret.yaml` | ExternalSecret → Vault `secret/opencode` (currently 8 keys; add `litellmMasterKey` → 9) |
| `pvc.yaml` | 20Gi `local-path` PVC for agent data (`XDG_DATA_HOME=/data`) |
| `serviceaccount-rbac.yaml` | SA + read-only ClusterRole for the kubernetes MCP server |
| `deployment.yaml` | The `opencode web` server (Recreate strategy, RWO PVC) |
| `service.yaml` | ClusterIP :4096 |
| `ingress.yaml` | Traefik IngressRoute + oauth2-proxy ForwardAuth (SSO) |
