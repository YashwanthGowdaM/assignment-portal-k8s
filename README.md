# Assignment Portal — Kubernetes Manifests & ArgoCD (GitOps / CD)

Kubernetes manifests for the **Assignment Group Portal**, deployed to **Amazon EKS** by **ArgoCD** using a GitOps model. This repository is the **single source of truth** for what runs in the cluster; its image tags are updated automatically by the CI pipeline in the source-code repository.

> **Repository role:** CD (desired cluster state)
> **Companion repository (CI):** `Assignment_submission_portal` (branch `K8s-deployment`) — builds the images and commits the new tags here
> **This repository:** [`YashwanthGowdaM/assignment-portal-k8s`](https://github.com/YashwanthGowdaM/assignment-portal-k8s) (branch `main`)

---

## Table of Contents

1. [Repository Structure](#1-repository-structure)
2. [Deployed Architecture](#2-deployed-architecture)
3. [Resource Reference](#3-resource-reference)
4. [ArgoCD Application](#4-argocd-application)
5. [GitOps Workflow](#5-gitops-workflow)
6. [Cluster Bootstrap (One-Time Setup)](#6-cluster-bootstrap-one-time-setup)
7. [Deploying & Verifying](#7-deploying--verifying)
8. [Monitoring (Prometheus / Grafana)](#8-monitoring-prometheus--grafana)
9. [Troubleshooting](#9-troubleshooting)
10. [Cleanup](#10-cleanup)
11. [Observations From the Files](#11-observations-from-the-files)

---

## 1. Repository Structure

```text
assignment-portal-k8s/
├── README.md                          # EKS cluster setup commands
├── iam_policy.json                    # AWS Load Balancer Controller IAM policy
├── pre_installation/
│   └── installation_guide.sh          # (empty file, 0 bytes)
├── argoCD/
│   ├── README.md                      # ArgoCD install + GitOps setup guide
│   └── application.yaml               # ArgoCD Application definition
└── manifest_files/                    # Everything ArgoCD syncs (recursive)
    ├── namespace/namespace.yaml       # Namespace: assignment-portal
    ├── config/
    │   ├── configmap.yaml             # assignment-portal-config
    │   └── secret.yaml                # assignment-portal-secret
    ├── cluster/storageclass.yaml      # gp3-storage (EBS CSI)
    ├── postgres/                      # deployment, pvc, service
    ├── redis/                         # deployment, service
    ├── backend/                       # deployment, service, backend_hpa
    ├── frontend/                      # deployment, service, frontend_hpa
    ├── ingress/ingress.yaml           # AWS ALB ingress
    └── monitoring/                    # README, PrometheusRule, ServiceMonitor
```

---

## 2. Deployed Architecture

```text
                         Internet
                            │  HTTP :80
                            ▼
              AWS Application Load Balancer
         (created by AWS Load Balancer Controller
          from Ingress "assignment-portal-ingress")
                            │  path "/"  (target-type: ip)
                            ▼
              frontend-service  (NodePort :80)
                            │
                            ▼
        frontend Deployment — Nginx   (2–5 pods, HPA)
          ├─ /static/*  served locally
          └─ /         proxied to backend-service:5000
                            │
                            ▼
              backend-service  (ClusterIP :5000)
                            │
                            ▼
        backend Deployment — Flask/Gunicorn   (HPA 2–5, Deployment replicas: 3)
             │                              │
             ▼                              ▼
     postgres-service :5432         redis-service :6379
     postgres Deployment (1)        redis Deployment (1)
             │
             ▼
     PVC postgres-pvc (5Gi, gp3-storage → AWS EBS via EBS CSI driver)
```

Everything above runs in namespace **`assignment-portal`** on an EKS cluster (the guide creates `my-eks-cluster` in `us-east-1`, 2 × `t3.medium` nodes).

Container images come from **Amazon ECR** (`003344631245.dkr.ecr.us-east-1.amazonaws.com`):

| Component | Image |
|---|---|
| backend | `assignment-portal-backend:<commit-sha>` |
| frontend | `assignment-portal-frontend:<commit-sha>` |
| postgres | `postgres:16-alpine` |
| redis | `redis:7-alpine` |

---

## 3. Resource Reference

### 3.1 Namespace, config and storage

| File | Kind / Name | Details |
|---|---|---|
| `namespace/namespace.yaml` | Namespace `assignment-portal` | |
| `config/configmap.yaml` | ConfigMap `assignment-portal-config` | `FLASK_ENV=development`, `REDIS_URL=redis://redis-service:6379/0`, `POSTGRES_HOST=postgres-service`, `POSTGRES_PORT=5432`, `POSTGRES_DB=assignment_portal_db`, `POSTGRES_USER=postgres` |
| `config/secret.yaml` | Secret `assignment-portal-secret` (Opaque, `stringData`) | Keys `POSTGRES_PASSWORD`, `SECRET_KEY` |
| `cluster/storageclass.yaml` | StorageClass `gp3-storage` | Default class, provisioner `ebs.csi.aws.com`, type `gp3`, `ext4`, `WaitForFirstConsumer`, `Delete` reclaim, volume expansion allowed |

### 3.2 Workloads

| Component | Replicas | Port | Resources (req → limit) | Probes |
|---|---|---|---|---|
| **backend** | 3 (Deployment) | 5000 | CPU 100m → 500m, Mem 256Mi → 512Mi | readiness + liveness `GET /health` |
| **frontend** | 2 (Deployment) | 80 | CPU 50m → 250m, Mem 64Mi → 256Mi | readiness + liveness `GET /` |
| **postgres** | 1 | 5432 | CPU 250m → 500m, Mem 256Mi → 512Mi | `pg_isready` (exec) |
| **redis** | 1 | 6379 | CPU 100m → 250m, Mem 128Mi → 256Mi | `redis-cli ping` (exec) |

- Backend and frontend use **RollingUpdate** (`maxSurge: 1`, `maxUnavailable: 1`) and `imagePullPolicy: Always`.
- Backend pulls its image with `imagePullSecrets: ecr-registry-secret`. In the frontend Deployment this block is commented out.
- Backend environment: `FLASK_ENV` and `REDIS_URL` from the ConfigMap, `SECRET_KEY` from the Secret, `DATABASE_URL` set inline to `postgresql://postgres:postgres@postgres-service:5432/assignment_portal_db`.
- Postgres data is mounted at `/var/lib/postgresql/data` (subPath `postgres`) from `postgres-pvc`.

### 3.3 Services

| Service | Type | Port → Target |
|---|---|---|
| `backend-service` | ClusterIP | 5000 → 5000 (port named `http`) |
| `frontend-service` | NodePort | 80 → 80 |
| `postgres-service` | ClusterIP | 5432 → 5432 |
| `redis-service` | ClusterIP | 6379 → 6379 |

### 3.4 Autoscaling (HPA, `autoscaling/v2`)

| HPA | Target | Min–Max | CPU | Memory | Scale-down stabilization |
|---|---|---|---|---|---|
| `backend-hpa` | Deployment `backend` | 2–5 | 70 % | 95 % | 30 s |
| `frontend-hpa` | Deployment `frontend` | 2–5 | 70 % | 70 % | 300 s |

Scale-up policy for both: +1 pod or +100 % per 60 s (select `Max`), no stabilization delay. Scale-down: −1 pod or −50 % per 60 s (select `Max`).

### 3.5 Ingress

`ingress/ingress.yaml` — `assignment-portal-ingress`, `ingressClassName: alb`:

| Annotation | Value |
|---|---|
| `alb.ingress.kubernetes.io/scheme` | `internet-facing` |
| `alb.ingress.kubernetes.io/target-type` | `ip` |
| `alb.ingress.kubernetes.io/healthcheck-path` | `/` |
| `alb.ingress.kubernetes.io/listen-ports` | `[{"HTTP":80}]` |
| `alb.ingress.kubernetes.io/success-codes` | `200,302` |

Rule: path `/` (Prefix) → `frontend-service:80`. There is no host rule and no TLS section.

### 3.6 Monitoring resources (namespace `monitoring`)

| File | Kind | Purpose |
|---|---|---|
| `backend-servicemonitor.yaml` | ServiceMonitor `assignment-portal-backend` | Selects `app: backend` in `assignment-portal`, scrapes port `http`, path `/metrics`, every 30 s (timeout 10 s) |
| `backend-alert.yaml` | PrometheusRule `assignment-portal-backend-alert` | 5 alerts (below) |

Both carry label `release: kube-prometheus-stack`.

| Alert | Condition (summary) | For | Severity |
|---|---|---|---|
| `AssignmentPortalBackendDown` | 0 available backend replicas | 1m | critical |
| `AssignmentPortalBackendHighCPU` | CPU usage > 80 % of requests | 5m | warning |
| `AssignmentPortalBackendHighMemory` | Memory usage > 90 % of requests | 5m | warning |
| `AssignmentPortalBackendPodsRestarting` | > 3 restarts in 15 min | 5m | warning |
| `AssignmentPortalBackendUnavailable` | Any unavailable backend replica | 2m | critical |

---

## 4. ArgoCD Application

`argoCD/application.yaml`:

| Field | Value |
|---|---|
| Application | `assignment-portal` (namespace `argocd`), project `default` |
| Source repo | `https://github.com/YashwanthGowdaM/assignment-portal-k8s.git` |
| Target revision | `main` |
| Path | `manifest_files` |
| Directory | `recurse: true` (required — manifests are in sub-folders) |
| Destination | `https://kubernetes.default.svc`, namespace `assignment-portal` |
| Sync policy | `automated` with **`prune: true`** and **`selfHeal: true`** |
| Sync options | `CreateNamespace=true` |

What this means in practice:

- **Automated sync** — a new commit on `main` is applied without a manual step.
- **Prune** — resources removed from Git are deleted from the cluster.
- **Self-heal** — manual changes made directly in the cluster are reverted to the Git state.

---

## 5. GitOps Workflow

```text
Developer pushes code (K8s-deployment branch, CI repo)
        │
        ▼
GitHub Actions builds backend + frontend images → pushes to ECR (tag = commit SHA)
        │
        ▼
GitHub Actions commits new image tags to
  manifest_files/backend/deployment.yaml
  manifest_files/frontend/deployment.yaml     (this repo, branch main)
        │
        ▼
ArgoCD (namespace argocd) compares Git ↔ cluster
        │
        ▼
Out of sync → automatic sync (prune + selfHeal)
        │
        ▼
Kubernetes performs a RollingUpdate of backend / frontend pods
```

The image tags currently in this repository (`77fd0abddeb0d3fefcf1765151246247bc28117e`) are the values written by that pipeline.

---

## 6. Cluster Bootstrap (One-Time Setup)

Order and commands as documented in `README.md` and `argoCD/README.md` (region `us-east-1`):

| # | Step | Command / action |
|---|---|---|
| 1 | Check tools | `aws`, `kubectl`, `eksctl`, `helm` |
| 2 | AWS identity | `aws configure`, `aws sts get-caller-identity` |
| 3 | Create cluster | `eksctl create cluster --name my-eks-cluster --region us-east-1 --nodegroup-name my-worker-node --node-type t3.medium --nodes 2` |
| 4 | Kubeconfig | `aws eks update-kubeconfig --region us-east-1 --name my-eks-cluster` |
| 5 | OIDC provider | `eksctl utils associate-iam-oidc-provider ... --approve` |
| 6 | EBS CSI driver | `eksctl create addon --name aws-ebs-csi-driver ...` |
| 7 | LB Controller IAM policy | Create `AWSLoadBalancerControllerIAMPolicy` from `iam_policy.json` |
| 8 | IAM service account | `eksctl create iamserviceaccount` for `kube-system/aws-load-balancer-controller` |
| 9 | Install LB Controller | `helm repo add eks https://aws.github.io/eks-charts` → `helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system ...` |
| 10 | Check Metrics Server | `kubectl get pods -n kube-system \| grep metrics-server`, `kubectl top nodes` |
| 11 | ECR pull secret | `kubectl create secret docker-registry ecr-registry-secret ... -n assignment-portal` |
| 12 | Install ArgoCD | `kubectl create namespace argocd`, then apply `argo-cd/v3.4.9/manifests/install.yaml` (`--server-side --force-conflicts`) |
| 13 | Admin password | `kubectl -n argocd get secret argocd-initial-admin-secret ...` (user `admin`) |
| 14 | Expose ArgoCD UI | Patch `argocd-server` Service to `LoadBalancer` |
| 15 | Register the app | `kubectl apply -f argoCD/application.yaml` |

> The ECR pull secret (step 11) targets namespace `assignment-portal`, which must exist first. `application.yaml` has `CreateNamespace=true`, and `manifest_files/namespace/namespace.yaml` also defines it.

---

## 7. Deploying & Verifying

After step 15, ArgoCD syncs the application automatically. Check:

```bash
kubectl get app assignment-portal -n argocd      # expect: Synced / Healthy
kubectl get all -n assignment-portal
kubectl get pods,svc,ingress,pvc,hpa -n assignment-portal
```

The ArgoCD resource tree is documented to show: Namespace, ConfigMap, Secret, backend/frontend Deployments (ReplicaSets, Pods, Services, HPAs), PostgreSQL, Redis, PVC, StorageClass and Ingress.

**Auto-sync test (from `argoCD/README.md`):** change a value (e.g. backend replicas 2 → 3) in Git, commit and push, then watch `kubectl get pods -n assignment-portal -w` — no `kubectl apply` is needed.

Useful debug commands:

```bash
kubectl describe pod <pod> -n assignment-portal
kubectl logs <pod> -n assignment-portal            # add --previous for the last crash
kubectl describe ingress assignment-portal-ingress -n assignment-portal
kubectl describe hpa backend-hpa -n assignment-portal
kubectl get endpoints -n assignment-portal
kubectl top pods -n assignment-portal
```

---

## 8. Monitoring (Prometheus / Grafana)

Documented in `manifest_files/monitoring/README.md`. Monitoring is installed **outside** ArgoCD with Helm; only the ServiceMonitor and PrometheusRule are managed through this repository.

1. `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts`
2. `kubectl create namespace monitoring`
3. `helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack --namespace monitoring`
4. Grafana and Prometheus Services are patched to `LoadBalancer` (Grafana user `admin`, password from secret `kube-prometheus-stack-grafana`).
5. The backend exposes `/metrics` through `prometheus-flask-exporter`; the backend Service has the named port `http` that the ServiceMonitor uses.

**Status recorded in that README:** kube-prometheus-stack, Prometheus, Grafana, Alertmanager, PrometheusRule, ServiceMonitor, Flask metrics and the generated scrape config are done. **Next steps listed:** confirm the `assignment-portal-backend` target is **UP** (Prometheus → Status → Targets), verify the `assignment_portal` and `flask_http_request_total` metrics, build a Grafana dashboard, configure Alertmanager notifications.

---

## 9. Troubleshooting

| Symptom | Cause (from `argoCD/README.md`) | Fix |
|---|---|---|
| App is *Healthy* / *Synced* but shows **No resources** | `directory.recurse: true` missing in `application.yaml` | Add it under `spec.source` |
| App stuck **OutOfSync** | `PrometheusRule` / `ServiceMonitor` applied before the Prometheus Operator CRDs exist (`monitoring.coreos.com/v1` CRD not found) | Install `kube-prometheus-stack` first, or remove the monitoring manifests |

ArgoCD diagnostics:

```bash
kubectl get app -n argocd
kubectl describe app assignment-portal -n argocd
kubectl logs deploy/argocd-repo-server -n argocd
kubectl logs statefulset/argocd-application-controller -n argocd
kubectl get pods,svc -n argocd
```

---

## 10. Cleanup

```bash
kubectl delete namespace assignment-portal
helm uninstall aws-load-balancer-controller -n kube-system
eksctl delete iamserviceaccount --cluster my-eks-cluster --namespace kube-system --name aws-load-balancer-controller --region us-east-1
eksctl delete cluster --name my-eks-cluster --region us-east-1
```

> With `selfHeal` and `automated` sync enabled, delete or disable the ArgoCD Application first if you want a deletion to persist.

---

## 11. Observations From the Files

Facts noticed while reading the repository (no changes made):

1. **Plain-text credentials in Git.** `secret.yaml` holds `POSTGRES_PASSWORD: "postgres"` and `SECRET_KEY: "change-me-in-kubernetes"`; the backend Deployment sets `DATABASE_URL` inline with the password.
2. **`FLASK_ENV` is `development`** in the ConfigMap.
3. **Root `README.md` folder names differ from the repo.** Its second deploy option applies `manifest_files/storage/` and `manifest_files/hpa/`, which do not exist (the real folders are `cluster/` and the HPAs sit inside `backend/` and `frontend/`). `kubectl apply -f manifest_files/` also does not descend into sub-folders without `-R`.
4. **`pre_installation/installation_guide.sh` is empty.**
5. **Replica counts:** backend Deployment `replicas: 3` while `backend-hpa` has `minReplicas: 2`.
6. **Frontend `imagePullSecrets` is commented out**, while the frontend image is also in ECR.
7. **Monitoring manifests target namespace `monitoring`,** which is not created by this repository; they need the Prometheus Operator CRDs (see Troubleshooting).
8. **Ingress is HTTP-only (port 80)** with no host or TLS configuration.
9. **Single-replica stateful services:** PostgreSQL and Redis are one-pod Deployments; PostgreSQL data lives on one 5Gi EBS volume with `reclaimPolicy: Delete`.
