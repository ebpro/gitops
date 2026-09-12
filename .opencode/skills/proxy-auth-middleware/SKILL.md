---
name: proxy-auth-middleware
description: Set up reverse proxy authentication (Traefik ForwardAuth + oauth2-proxy) for applications without native SSO support
---

## What I do
1. Deploy **oauth2-proxy** as a SideCar
2. Configure oauth2-proxy with the oauth2-proxy** as a standalone deployment in its own namespace (`sso-proxies`) with GitOps
2. Create a `Keycloak client` in `keycloak/clients/oauth2-proxy.yaml` (confidential, PKCE)
3. Configure Traefik `Middleware` of type `ForwardAuth`:
   ```yaml
   apiVersion: traefik.io/v1alpha1
   kind: Middleware
   metadata:
     name: keycloak-forward-auth
   spec:
     forwardAuth:
       address: http://oauth2-proxy.sso-proxies.svc.cluster.local:4180/oauth2/auth
       trustForwardHeader: true
       authResponseHeaders:
         - X-Forwarded-User
         - X-Forwarded-Groups
   ```
4. Apply to IngressRoute:
   ```yaml
   spec:
     entryPoints:
       - websecure
     routes:
       - match: Host(`sonarqube.example.com`)
         kind: Rule
         services:
           - name: sonarqube
             port: 9000
         middlewares:
           - name: keycloak-forward-auth
   ```
5. Configure application to trust headers:
   - **SonarQube**: `sonar.forceAuthentication` + custom security realm that reads `X-Forwarded-User` (requires patch/property flag)
   - **Nexus**: `nexus.content.userProperties.forceAuthentication` + headers
6. Test with `curl -H "Authorization: Bearer <keycloak-token>" <app-url>/healthcheck`

## Key patterns
- **oauth2-proxy config**: `provider=keycloak-oidc`, `oidcissuerurl=https://keycloak.example.com/realms/platform`, `emaildomain=*`
- **Group extraction**: `skip-jwt-bearer-tokens=true`, `pass-access-token=true`, `set-xauthrequest=true`
- **Speed/access-header**: `X-Forwarded-User`, `X-Forwarded-Email`, `X-Forwarded-Preferred-Username`, `X-Forwarded-Groups`
- **Vault secret**: oauth2-proxy `cookie-secret`, `client-secret` stored in Vault → ExternalSecret
- **Emergency access**: One bypass IP range or path for break-glass admin

## When to use me
Use when an application (SonarQube CE, Nexus OSS, Apicurio Studio) lacks native OIDC/SAML and needs enterprise SSO.
