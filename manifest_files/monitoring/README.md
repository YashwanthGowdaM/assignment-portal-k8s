# Assignment Portal – Backend Monitoring & Alerting Guide

Welcome to the comprehensive monitoring and alerting documentation for the **Assignment Submission Portal** running on Kubernetes. This guide assumes an enterprise-grade production environment where observability is treated as a first-class citizen. It consolidates the bootstrap procedures for the `kube-prometheus-stack` alongside the custom application-level configurations (`ServiceMonitor` and `PrometheusRule`).

---

## Architecture Overview

```
 assignment-portal namespace              monitoring namespace
┌──────────────────────────┐        ┌──────────────────────────────────┐
│ Service (app=backend)    │◄───────│ ServiceMonitor                   │
│   port: http /metrics    │ scrape │   assignment-portal-backend      │
│ Backend Deployment/Pods  │ 30s    └───────────────┬──────────────────┘
└──────────────────────────┘                        │ discovered by
                                                    ▼
                                      ┌──────────────────────────┐
                                      │ Prometheus (Operator)    │
                                      │  + PrometheusRule        │──► Alertmanager ──► Notifications
                                      │    assignment-portal-    │
                                      │    backend-alert         │
                                      └──────────────────────────┘
```

1. **Discovery:** The `ServiceMonitor` selects the backend `Service` in the `assignment-portal` namespace via label selectors.
2. **Scraping:** Prometheus scrapes `/metrics` from the application pods every 30 seconds.
3. **Evaluation:** The `PrometheusRule` continually evaluates cluster health metrics, custom application metrics, and resource utilization.
4. **Routing:** Firing alerts pass through Alertmanager to dispatch notifications.

> **Crucial Operator Requirement:** Both custom resources (`ServiceMonitor` and `PrometheusRule`) must carry the label `release: kube-prometheus-stack`. The Prometheus Operator filters resources based on this label.

---

## Part 1: Cluster Monitoring Bootstrap (Prerequisites & Installation)

Perform these steps post-ArgoCD deployment to provision the core monitoring engine.

### 1. Pre-flight Checks
Verify your ArgoCD state and Helm binary:
```bash
kubectl get app -n argocd
helm version
```

### 2. Add Helm Repository & Namespace
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring || true
```

### 3. Install kube-prometheus-stack
```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring
```

Verify that all pods (`Prometheus`, `Grafana`, `Alertmanager`, `Operator`, `node-exporter`, `kube-state-metrics`) report status `Running`:
```bash
kubectl get pods -n monitoring
kubectl get crd | grep prometheusrules
```

### 4. Expose Dashboards via LoadBalancer (Optional / Dev Environment)
```bash
# Expose Grafana
kubectl patch svc kube-prometheus-stack-grafana -n monitoring -p '{"spec":{"type":"LoadBalancer"}}'

# Expose Prometheus
kubectl patch svc kube-prometheus-stack-prometheus -n monitoring -p '{"spec":{"type":"LoadBalancer"}}'
```
* **Grafana Credentials User:** `admin`
* **Grafana Password Retrieval:**
  ```bash
  kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d
  ```

---

## Part 2: Application Instrumentation & Manifests

### 1. Flask Application Exporter Integration
Install the dependency in your backend service:
https://github.com/YashwanthGowdaM/Assignment_submission_portal/commit/77fd0abddeb0d3fefcf1765151246247bc28117e
```text
prometheus-flask-exporter==0.23.2
```

Initialize metrics within your application code:
```python
from prometheus_flask_exporter import PrometheusMetrics

metrics = PrometheusMetrics(app)

