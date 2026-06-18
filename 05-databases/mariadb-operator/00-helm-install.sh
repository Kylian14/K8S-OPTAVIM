#!/usr/bin/env bash
##############################################################################
# OPTAVIM : install mariadb-operator (CRDs + operator) via Helm OCI charts
#
# Idempotent, no impact on a running Galera: the operator only watches CRs, and
# with no CR present it does nothing. Run from the bastion.
#
# Docs: https://mariadb-operator.com/docs
##############################################################################
set -euo pipefail

NS_OPERATOR="${NS_OPERATOR:-mariadb-operator-system}"
CHART_VERSION="${CHART_VERSION:-26.6.0}"  # Pin operator version (June 2026)

echo "==> Install mariadb-operator $CHART_VERSION in $NS_OPERATOR"

# Helm installed?
if ! command -v helm >/dev/null 2>&1; then
  echo "ERR: helm missing, install Helm 3.x first"
  exit 1
fi

# Namespace
kubectl get ns "$NS_OPERATOR" >/dev/null 2>&1 \
  || kubectl create ns "$NS_OPERATOR"

# CRDs (separate chart, idempotent install/upgrade)
helm upgrade --install mariadb-operator-crds \
  oci://ghcr.io/mariadb-operator/charts/mariadb-operator-crds \
  --version "$CHART_VERSION" \
  --namespace "$NS_OPERATOR"

# Operator
helm upgrade --install mariadb-operator \
  oci://ghcr.io/mariadb-operator/charts/mariadb-operator \
  --version "$CHART_VERSION" \
  --namespace "$NS_OPERATOR" \
  --wait --timeout 5m

echo
echo "==> CRDs available:"
kubectl get crd 2>/dev/null | grep -E "k8s\.mariadb\.com" | awk '{print "    " $1}'

echo
echo "==> Operator pods :"
kubectl get pods -n "$NS_OPERATOR" 2>/dev/null | awk 'NR==1 || /mariadb-operator/'

echo
echo "==> OK, operator ready. Next run: kubectl apply -f 01-minio.yaml"
