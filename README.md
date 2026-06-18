This repository serves as the single source of truth for the foundational tier of our Kubernetes platform. 
Managed entirely via GitOps principles using ArgoCD, it deploys the core infrastructure, observability stack, and developer 
toolchain necessary to support complex, multi-agent software engineering environments.

## Architecture Overview

The platform is structured to separate configurations into distinct application overlays and Helm release values, utilizing ArgoCD `ApplicationSets` for automated discovery and deployment.

* **Ingress & Routing:** Traefik, Cert-Manager (Let's Encrypt / Local CA)
* **Observability:** Kube-Prometheus-Stack, Grafana Alloy, Loki, Tempo
* **CI/CD & Runners:** Actions Runner Controller (ARC)
* **Developer Toolchain:** Gitea, Plane, Harbor (Registry), Nexus (Artifacts), SonarQube, Pact-Broker, Microcks
* **Security & State:** Vault, External Secrets, Velero (Backups), Garage (S3), NFS Provisioner

## Repository Structure

```text
├── apps/                 # Kustomize overlays for platform applications (Gitea, Plane, Apicurio)
├── bootstrap/            # ArgoCD ApplicationSets defining the foundational tier
├── clusters/             # Cluster-specific overrides and environment variables
├── helm/
│   ├── apps/             # Generated ArgoCD Application manifests (via gen-helm-apps-full.sh)
│   └── releases/         # Helm values.yaml overrides for each deployed tool
├── infrastructure/       # Shared infrastructure services (e.g., PostgreSQL databases)
└── gen-helm-apps-full.sh # Utility script to regenerate ArgoCD Helm applications

```

## Quickstart: Bootstrapping the Cluster

To initialize the cluster from a blank state, follow these steps.

### Prerequisites

* A running Kubernetes cluster.
* `kubectl` configured with cluster admin context.
* Helm installed locally.

### Step 1: Install the GitOps Engine (ArgoCD)

ArgoCD must be installed manually before it can begin syncing this repository.

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f [https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml](https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml)

```

*Wait for the ArgoCD server pods to reach a `Running` state.*

### Step 2: Apply the Foundational Tier

Once ArgoCD is running, apply the ApplicationSets located in the `bootstrap` directory. This tells ArgoCD to read the repository and begin deploying the Helm charts and Kustomize applications.

```bash
# Apply the Helm applications (Infrastructure, Observability, Tools)
kubectl apply -f bootstrap/appset-helm.yaml

# Apply the Kustomize applications (Gitea, Plane, etc.)
kubectl apply -f bootstrap/appset-kustomize.yaml

```

### Step 3: Accessing the Dashboards

By default, the ArgoCD UI is not exposed via an Ingress until the platform fully syncs. Port-forward to access it locally:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443

```

Retrieve the initial ArgoCD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

```

Log in to `https://localhost:8080` with username `admin` and the retrieved password. From here, you can watch the GitOps synchronization cascade across the cluster.

## Management & Operations

**Adding a new Helm Application:**

1. Add the chart name to the `charts` array in `gen-helm-apps-full.sh`.
2. Define its target namespace in the `NS` array within the script.
3. Run `./gen-helm-apps-full.sh` to generate the ArgoCD wrapper.
4. Create the corresponding `helm/releases/<app-name>/values.yaml` file.
5. Commit and push to main.

**Secret Management:**
Do not commit plaintext secrets to this repository. Ensure all sensitive values in `helm/releases/*/values.yaml` are mapped to `ExternalSecrets` backed by the deployed HashiCorp Vault instance.
