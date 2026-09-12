# CONTEXT — SonarQube 26.7 empty project list

## Source of truth: helm/releases/sonarqube/values.yaml
Version pins (all point at plugin/webapp 26.5.0 while the chart ships server 26.7.0):
- line 5   : init container downloads `.../releases/download/26.5.0/sonarqube-webapp.zip` -> mounted over /opt/sonarqube/web
- line 40  : plugins.install `.../26.5.0/sonarqube-community-branch-plugin-26.5.0.jar`
- line 53  : sonar.ce.javaAdditionalOpts  `-javaagent:.../sonarqube-community-branch-plugin-26.5.0.jar=ce`
- line 55  : sonar.web.javaAdditionalOpts `-javaagent:.../sonarqube-community-branch-plugin-26.5.0.jar=web`

## AppSet wiring (cache-buster trap)
bootstrap/appset-helm.yaml:
- line 121 : chart version 2026.4.1
- line 123 : valueURL https://raw.githubusercontent.com/ebpro/gitops/main/helm/releases/sonarqube/values.yaml?v=3
  -> ArgoCD caches raw valueFiles aggressively. Any values.yaml change MUST bump `?v=3` -> `?v=4`
     or ArgoCD keeps rendering the OLD values (see AGENTS.md "ArgoCD ignores remote valueFile changes").

## Search internals (why 26.5.0 plugin breaks 26.7 search)
SonarQube 26.7 resolves components by document UUID and stores per-project auth in `auth_<uuid>`
shadow docs. The community branch plugin (javaagent + patched webapp) hooks the web/ce search path;
a 26.5.0 agent predates the 26.7 UUID/shadow-doc model, so `search_projects` returns the right
`total` but an empty `components[]`.

## Upstream plugin status
- Latest release: 26.5.0 (no 26.7.0).
- PR #1280 (mc1arke/sonarqube-community-branch-plugin): open, unmerged, unreviewed, Snyk green.
  Head f47c931debe54f0ead79801546937ce03acf137f — only known 26.7-compatible code path.

## Access
- Admin API inside pod: header `Gap-Auth: admin` (SSO break-glass path, see AGENTS.md).
- ES: `http://localhost:9001/` from within sonarqube-sonarqube-0.
- DB: psql via CNPG pod `sonarqube-db-1` container `postgres`, db `sonardb`.

## ES index shape — evidence AGAINST "reindex will fix it" (verified 2026-09-12)
Read-only probe of `components` index inside sonarqube-sonarqube-0 (`http://localhost:9001/components/_mapping` / `_count`):
- `_count` = 30 (5/5 shards successful, 0 failed → GREEN).
- mapping `properties` = auth_allowAnyone, auth_groupIds, auth_userIds, indexType, join_components, key, name, qualifier, uuid.
- `_source: enabled:false` (normal for SonarQube; it reads doc-values).
The presence of `auth_*` + `join_components` fields is the **26.7 auth-shadow-doc model** — a
stale/26.5-shaped or corrupted index would NOT carry them. So the index is already correct-shape
and 1:1 consistent with the 15 DB projects. A reindex rebuilds the SAME 30 docs from the SAME DB
-> same hydration outcome. **Conclusion: refreshing the ES index will NOT fix the empty list; the
failure is downstream of ES (Web resolving the 15 UUIDs it already has into 0 objects).**

## No cheap/safe reindex lever in 26.7 (verified 2026-09-12)
- `GET /api/webservices/list` (top-level key `webServices`) exposes NO full DB->ES reindex action;
  the only `reindex` key is a narrow per-project ISSUE reindex, not components/projects.
- Therefore "reindex everything" = delete the ES index dir on the PVC + restart = downtime + risk to
  branch-plugin structures. STRICTLY worse than the reversible `=web` javaagent test (NEXT-STEPS 1).
- internal_properties has no reindex/search/es key (queried; 0 rows) — there is no pending trigger.
