#!/usr/bin/env bash
##############################################################################
# OPTAVIM: realm settings (FR i18n + theme + clear displayName)
#
# Idempotent. Run from the bastion. Configures OPTAVIM + master realms:
#   - loginTheme = optavim
#   - accountTheme = optavim
#   - internationalizationEnabled = true
#   - supportedLocales = ["fr", "en"]
#   - defaultLocale = fr
#   - displayName = "" (avoids duplicate with the CSS logo "OPTAVIM")
##############################################################################
set -euo pipefail

NS=auth
POD=keycloak-0
REALMS="${*:-OPTAVIM master}"

echo "==> Target realms: $REALMS"

for REALM in $REALMS; do
  echo
  echo "--- $REALM ---"
  kubectl exec -n "$NS" "$POD" -c keycloak -- bash -c "
    /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://localhost:8080 --realm master \
      --user \$KEYCLOAK_ADMIN --password \$KEYCLOAK_ADMIN_PASSWORD >/dev/null 2>&1

    /opt/keycloak/bin/kcadm.sh update realms/$REALM \
      -s loginTheme=optavim \
      -s accountTheme=optavim \
      -s internationalizationEnabled=true \
      -s 'supportedLocales=[\"fr\",\"en\"]' \
      -s defaultLocale=fr \
      -s displayName= \
      -s displayNameHtml= 2>&1
  " 2>&1 | grep -v "^Defaulted" | head -3

  # Verify
  kubectl exec -n "$NS" "$POD" -c keycloak -- bash -c "
    /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://localhost:8080 --realm master \
      --user \$KEYCLOAK_ADMIN --password \$KEYCLOAK_ADMIN_PASSWORD >/dev/null 2>&1
    /opt/keycloak/bin/kcadm.sh get realms/$REALM \
      --fields loginTheme,accountTheme,internationalizationEnabled,supportedLocales,defaultLocale,displayName 2>&1
  " 2>&1 | grep -v "^Defaulted" | head -10
done

echo
echo "==> OK, test:"
echo "   curl -ksk -H 'Host: auth.optavim.corp' https://10.1.50.100/realms/OPTAVIM/protocol/openid-connect/auth?client_id=nextcloud&response_type=code&redirect_uri=https://cloud.optavim.corp/&scope=openid | grep -E 'Connectez|Mot de passe'"
