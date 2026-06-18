#!/bin/bash
# OPTAVIM — Installation nfs-subdir-external-provisioner
# VIP NFS : 10.1.30.100 | Path : /data/exports

set -euo pipefail

echo "=== Ajout du repo Helm ==="
helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ 2>/dev/null || true
helm repo update

echo "=== Installation du provisioner ==="
helm upgrade --install nfs-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --namespace kube-system \
  --set nfs.server=10.1.30.100 \
  --set nfs.path=/data/exports \
  --set storageClass.name=nfs-client \
  --set storageClass.defaultClass=true \
  --set storageClass.reclaimPolicy=Retain

echo "=== Verification ==="
kubectl get sc
kubectl get pods -n kube-system -l app=nfs-subdir-external-provisioner
