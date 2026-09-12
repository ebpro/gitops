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
