# SITREP — SonarQube 26.7 empty project list

## Symptom
UI project list is empty. API confirms the backend returns zero resolvable projects even though
15 projects exist in the DB and in Elasticsearch.

- `GET /api/components/search_projects?ps=50` -> HTTP 200, `paging.total: 15`, but `components: []`
- `GET /api/projects/search?ps=50`            -> `paging.total: 0`
- Reproduced twice (plain + UI-style with facets).

## Environment
- SonarQube **Community Build v26.7.0.124771**, ns `sonarqube`, pod `sonarqube-sonarqube-0` (container `sonarqube`).
- Community Branch Plugin **26.5.0** installed as a javaagent on BOTH ce and web.
- DB: CNPG pod `sonarqube-db-1` (container `postgres`), DB `sonardb`. Admin via header `Gap-Auth: admin`.
- Embedded Elasticsearch 8.19.16 at `http://localhost:9001/` (inside the SQ pod).

## Evidence gathered (read-only)
- DB `projects`: 15 rows, all `qualifier=TRK`, all `private=f`.
- ES `components` index: 30 docs = 15 real + 15 `auth_<uuid>` shadow docs; `_source` disabled; index GREEN.
- DB project UUIDs match the 15 real ES component doc ids **1:1**.
- Web/CE/access logs clean — no WARN/ERROR, no 500s.
- So ES itself is healthy and the failure is **downstream of ES**: Web receives 15 UUIDs but resolves 0 project objects.

## Leading hypothesis
Plugin/webapp **26.5.0** is incompatible with server **26.7.0**'s search internals:
26.7 changed component/project search to resolve documents by UUID with `auth_` shadow docs;
the 26.5.0 branch-plugin javaagent patches the web layer and the 26.5.0 webapp.zip is mounted over
`/opt/sonarqube/web`, so search calls the plugin's old resolution path and returns empty.
No 26.7.0 plugin release exists upstream (latest is 26.5.0). PR #1280 in the plugin repo is the
only known 26.7-compatible work and is unmerged/unreviewed.

## Ruled out
- DB/ES inconsistency (they match 1:1).
- Index corruption / red indices (GREEN, docs present).
- Auth/permissions (admin header path, all projects private=f).
- A transient (reproduced twice, logs clean).

## Not yet done (see NEXT-STEPS)
- Definitive proof: start Web WITHOUT the `=web` javaagent / WITHOUT the 26.5.0 webapp override and
  re-check `search_projects`. This is the decisive experiment but requires a GitOps change + pod restart.
