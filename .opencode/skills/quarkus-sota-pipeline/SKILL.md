---
name: quarkus-sota-pipeline
description: State-of-the-art Woodpecker/Harbor/ArgoCD CI/CD pipeline for Quarkus apps (native build, distroless packaging, Trivy+COSIGN, image-updater CD)
---

# Quarkus SOTA Pipeline 2026

This skill implements a state-of-the-art CI/CD pipeline for Quarkus applications using Woodpecker, Harbor, and ArgoCD.

## Pipeline Architecture
1. **Build Stage**: Uses `quarkus/maven` for native compilation.
2. **Package Stage**: Buildpacks (Paketo/CloudNative) to create distroless images.
3. **Security Stage**: Harbor Trivy scanning + Cosign signing.
4. **CD Stage**: ArgoCD Image Updater for zero-touch deployment.

## Implementation Steps
1. Create `.woodpecker.yaml` in the app repository.
2. Configure Harbor Project for the user.
3. Link the app to `argocd-image-updater`.
