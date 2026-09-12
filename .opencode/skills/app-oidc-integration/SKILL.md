---
name: app-oidc-integration
description: Integrate an application with Keycloak for OIDC/SAML authentication, including group-to-role mapping
---

## What I do
1. Verify the **"Supported authentication protocol** column in the app matrix
2. For apps with **native OIDC support**:
   - Create Keycloak client in `keycloak/clients/` (client-id, redirect URIs, scopes)
   - Configure `GroupMapper` in Keycloak realm to pass `groups` claim
   - Edit app's `helm/releases/<app>/values.yaml` with OIDC provider URL, client ID, client secret ref
   - Map Keycloak groups → app Role in app config
3. For apps **without native SSO** (SonarQube CE, Nexus OSS):
   - Use `proxy-auth-middleware` skill instead → Traefik ForwardAuth + oauth2-proxy
   - Inject `X-Forwarded-User` and `X-Forwarded-Groups` headers into the app
4. Test with `kubectl exec -it <pod> -n <ns> -- curl <app-url>/login` or SSO redirect flow
5. Update `infrastructure/README.md` identity matrix with new entry

## Key patterns
- **OIDC client config**: `protocol: openid-connect`, `access-type: confidential`, `standard-flow: true`
- **Group mapper**: `user attribute → groups`, claim name `groups` or `roles` (app-specific)
- **Secret management**: Client secret stored in Vault, referenced via ExternalSecret
- **Rollback**: Disable OIDC in app values, fallback to local auth. Keep one emergency admin account.

## Supported apps matrix (for reference)
| App | Protocol | Native OIDC | Notes |
|---|---|---|---|
| ArgoCD | OIDC | ✅ | Groups → ArgoCD RBAC via `argocd-rbac-cm` |
| Harbor | OIDC | ✅ | Native OIDC provider integration |
| Gitea | OIDC | ✅ | OAuth2/OIDC provider, disable local register |
| Grafana | OIDC | ✅ | `grafana.ini` config |
| Vault | OIDC | ✅ | Vault OIDC auth method |
| Backstage | OIDC | ✅ | `app-config.yaml` OIDC plugin |
| Plane | SAML/OIDC | ✅ | Supported via settings |
| Microcks | Keycloak | ✅ | Native Keycloak integration |
| Nexus OSS | — | ❌ | Use Traefik ForwardAuth (skill: proxy-auth-middleware) |
| SonarQube CE | — | ❌ | Enterprise-only. Use ForwardAuth (skill: proxy-auth-middleware) |

## When to use me
Use when connecting an existing application to Keycloak for authentication.