metrics.info(
    "assignment_portal",
    "Assignment Group Portal",
    version="1.0.0"
)
```

### 2. Service Requirements
Ensure your backend Kubernetes Service fulfills these constraints:
* Located in namespace: `assignment-portal`
* Labeled with: `app: backend`
* Exposes a **named** port configuration:
  ```yaml
  ports:
  - name: http
    port: 5000
    targetPort: 5000
  ```

### 3. Monitoring Manifests Reference

| File | Kind | Purpose |
|------|------|---------|
| `manifest_files/monitoring/backend-servicemonitor.yaml` | `ServiceMonitor` | Tells Prometheus where and how to scrape backend metrics |
| `manifest_files/monitoring/backend-alert.yaml` | `PrometheusRule` | Defines alert rules evaluated against backend metrics |

#### `backend-servicemonitor.yaml` specifications:
* `metadata.namespace`: `monitoring` (Co-located with Prometheus)
* `spec.namespaceSelector.matchNames`: `assignment-portal`
* `spec.selector.matchLabels`: `app: backend`
* `endpoints[].port`: `http` (Must match the named backend service port)
* `endpoints[].path`: `/metrics`
* `endpoints[].interval`: `30s`

#### `backend-alert.yaml` rules summary (Group: `assignment-portal.rules`):
| Alert | Severity | Condition | Duration (`for`) |
|-------|----------|-----------|------------------|
| `AssignmentPortalBackendDown` | critical | Available replicas of the `backend` deployment equal 0 | 1m |
| `AssignmentPortalBackendUnavailable` | critical | Partial deployment replicas unavailable | 2m |
| `AssignmentPortalBackendHighCPU` | warning | Backend CPU usage > **80%** of requests | 5m |
| `AssignmentPortalBackendHighMemory` | warning | Backend memory working set > **90%** of requests | 5m |
| `AssignmentPortalBackendPodsRestarting` | warning | > **3** container restarts within 15 minutes | 5m |

> *Note on Resource Alerts:* CPU and memory calculations rely on container resource requests being explicitly defined in your deployment specs.

---

## Part 3: Deployment & Verification Lifecycle

### 1. Applying Resources via GitOps / ArgoCD
Commit your backend modifications, `ServiceMonitor`, and `PrometheusRule` manifests to your repository:
```bash
git add .
git commit -m "Add Prometheus instrumentation, ServiceMonitor and alerts"
git push
```
Verify synchronization via ArgoCD:
```bash
kubectl get app assignment-portal -n argocd
```

### 2. Direct Kubernetes Verification Pipeline
Run these validation commands to verify your deployment health:
```bash
# Verify ServiceMonitor
kubectl get servicemonitor -n monitoring assignment-portal-backend

# Verify PrometheusRule
kubectl describe prometheusrule assignment-portal-backend-alert -n monitoring

# Verify Endpoints & Slices
kubectl get endpoints backend-service -n assignment-portal
kubectl get endpointslices -n assignment-portal

# Confirm Prometheus configuration picked up the target
kubectl get secret -n monitoring prometheus-kube-prometheus-stack-prometheus \
  -o jsonpath='{.data.prometheus\.yaml\.gz}' | base64 -d | gunzip | grep -A10 assignment-portal
```

### 3. Prometheus Target Health Check
Port-forward Prometheus locally if LoadBalancer is disabled:
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```
Navigate to `http://localhost:9090` -> **Status** -> **Targets**, and confirm `serviceMonitor/monitoring/assignment-portal-backend/0` is **UP**.

---

## Troubleshooting Guide

| Symptom | Probable Cause | Corrective Action |
|---|---|---|
| Target missing from Prometheus | Missing `release: kube-prometheus-stack` label on custom resources | Ensure both `ServiceMonitor` and `PrometheusRule` have the proper helm release label. |
| Target marked as **DOWN** | `/metrics` path unexposed, port naming mismatch, or NetworkPolicies blocking traffic | Verify backend app exposes `/metrics` on port named `http` and check namespace communication. |
| Rules not loaded in Prometheus | Missing release label on `PrometheusRule` manifest | Add `release: kube-prometheus-stack` under metadata labels. |
| CPU/Memory alerts fail to fire | Resource requests omitted from the backend Deployment spec | Define clear CPU/memory requests in your backend container specifications. |
