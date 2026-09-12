# Technical context — Kyverno arm64 taint enforcement

## Why admission + background
- **Admission** (`admission: true`): re-adds the taint in real time on any non-kubelet Node update.
- **Background** (`background: true`): kubelet periodically re-provisions Node objects and is in
  `excludeGroups: system:nodes`, so admission alone would miss those; the background controller
  rescan re-applies the taint. Background Node mutation requires update RBAC on nodes (see RBAC below).

## The ONE sanctioned cluster write (exception to "no kubectl write")
The `kyverno` ConfigMap carries `helm.sh/resource-policy: keep` and is NOT managed by ArgoCD/Helm,
so removing `[Node,*,*]` from its `resourceFilters` cannot be done via git. It is a documented,
one-off, data-level patch. BEFORE patching, read-only confirm the policy mutating webhook actually
catches Nodes (catch-all): `apiGroups: *`, `resources: */*`, operations `CREATE`/`UPDATE` on
`kyverno-policy-mutating-webhook-cfg`.

CURRENT live `resourceFilters` (note `[Node,*,*]` then `[Node/?*,*,*]` at the end):
```
[*/*,kyverno,*] [Event,*,*] [*/events,*,*] [APIService,*,*] [APIServiceGroup,*,*] [TokenReview,*,*] [SubjectAccessReview,*,*] [SelfSubjectAccessReview,*,*] [RuntimeClass,*,*] [ClusterRuntimeClass,*,*] [ConstrainedTemplatePolicy,*,*] [ClusterConstrainedTemplatePolicy,*,*] [ClusterPolicy,*,*] [ClusterPolicyException,*,*] [BackgroundScanReport,*,*] [ClusterBackgroundScanReport,*,*] [ClusterAdmissionReport,*,*] [AdmissionReport,*,*] [kyverno.io/*,*,*] [updaterequests,*,*] [kyverno.io/updaterequests,*,*] [namespaceinitializers,*,*] [namespaceinitializers.cert-manager.io,*,*] [Node,*,*] [Node/?*,*,*]
```

INTENDED new `resourceFilters` (identical MINUS the standalone `[Node,*,*]`; `[Node/?*,*,*]` kept):
```
[*/*,kyverno,*] [Event,*,*] [*/events,*,*] [APIService,*,*] [APIServiceGroup,*,*] [TokenReview,*,*] [SubjectAccessReview,*,*] [SelfSubjectAccessReview,*,*] [RuntimeClass,*,*] [ClusterRuntimeClass,*,*] [ConstrainedTemplatePolicy,*,*] [ClusterConstrainedTemplatePolicy,*,*] [ClusterPolicy,*,*] [ClusterPolicyException,*,*] [BackgroundScanReport,*,*] [ClusterBackgroundScanReport,*,*] [ClusterAdmissionReport,*,*] [AdmissionReport,*,*] [kyverno.io/*,*,*] [updaterequests,*,*] [kyverno.io/updaterequests,*,*] [namespaceinitializers,*,*] [namespaceinitializers.cert-manager.io,*,*] [Node/?*,*,*]
```

Patch command (substitute <NEW STRING> = the INTENDED line above, exactly, single line):
```
kubectl patch configmap kyverno -n kyverno --type merge -p '{"data":{"resourceFilters":"<NEW STRING>"}}'
```

## Git fidelity for the ConfigMap (avoid drift on fresh install)
- Find the `kyverno-3.5.0` chart values key that renders this CM's `resourceFilters`/`excludeGroups`
  (likely a `config:` block). Verify against the chart; **do not guess**.
  - If a hook exists → encode the intended `resourceFilters` + `excludeGroups: system:nodes` in
    `helm/releases/kyverno/values.yaml`.
  - If NO hook exists → add a clearly-marked comment block in `helm/releases/kyverno/values.yaml`
    documenting the one-off patch + the exact new string, so a rebuilt cluster reproduces it.

## Kyverno policy — target content (create kubernetes/arc/node-arm64-arch-taint.yaml)
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: node-arm64-arch-taint
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  validationFailureAction: Audit
  background: true
  admission: true
  emitWarning: false
  rules:
    - name: taint-arm64-nodes
      match:
        any:
          - resources:
              kinds: ["Node"]
              selector:
                matchLabels:
                  kubernetes.io/arch: arm64
      mutate:
        patchStrategicMerge:
          spec:
            taints:
              - key: kubernetes.io/arch
                value: "arm64"
                effect: NoSchedule
```

## RBAC — target content (create kubernetes/arc/kyverno-node-mutation-rbac.yaml)
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:update-nodes
  labels:
    rbac.kyverno.io/aggregate-to-background-controller: "true"
    argocd.argoproj.io/sync-wave: "-1"
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch", "update", "patch"]
```
- Verify the aggregation label matches the base Kyverno background-controller ClusterRole's
  `aggregationRule`. If uncertain, ALSO add a direct `ClusterRoleBinding` to the Kyverno
  background-controller ServiceAccount and report it.

## ARC toleration (Option A) — add under existing template.spec in arm-scale-set-values.yaml
```yaml
    tolerations:
      - key: "kubernetes.io/arch"
        operator: "Equal"
        value: "arm64"
        effect: "NoSchedule"
```
Place it as a sibling of `nodeSelector:` inside `template.spec` (line ~24-25). Do NOT add to
`listenerTemplate` (listeners intentionally stay on the x64 node).

## Stray artifact
`arm-test.yaml` (repo root, untracked) = throwaway nginx Pod pinned arm64 from a prior manual test.
Superseded by the toleration approach. Not part of the change-set; excluded from the handoff commit.
