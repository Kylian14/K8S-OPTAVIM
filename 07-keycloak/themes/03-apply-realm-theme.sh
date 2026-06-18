#!/usr/bin/env bash
##############################################################################
# OPTAVIM: apply the `optavim` theme to the realms (OPTAVIM + master)
#
# Idempotent. Run from the bastion. Connects to Keycloak via kcadm.sh in the pod.
#
# Usage: bash 03-apply-realm-theme.sh [REALM]
#   REALM default = "OPTAVIM master" (both)
##############################################################################
set -euo pipefail

NS=auth
POD=keycloak-0

REALMS="${1:-OPTAVIM master}"

echo "==> Apply theme 'optavim' to realms: $REALMS"
echo

for REALM in $REALMS; do
  echo "--- Realm: $REALM ---"
  kubectl exec -n "$NS" "$POD" -c keycloak -- bash -c "
    /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://localhost:8080 \
      --realm master \
      --user \$KEYCLOAK_ADMIN \
      --password \$KEYCLOAK_ADMIN_PASSWORD >/dev/null 2>&1 && \
    /opt/keycloak/bin/kcadm.sh update realms/$REALM -s loginTheme=optavim -s accountTheme=optavim -s emailTheme=optavim 2>&1 || \
    /opt/keycloak/bin/kcadm.sh update realms/$REALM -s loginTheme=optavim -s accountTheme=optavim 2>&1
  " 2>&1 | grep -v "^Defaulted" | head -5
done

echo
echo "==> Verification:"
for REALM in $REALMS; do
  echo "--- $REALM ---"
  kubectl exec -n "$NS" "$POD" -c keycloak -- bash -c "
    /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://localhost:8080 \
      --realm master \
      --user \$KEYCLOAK_ADMIN \
      --password \$KEYCLOAK_ADMIN_PASSWORD >/dev/null 2>&1 && \
    /opt/keycloak/bin/kcadm.sh get realms/$REALM --fields loginTheme,accountTheme,emailTheme 2>&1
  " 2>&1 | grep -v "^Defaulted" | head -8
done

echo
echo "==> OK, test the rendering:"
echo "   https://auth.optavim.corp/realms/OPTAVIM/account/"
echo "   https://auth.optavim.corp/realms/OPTAVIM/protocol/openid-connect/auth?client_id=account&redirect_uri=https://auth.optavim.corp/realms/OPTAVIM/account/&response_type=code"
