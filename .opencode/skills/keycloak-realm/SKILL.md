---
name: keycloak-realm
description: Create or modify Keycloak realms, clients, groups, and roles via GitOps using Keycloak IAM
---

## What I do
1. Create `keycloak/operator/` — deploy CodeCentric Keycloak Operator (`keycloak/keycloak`) via Helm in `bootstrap/appset-helm.yaml`
2. Create `keycloak/postgresql/realm-<realm-name>` — CNPG cluster for Keycloak (separate from app DBs)
3. Create `keycloak/crds/Keycloak.yaml` — `Keycloak` custom resource with HTTPS config, database connection
4. Create `keycloak/groups/` — one file per group with members, roles, and attribute mappings
5. Create `keycloak/realm-<name>` — `KeycloakRealmImport` CR with full realm JSON (clients, mappers, policies, auth flows)
6. ArgoCD syncs everything via `bootstrap/appset-manifests.yaml`
7. Verify with `kubectl get keycloakrealmimport -A` and check Keycloak admin console

## Key patterns
- Operator: **CodeCentric** (codecentric/keycloak). `KeycloakRoleImport` is the GitOps import mechanism. No UI depends on truth is GitOps.
- Realm JSON: export via `kcadm.sh get realms/<name>` → import via `RealmImport` CR
- Groups: defined in `keycloak/groups/<group>.yaml`, synced via `keycloak-cli` or CR
- Roles: group-needed → client-role, mapped per-application client config. Keep GitOps as the source of truth.
- Auth flows: `authentication-flows` in realm JSON for:
  - Browser flow (web login, standard OIDC)
  - Direct access grants (machine-to-machine)
  - Custom flows: OTP for admin groups, WebAuthn for passkeys

## GitOps structure
```
keycloak/
├── operator/
│   └── keycloak-operator.yaml    # CRD + operator deployment
├── realms/
│   └── platform-realm.yaml       # KeycloakRealmImport CR
├── clients/
│   ├── argocd-client.yaml
│   ├── harbor-client.yaml
│   └── ...
├── groups/
│   ├── platform-admins.yaml
│   ├── platform-engineers.yaml
│   ├── developers.yaml
│   └── ...
└── policies/
    └── role-mappings.yaml
```

## When to use me
Use when provisioning a new Keycloak realm, onboarding a new client (application), or modifying the identity model (groups, roles, policies).
