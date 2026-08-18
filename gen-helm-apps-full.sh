#!/usr/bin/env bash
set -e

mkdir -p helm/apps

declare -A NS=(
  [traefik]=kube-system
  [kube-prometheus]=monitoring
  [cert-manager]=cert-manager
  [external-secrets]=external-secrets
  [nfs-client]=nfs-client
  [vault]=vault
  [woodpecker]=ci
  [garage]=garage
  [velero]=velero
)

# Default namespace fallback
default_ns="argocd"

charts=(
  actions-runner-controller
  alloy
  garage
  harbor
  nexus
  nfs-client
  pact-broker
  sonarqube
  tempo
  vault
  velero
  traefik
  cert-manager
  external-secrets
  kube-prometheus
  loki
  woodpecker
)

for app in "${charts[@]}"; do

  ns="${NS[$app]:-$default_ns}"

  cat > "helm/apps/${app}.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application

metadata:
  name: ${app}
  namespace: argocd

spec:
  project: platform

  source:
    repoURL: https://charts.${app}.io
    chart: ${app}
    targetRevision: latest
    helm:
      valueFiles:
        - ../releases/${app}/values.yaml

  destination:
    server: https://kubernetes.default.svc
    namespace: ${ns}

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

  echo "✅ Generated helm/apps/${app}.yaml"
done
