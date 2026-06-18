#!/usr/bin/env bash
# OPTAVIM, deploy the whole stack, in dependency order.
#
# Prerequisites (install these Helm operators first, they own CRDs the manifests use):
#   - Calico (tigera-operator)         - cert-manager
#   - nfs-subdir-external-provisioner   - adcs-issuer
#   - mariadb-operator
# And fill in the secrets (replace the CHANGE_ME_* placeholders) before running.
#
# Each numbered directory is a Kustomize overlay (kubectl apply -k).

set -euo pipefail
cd "$(dirname "$0")"

PHASES=(
  00-calico
  01-namespaces
  02-storage
  03-resourcequotas
  05-databases
  06-ingress
)

for p in "${PHASES[@]}"; do
  echo ">> apply -k $p"
  kubectl apply -k "$p/"
done

# Keycloak truststore + LDAP CA are plain Secrets (not part of the overlay).
echo ">> apply -f 07-keycloak/secrets-templates"
kubectl apply -f 07-keycloak/secrets-templates/

for p in 07-keycloak 08-apps 08-privacyidea 09-monitoring 10-security; do
  echo ">> apply -k $p"
  kubectl apply -k "$p/"
done

echo
echo "Done. Watch it come up:  kubectl get pods -A"
