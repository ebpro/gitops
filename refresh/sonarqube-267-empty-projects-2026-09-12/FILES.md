# FILES — touched / relevant to this job

## Repo files that carry the version pins (the actual fix surface)
- `helm/releases/sonarqube/values.yaml`
  - line 5  : webapp.zip 26.5.0 download URL (init container)
  - line 40 : plugin jar 26.5.0 install URL
  - line 53 : `sonar.ce.javaAdditionalOpts`  =javaagent ...26.5.0.jar=ce
  - line 55 : `sonar.web.javaAdditionalOpts` =javaagent ...26.5.0.jar=web
- `bootstrap/appset-helm.yaml`
  - line 121: chart version 2026.4.1 (server 26.7.0.124771)
  - line 123: valueURL ...?v=3  -> bump to ?v=4 whenever values.yaml changes (cache-buster)

## In-cluster artifacts (read-only inspection, NOT git-managed)
- `/opt/sonarqube/extensions/plugins/sonarqube-community-branch-plugin-26.5.0.jar` (live pod)
- `/opt/sonarqube/web/**` (overridden by the 26.5.0 webapp.zip init container)
- `/opt/sonarqube/logs/` : web.log, ce.log, es.log, access.log (observed clean)

## NOT part of this job (leave for owner sessions)
- `arm-test.yaml`, `helm/releases/pact-broker/values.yaml.backup`,
  `kubernetes/keycloak-realm/platform-realm-setup-job.yaml.bak` — unrelated stray files.
