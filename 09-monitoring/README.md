# Phase 7 — Monitoring (Prometheus + Grafana)

Minimal observability stack: metrics (no logs for now, Alloy/Loki as a future option).

| Component | Role | Resources |
|---|---|---|
| **Prometheus** | Scrape + TSDB, 15-day retention | 1 replica, 5 Gi PV |
| **Node Exporter** | Host metrics (CPU, RAM, disk, NET) | DaemonSet 6 nodes |
| **kube-state-metrics** | K8s object metrics (deploys, pods, pv…) | 1 replica |
| **Grafana** | Dashboards + OIDC SSO via Keycloak | 1 replica, 1 Gi PV |

## Apply order

```bash
# 0. Check that the monitoring ResourceQuota has been updated (2 CPU, 3Gi mem)
kubectl apply -f 03-resourcequotas/resourcequotas.yaml

# 1. Prometheus
kubectl apply -f 09-monitoring/prometheus/
kubectl apply -f 09-monitoring/node-exporter/
kubectl apply -f 09-monitoring/kube-state-metrics/
kubectl rollout status deploy/prometheus -n monitoring --timeout=180s

# 2. Grafana — OIDC secret to create then fill (the script does this automatically)
kubectl apply -f 09-monitoring/grafana/01-secret.yaml
kubectl apply -f 09-monitoring/grafana/02-configmap.yaml
kubectl apply -f 09-monitoring/grafana/03-deployment.yaml
kubectl apply -f 09-monitoring/grafana/04-ingressroute.yaml
kubectl rollout status deploy/grafana -n monitoring --timeout=180s

# 3. Create the Grafana OIDC client in Keycloak + inject the secret
bash 09-monitoring/configure-oidc-grafana.sh

# 4. (Optional) Import dashboards via the Grafana UI:
#    Dashboards → Import
#      1860 : Node Exporter Full
#     15757 : Kubernetes / Views / Cluster
#     15758 : Kubernetes / Views / Nodes
#     15759 : Kubernetes / Views / Namespaces
```

## Access

- **Grafana**: `https://grafana.optavim.corp` → "Sign in with OPTAVIM SSO" button
- Local admin (fallback): `admin` / value of `GRAFANA_ADMIN_PASSWORD`
- Prometheus UI: port-forward `kubectl port-forward -n monitoring svc/prometheus 9090:9090` (no IngressRoute, internal access only)

## DNS to configure

`grafana.optavim.corp → 10.1.50.100` (HAProxy VIP)
