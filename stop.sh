#!/usr/bin/env bash
# OPTAVIM, stop the workloads (scale to 0). PVCs and data are kept.
# Reverse dependency order: apps and MFA, then SSO, observability and SIEM,
# then ingress and cache. Re-run apply.sh to bring everything back up.
#
# The MariaDB database is operator-managed and left to the operator (it shuts
# down gracefully when the nodes power off); this script does not touch it.

set -euo pipefail

scale0() {  # kind ns name
  kubectl scale "$1" -n "$2" "$3" --replicas=0 >/dev/null 2>&1 \
    && echo "  $1/$3 ($2) -> 0" \
    || echo "  $1/$3 ($2) skipped (absent)"
}

echo ">> apps + MFA"
for d in nextcloud dolibarr orangehrm; do scale0 deploy apps "$d"; done
for d in privacyidea-server privacyidea-radius; do scale0 deploy identity "$d"; done

echo ">> SSO"
scale0 sts auth keycloak

echo ">> observability + SIEM"
for d in grafana prometheus kube-state-metrics blackbox-exporter redis-exporter haproxy-exporter snmp-exporter; do
  scale0 deploy monitoring "$d"
done
scale0 deploy security wazuh-dashboard
for s in wazuh-manager wazuh-indexer; do scale0 sts security "$s"; done

echo ">> ingress + cache"
scale0 deploy ingress traefik
scale0 deploy databases redis

echo
echo "Workloads stopped (data kept). Bring back up with:  ./apply.sh"
