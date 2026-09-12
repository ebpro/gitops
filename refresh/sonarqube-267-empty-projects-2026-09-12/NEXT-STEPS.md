# NEXT-STEPS

## 0. Re-derive the evidence (read-only, from inside the pod)
```
# API symptoms
kubectl -n sonarqube exec sonarqube-sonarqube-0 -c sonarqube -- sh -c \
 'curl -s -H "Gap-Auth: admin" "http://localhost:9000/api/components/search_projects?ps=50"'
kubectl -n sonarqube exec sonarqube-sonarqube-0 -c sonarqube -- sh -c \
 'curl -s -H "Gap-Auth: admin" "http://localhost:9000/api/projects/search?ps=50"'
# ES doc counts (15 real + 15 auth_ shadows expected)
kubectl -n sonarqube exec sonarqube-sonarqube-0 -c sonarqube -- sh -c \
 'curl -s "http://localhost:9001/_cat/indices?v" ; \
  curl -s "http://localhost:9001/components/_count"'
# DB truth (15 TRK, private=f)
kubectl -n sonarqube exec sonarqube-db-1 -c postgres -- \
 psql -U postgres -d sonardb -c "SELECT count(*), qualifier, private FROM projects GROUP BY qualifier, private;"
```

## 1. DECISIVE EXPERIMENT (the whole point) — disable the 26.5.0 web-layer agent
Prove the version-skew hypothesis: render the app WITHOUT the `=web` javaagent (and ideally WITHOUT
the 26.5.0 webapp.zip override) and re-check `search_projects`. If projects come back -> confirmed.

Two ways, both via Git (NEVER kubectl patch on the live resource):
  A) Minimal test: temporarily comment out line 55 (`sonar.web.javaAdditionalOpts` =web agent) in
     helm/releases/sonarqube/values.yaml, bump `?v=3`->`?v=4` on appset-helm.yaml line 123, commit to
     the preservation branch, and validate render (`argocd app diff`/`helm template`) before merging.
  B) Cleaner test: also drop the webapp.zip init container (line 5) + its /opt/sonarqube/web mount
     so the stock 26.7 webapp is used.
This restarts the SQ pod (brief outage for the team) -> coordinate before merging to main.

## 2. If confirmed, pick the fix
  - Preferred: pin the SERVER down to match the plugin. Force image 26.5.x in values.yaml
    (chart default is 26.7 — set `image.tag` explicitly) so plugin 26.5.0 + webapp 26.5.0 align.
    Lowest risk, keeps branch-plugin features. Remember ?v bump.
  - Or: upgrade to a 26.7-compatible plugin — none released; only PR #1280 (head f47c931...) is a
    candidate. Build/track that fork, then bump lines 5/40/53/55 together and ?v bump.
  - Or: drop the community branch plugin entirely (lose branch features) and use stock 26.7.
  Decide with Bruno based on whether branch analysis is needed.

## 3. Deferred (from pre-compaction session)
  - Finish reading the javaagent source in the plugin clone (`/tmp/opencode/sqcb-plugin` — EPHEMERAL,
    may be gone; re-clone `mc1arke/sonarqube-community-branch-plugin` if needed) to pinpoint the exact
    26.7 search-path hook. Optional; step 1 gives the faster proof.

## 1b. Do NOT bother with an ES reindex (settled 2026-09-12)
The tempting "DB good / index corrupt" theory was checked and REJECTED as a fix path. See CONTEXT.md
"ES index shape". Short version: components index is already 26.7-shaped (auth_*/join_components, 30
docs = 15 real + 15 auth shadow, GREEN, matches DB 1:1) and there is NO safe reindex API in 26.7 —
a rebuild would only wipe ES + restart and reproduce the same content. Go straight to step 1
(disable the `=web` javaagent via Git + ?v bump + restart); it is the reversible, diagnostic test.
