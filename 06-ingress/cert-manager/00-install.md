# cert-manager: installation

Installed via Helm; the chart manages all CRDs and RBAC. The raw manifest is not versioned
(4000+ lines of generated CRDs), only the procedure is kept.

## Installation

```bash
# CRDs + namespace + deployment
helm repo add jetstack https://charts.jetstack.io
helm repo update
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.14.5 \
  --set installCRDs=true
```

## Validation

```bash
kubectl get pods -n cert-manager
# Expected:
# cert-manager-*             1/1 Running
# cert-manager-cainjector-*  1/1 Running
# cert-manager-webhook-*     1/1 Running
```

## Installed version (snapshot 2026-04-23)

- cert-manager: v1.14+ (via Helm)
- Deployed on 2026-03-26 (28 days ago)

## Uninstall (to redo from scratch)

```bash
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager
# Delete the CRDs (if you really want to clean everything up)
kubectl get crd | awk '/cert-manager/ {print $1}' | xargs kubectl delete crd
```
