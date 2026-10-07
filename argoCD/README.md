# ArgoCD Installation & GitOps Setup (EKS)

## Prerequisites

- EKS Cluster is running.
- kubectl is configured.
- Manifest repository is available on GitHub.
- AWS Load Balancer Controller is already installed.
- Internet access from EKS nodes.

---

# 1. Create ArgoCD Namespace

```bash
kubectl create namespace argocd
```

---

# 2. Install ArgoCD

> Install a pinned version instead of using `stable`.

```bash
kubectl apply -n argocd \
  --server-side \
  --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.9/manifests/install.yaml
```

---

# 3. Verify Installation

```bash
kubectl get pods -n argocd
```

Expected:

```
argocd-application-controller
argocd-applicationset-controller
argocd-dex-server
argocd-notifications-controller
argocd-redis
argocd-repo-server
argocd-server
```

All pods should be **Running**.

---

# 4. Get Initial Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
-o jsonpath="{.data.password}" | base64 -d

echo
```

Username

```
admin
```

---

# 5. Expose ArgoCD UI

```bash
kubectl patch svc argocd-server \
-n argocd \
-p '{"spec":{"type":"LoadBalancer"}}'
```

Check until ELB is created.

```bash
kubectl get svc argocd-server -n argocd -w
```

Example

```
NAME            TYPE           EXTERNAL-IP
argocd-server   LoadBalancer   xxxxxxxxx.us-east-1.elb.amazonaws.com
```

Open

```
https://<ELB-DNS>
```

Ignore browser certificate warning.

---

# 6. Repository Structure

```
assignment-portal-k8s
│
├── argoCD
│   └── application.yaml
│
└── manifest_files
    ├── backend
    ├── frontend
    ├── postgres
    ├── redis
    ├── ingress
    ├── config
    ├── cluster
    ├── monitoring
    └── namespace
```

---

# 7. Create Application

```bash
kubectl apply -f argoCD/application.yaml
```

Verify

```bash
kubectl get applications -n argocd
```

---

# 8. IMPORTANT

Since manifests are inside multiple folders, enable recursive scanning.

Without this ArgoCD will show

```
Healthy
Synced
```

but

```
No resources found
```

Application.yaml

```yaml
source:
  repoURL: https://github.com/YashwanthGowdaM/assignment-portal-k8s.git
  targetRevision: main
  path: manifest_files

  directory:
    recurse: true
```

This setting is mandatory for this repository structure.

---

# 9. Verify Application

```bash
kubectl get app assignment-portal -n argocd
```

Expected

```
SYNC STATUS     HEALTH STATUS

Synced          Healthy
```

---

# 10. Verify Resource Tree

ArgoCD UI should display

```
Application
│
├── Namespace
├── ConfigMap
├── Secret
├── Backend Deployment
├── Backend ReplicaSet
├── Backend Pods
├── Backend Service
├── Backend HPA
├── Frontend Deployment
├── Frontend ReplicaSet
├── Frontend Pods
├── Frontend Service
├── Frontend HPA
├── PostgreSQL
├── Redis
├── PVC
├── StorageClass
└── Ingress
```

---

# 11. Auto Sync Test

Change something in GitHub.

Example

```
backend replicas

2

↓

3
```

Commit & Push.

No kubectl apply is required.

Verify

```bash
kubectl get pods -n assignment-portal -w
```

ArgoCD should automatically deploy the change.

---

# Troubleshooting

## Problem

Application shows

```
Healthy
```

but

```
No resources
```

### Cause

Missing

```yaml
directory:
  recurse: true
```

---

## Problem

Application stuck

```
OutOfSync
```

### Cause

Manifest contained

```
PrometheusRule
```

but Prometheus Operator CRDs were not installed.

Example error

```
monitoring.coreos.com/v1
PrometheusRule

CRD not found
```

### Solution

Either

- Remove monitoring manifest

or

- Install kube-prometheus-stack first.

---

## Useful Commands

Get Applications

```bash
kubectl get app -n argocd
```

Describe Application

```bash
kubectl describe app assignment-portal -n argocd
```

View Application YAML

```bash
kubectl get app assignment-portal -n argocd -o yaml
```

Application Status

```bash
kubectl get app assignment-portal -n argocd
```

Repo Server Logs

```bash
kubectl logs deploy/argocd-repo-server -n argocd
```

Application Controller Logs

```bash
kubectl logs statefulset/argocd-application-controller -n argocd
```

ArgoCD Pods

```bash
kubectl get pods -n argocd
```

ArgoCD Services

```bash
kubectl get svc -n argocd
```

---

# Final Expected State

```
ArgoCD UI
        │
        ▼
GitHub Manifest Repository
        │
        ▼
Automatic Sync
        │
        ▼
Amazon EKS
        │
        ├── Namespace
        ├── ConfigMap
        ├── Secret
        ├── Backend
        ├── Frontend
        ├── PostgreSQL
        ├── Redis
        ├── Services
        ├── Ingress
        ├── HPA
        └── StorageClass
```
