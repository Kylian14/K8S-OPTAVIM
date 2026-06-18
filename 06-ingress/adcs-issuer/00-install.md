# adcs-issuer: cert-manager Issuer for AD Certificate Services

Nokia plugin that lets cert-manager request certificates from the Microsoft AD CS
Certificate Authority exposed by DC-01. Installed via Helm.

## Installation

```bash
helm repo add adcs-issuer https://nokia.github.io/adcs-issuer/
helm repo update
kubectl create namespace adcs-issuer --dry-run=client -o yaml | kubectl apply -f -
helm install adcs-issuer adcs-issuer/adcs-issuer \
  --namespace adcs-issuer \
  --version 3.0.2
```

## Apply order after the Helm chart

```bash
# 1. AD credentials (svc_cert account with "Enroll" rights on the WebServer template)
kubectl apply -f 01-credentials-secret.yaml   # fill in with the credentials

# 2. ClusterAdcsIssuer pointing at the AD CS on DC-01
kubectl apply -f 02-cluster-adcs-issuer.yaml
```

## Installed version (snapshot 2026-04-23)

- adcs-issuer: 3.0.2 via Helm
- AD CS URL: `http://10.1.20.1/certsrv`
- Template used: `WebServer`
