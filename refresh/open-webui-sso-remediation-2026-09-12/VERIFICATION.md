# VERIFICATION — done == all green (no secret values printed)

```
# app healthy
kubectl -n argocd get application open-webui            # SYNC=Synced  HEALTH=Healthy
kubectl -n open-webui get externalsecret                # both ESOs READY=True
kubectl -n open-webui get pods                          # open-webui Deployment pod 1/1 Running
kubectl -n open-webui get databaserole openwebui -o wide  # status not empty / role reconciled

# ownership fixed (Issue 2)
kubectl -n open-webui get secret open-webui-db-app -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
#   -> expect: ExternalSecret  (NOT Cluster)

# in-cluster smoke (Issue app + DB)
kubectl -n open-webui exec deploy/open-webui -- \
  curl -s -o /dev/null -w "health=%{http_code}\n" http://localhost:8080/health      # expect health=200

# LiteLLM reachable with app's key (key read in-pod, never echoed)
kubectl -n open-webui exec deploy/open-webui -- \
  sh -c 'curl -s -o /dev/null -w "litellm=%{http_code}\n" -H "Authorization: Bearer $OPENAI_API_KEY" http://litellm.llm-gateway.svc:4000/v1/models'
#   expect litellm=200

# DB auth (value never printed)
PASS=$(kubectl -n open-webui get secret open-webui-db-app -o jsonpath='{.data.password}' | base64 -d)
PGPASSWORD="$PASS" kubectl -n open-webui exec -i open-webui-db-1 -c postgres -- \
  psql "host=127.0.0.1 user=openwebui dbname=openwebui sslmode=disable" -tAc "SELECT current_user;"
#   expect: openwebui
```

## Manual / out-of-band (cannot be automated here)
- Open `https://openwebui.ebruno.fr` in a browser -> Keycloak login -> provisioned user lands, admin group
  (`platform-admin`) grants Open WebUI admin. Record pass/fail + any claim mapping issues in RESOLVED.md.
- Confirm `/metrics` actually serves (open deviation — ServiceMonitor may target a missing endpoint).
