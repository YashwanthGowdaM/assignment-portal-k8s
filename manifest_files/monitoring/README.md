# Monitoring Setup (After ArgoCD)

This document contains only the successful setup steps performed after ArgoCD installation.

---

# Prerequisites

Verify ArgoCD Application

```bash
kubectl get app -n argocd
```

Expected

```
assignment-portal   Synced   Healthy
```

---

# Verify Helm

```bash
helm version
```

Expected

```
v3.x.x
```

---

# Add Prometheus Helm Repository

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
```

Update repositories

```bash
helm repo update
```

---

# Create Monitoring Namespace

```bash
kubectl create namespace monitoring
```

If it already exists

```
Error from server (AlreadyExists)
```

Ignore and continue.

---

# Install kube-prometheus-stack

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring
```

---

# Verify Pods

```bash
kubectl get pods -n monitoring
```

Expected

- Prometheus
- Grafana
- Alertmanager
- Prometheus Operator
- kube-state-metrics
- node-exporter

All should become

```
Running
```

---

# Verify Services

```bash
kubectl get svc -n monitoring
```

---

# Verify Prometheus CRDs

```bash
kubectl get crd | grep prometheusrules
```

Expected

```
prometheusrules.monitoring.coreos.com
```

---

# Expose Grafana

```bash
kubectl patch svc kube-prometheus-stack-grafana \
-n monitoring \
-p '{"spec":{"type":"LoadBalancer"}}'
```

Verify

```bash
kubectl get svc kube-prometheus-stack-grafana -n monitoring
```

Open

```
http://<Grafana-ELB>
```

---

# Grafana Login

Username

```
admin
```

Password

```bash
kubectl get secret kube-prometheus-stack-grafana \
-n monitoring \
-o jsonpath="{.data.admin-password}" | base64 -d
```

---

# Expose Prometheus

```bash
kubectl patch svc kube-prometheus-stack-prometheus \
-n monitoring \
-p '{"spec":{"type":"LoadBalancer"}}'
```

Verify

```bash
kubectl get svc kube-prometheus-stack-prometheus -n monitoring
```

Health Check

```bash
curl http://<Prometheus-ELB>:9090/-/healthy
```

Expected

```
Prometheus Server is Healthy.
```

---

# Backend Application Metrics

Install dependency

```
prometheus-flask-exporter==0.23.2
```

Initialize metrics

```python
from prometheus_flask_exporter import PrometheusMetrics

metrics = PrometheusMetrics(app)

metrics.info(
    "assignment_portal",
    "Assignment Group Portal",
    version="1.0.0"
)
```

Verify

```bash
curl http://localhost:5000/metrics
```

Metrics should include

```
assignment_portal
flask_http_request_total
flask_http_request_duration_seconds
python_info
```

---

# Push Application Changes

```bash
git add .
git commit -m "Add Prometheus metrics"
git push
```

GitHub Actions builds new Docker image.

Manifest repository gets updated.

ArgoCD deploys automatically.

Verify

```bash
kubectl get app assignment-portal -n argocd
```

Expected

```
Synced
Healthy
```

---

# Backend Alert Rules

Create

```
manifest_files/monitoring/backend-alert.yaml
```

Important label

```yaml
labels:
  release: kube-prometheus-stack
```

Push changes

```bash
git add .
git commit -m "Add backend Prometheus alerts"
git push
```

Verify

```bash
kubectl get prometheusrule -n monitoring
```

Describe

```bash
kubectl describe prometheusrule assignment-portal-backend-alert -n monitoring
```

---

# Backend ServiceMonitor

Create

```
manifest_files/monitoring/backend-servicemonitor.yaml
```

---

# Backend Service

Ensure the backend Service has a named port.

```yaml
ports:
- name: http
  port: 5000
  targetPort: 5000
```

---

# Push Manifest Changes

```bash
git add .
git commit -m "Add ServiceMonitor"
git push
```

Wait for ArgoCD

```bash
kubectl get app assignment-portal -n argocd
```

Expected

```
Synced
Healthy
```

---

# Verify ServiceMonitor

```bash
kubectl get servicemonitor -n monitoring
```

Expected

```
assignment-portal-backend
```

---

# Verify Backend Service

```bash
kubectl get svc backend-service \
-n assignment-portal
```

---

# Verify Backend Pods

```bash
kubectl get pods \
-n assignment-portal \
--show-labels
```

Backend pods should have

```
app=backend
```

---

# Verify Endpoints

```bash
kubectl get endpoints backend-service \
-n assignment-portal
```

---

# Verify EndpointSlice

```bash
kubectl get endpointslices \
-n assignment-portal
```

---

# Verify Prometheus Configuration

```bash
kubectl get prometheus kube-prometheus-stack-prometheus \
-n monitoring \
-o yaml | grep -A5 serviceMonitorSelector
```

Expected

```
release: kube-prometheus-stack
```

---

# Verify Generated Scrape Job

```bash
kubectl get secret -n monitoring prometheus-kube-prometheus-stack-prometheus \
-o jsonpath='{.data.prometheus\.yaml\.gz}' \
| base64 -d \
| gunzip \
| grep -A10 assignment-portal
```

Expected

```
job_name: serviceMonitor/monitoring/assignment-portal-backend/0
```

---

# Current Status

Completed

- ✅ kube-prometheus-stack installed
- ✅ Prometheus running
- ✅ Grafana running
- ✅ Alertmanager running
- ✅ PrometheusRule created
- ✅ ServiceMonitor created
- ✅ Flask metrics exposed
- ✅ Backend Service configured
- ✅ Prometheus generated scrape configuration

Next Session

Open Prometheus

```
http://<Prometheus-ELB>:9090
```

Navigate

```
Status
→ Targets
```

Verify

```
assignment-portal-backend
```

Once the target is **UP**, continue with:

- Verify `assignment_portal` metric
- Verify `flask_http_request_total`
- Build Grafana Dashboard
- Configure Alertmanager notifications
