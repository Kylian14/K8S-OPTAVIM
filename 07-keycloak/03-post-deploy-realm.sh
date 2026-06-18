#!/usr/bin/env bash
# OPTAVIM: full configuration of the OPTAVIM realm in Keycloak
#
# Usage:
#   bash 03-post-deploy-realm.sh
#
# Idempotent: can be rerun without breaking the existing config.
# Does everything via `kcadm.sh` run inside the keycloak-0 pod (no need for public
# DNS nor a valid TLS cert).
#
# Steps:
#   1. Create the OPTAVIM realm (if missing)
#   2. Enable TOTP MFA at the realm level
#   3. LDAPS federation to AD (opvatim.local via 10.1.20.1:636)
#   4. Create the 3 clients: nextcloud + dolibarr (OIDC), orangehrm (SAML)
#   5. Extract the secrets and update the matching K8s Secrets
#   6. Restart the apps so they pick up the new secrets

set -eu

# --- Config ---
REALM="OPTAVIM"
KC_POD="keycloak-0"
KC_NS="auth"
KC_LOCAL="http://localhost:8080"

# Keycloak admin credentials (read from the K8s Secret)
ADMIN_PASS=$(kubectl get secret -n $KC_NS keycloak-secret -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)
LDAP_BIND_PASS=$(kubectl get secret -n $KC_NS keycloak-secret -o jsonpath='{.data.LDAP_BIND_PASSWORD}' | base64 -d)

# LDAP / AD
# FQDN required (not the IP): the LDAPS cert has CN=DC-AD-DC-01.optavim.corp
# and some Java versions reject it even with hostname verification=ANY.
LDAP_URL="ldaps://DC-AD-DC-01.optavim.corp:636"
LDAP_BIND_DN="CN=svc_keycloak_ldap,OU=Comptes_Services,OU=Administration,OU=OPTAVIM,DC=optavim,DC=corp"
LDAP_BASE="OU=OPTAVIM,DC=optavim,DC=corp"

# App hosts (must match the IngressRoutes)
HOST_NEXTCLOUD="cloud.optavim.corp"
HOST_DOLIBARR="erp.optavim.corp"
HOST_ORANGEHRM="rh.optavim.corp"

# --- Helpers ---
log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }

# Run kcadm inside the keycloak-0 pod
kc() {
  kubectl exec -n $KC_NS $KC_POD -- /opt/keycloak/bin/kcadm.sh "$@"
}

# --- 0. Admin auth ---
log "Authenticating to Keycloak (localhost:8080 via kubectl exec)"
kc config credentials --server $KC_LOCAL --realm master --user admin --password "$ADMIN_PASS" >/dev/null
ok "Connected as admin"

# --- 1. Realm ---
log "Creating realm $REALM (if missing)"
if kc get realms/$REALM >/dev/null 2>&1; then
  ok "Realm $REALM already present"
else
  kc create realms -s realm=$REALM -s enabled=true -s displayName="OPTAVIM" \
    -s sslRequired=external -s registrationAllowed=false -s loginWithEmailAllowed=true \
    -s duplicateEmailsAllowed=false -s resetPasswordAllowed=false \
    -s editUsernameAllowed=false -s bruteForceProtected=true >/dev/null
  ok "Realm $REALM created"
fi

# --- 2. MFA TOTP ---
log "Enabling TOTP policy at the realm level"
kc update realms/$REALM \
  -s otpPolicyType=totp \
  -s otpPolicyAlgorithm=HmacSHA1 \
  -s otpPolicyDigits=6 \
  -s otpPolicyPeriod=30 >/dev/null
ok "TOTP configured (6 digits, SHA1, 30s period)"

# Make configureTOTP required for all new users
# (mandatory at first login)
log "TOTP required for all new users (default required action)"
REQUIRED_ACTIONS_BODY='{"alias":"CONFIGURE_TOTP","defaultAction":true,"enabled":true}'
kubectl exec -n $KC_NS $KC_POD -- bash -c "
  /opt/keycloak/bin/kcadm.sh update authentication/required-actions/CONFIGURE_TOTP -r $REALM \
    -s defaultAction=true -s enabled=true 2>&1" >/dev/null && ok "CONFIGURE_TOTP enabled by default"

# --- 3. LDAP Federation ---
log "LDAPS federation to AD ($LDAP_URL)"
EXISTING_LDAP=$(kc get components -r $REALM -q "type=org.keycloak.storage.UserStorageProvider" --fields name,id 2>/dev/null | \
  python3 -c "import sys, json
try:
  data = json.load(sys.stdin)
  for c in data:
    if c.get('name') == 'AD-OPTAVIM':
      print(c['id']); break
except: pass" || true)

if [ -n "${EXISTING_LDAP:-}" ]; then
  ok "LDAP provider AD-OPTAVIM already configured (id=$EXISTING_LDAP)"
else
  LDAP_JSON=$(cat <<EOF
{
  "name": "AD-OPTAVIM",
  "providerId": "ldap",
  "providerType": "org.keycloak.storage.UserStorageProvider",
  "config": {
    "vendor":                ["ad"],
    "connectionUrl":         ["$LDAP_URL"],
    "bindDn":                ["$LDAP_BIND_DN"],
    "bindCredential":        ["$LDAP_BIND_PASS"],
    "usersDn":               ["$LDAP_BASE"],
    "userObjectClasses":     ["person, organizationalPerson, user"],
    "usernameLDAPAttribute": ["sAMAccountName"],
    "rdnLDAPAttribute":      ["cn"],
    "uuidLDAPAttribute":     ["objectGUID"],
    "searchScope":           ["2"],
    "useTruststoreSpi":      ["never"],
    "connectionPooling":     ["true"],
    "pagination":            ["true"],
    "enabled":               ["true"],
    "priority":              ["0"],
    "syncRegistrations":     ["false"],
    "importEnabled":         ["true"],
    "editMode":              ["READ_ONLY"],
    "fullSyncPeriod":        ["604800"],
    "changedSyncPeriod":     ["86400"],
    "startTls":              ["false"],
    "useKerberosForPasswordAuthentication": ["false"]
  }
}
EOF
  )
  # Write JSON to pod, then create
  echo "$LDAP_JSON" | kubectl exec -n $KC_NS $KC_POD -i -- bash -c "cat > /tmp/ldap.json && \
    /opt/keycloak/bin/kcadm.sh create components -r $REALM -f /tmp/ldap.json" \
    && ok "LDAP provider created" || warn "LDAP creation failed (check svc_keycloak_ldap in AD)"
fi

# --- 4. Clients ---
create_oidc_client() {
  local CLIENT_ID=$1
  local REDIRECT=$2
  local PUB_BASE=$3

  log "OIDC client: $CLIENT_ID"
  if kc get clients -r $REALM -q clientId=$CLIENT_ID | grep -q "\"$CLIENT_ID\""; then
    ok "  already present"
  else
    kc create clients -r $REALM \
      -s clientId=$CLIENT_ID \
      -s enabled=true \
      -s publicClient=false \
      -s protocol=openid-connect \
      -s "redirectUris=[\"$REDIRECT\"]" \
      -s "webOrigins=[\"$PUB_BASE\"]" \
      -s standardFlowEnabled=true \
      -s directAccessGrantsEnabled=false \
      -s serviceAccountsEnabled=false \
      -s attributes.'"post.logout.redirect.uris"'="$PUB_BASE/*" >/dev/null
    ok "  created"
  fi
}

create_oidc_client nextcloud "https://$HOST_NEXTCLOUD/*" "https://$HOST_NEXTCLOUD"
create_oidc_client dolibarr  "https://$HOST_DOLIBARR/*"  "https://$HOST_DOLIBARR"
create_oidc_client grafana   "https://grafana.optavim.corp/login/generic_oauth" "https://grafana.optavim.corp"
create_oidc_client wazuh     "https://wazuh.optavim.corp/*" "https://wazuh.optavim.corp"

log "SAML client: orangehrm"
if kc get clients -r $REALM -q clientId=orangehrm | grep -q '"orangehrm"'; then
  ok "  already present"
else
  kc create clients -r $REALM \
    -s clientId=orangehrm \
    -s enabled=true \
    -s protocol=saml \
    -s "redirectUris=[\"https://$HOST_ORANGEHRM/*\"]" \
    -s adminUrl="https://$HOST_ORANGEHRM" \
    -s baseUrl="https://$HOST_ORANGEHRM" \
    -s attributes.'"saml.assertion.signature"'=true \
    -s attributes.'"saml.client.signature"'=false \
    -s attributes.'"saml_assertion_consumer_url_post"'="https://$HOST_ORANGEHRM/auth/saml/callback" \
    -s attributes.'"saml_name_id_format"'=username >/dev/null
  ok "  created"
fi

# --- 5. Secret extraction ---
log "Extracting client secrets"
get_client_id() {
  kc get clients -r $REALM -q clientId=$1 --fields id 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data[0]['id'] if data else '')"
}

NC_ID=$(get_client_id nextcloud)
DOLI_ID=$(get_client_id dolibarr)
GRAF_ID=$(get_client_id grafana)
WAZ_ID=$(get_client_id wazuh)

get_secret() { kc get clients/$1/client-secret -r $REALM --fields value 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('value',''))"; }
NC_SECRET=$(get_secret $NC_ID)
DOLI_SECRET=$(get_secret $DOLI_ID)
GRAF_SECRET=$(get_secret $GRAF_ID)
WAZ_SECRET=$(get_secret $WAZ_ID)

# Realm certificate for SAML (needed for OrangeHRM).
# We extract it via kcadm.sh get keys, no curl in the Keycloak container.
SAML_CERT=$(kc get keys -r $REALM 2>/dev/null | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
for k in data.get('keys', []):
    if k.get('algorithm') == 'RS256' and k.get('use') == 'SIG' and k.get('status') == 'ACTIVE':
        print(k.get('certificate',''))
        break")

if [ -z "$NC_SECRET" ] || [ -z "$DOLI_SECRET" ]; then
  warn "OIDC secrets empty, check client creation"
else
  ok "  nextcloud secret: ${NC_SECRET:0:8}…"
  ok "  dolibarr  secret: ${DOLI_SECRET:0:8}…"
fi
[ -n "$SAML_CERT" ] && ok "  SAML cert       : ${SAML_CERT:0:16}…" || warn "  SAML cert not retrieved"

# --- 6. Update the apps' K8s Secrets ---
log "Updating K8s Secrets"
kubectl get ns apps >/dev/null 2>&1 || kubectl create ns apps

if kubectl get secret -n apps nextcloud-secret >/dev/null 2>&1 && [ -n "$NC_SECRET" ]; then
  kubectl patch secret -n apps nextcloud-secret \
    -p "{\"stringData\":{\"OIDC_CLIENT_SECRET\":\"$NC_SECRET\"}}" >/dev/null
  ok "nextcloud-secret.OIDC_CLIENT_SECRET updated"
fi
if kubectl get secret -n apps dolibarr-secret >/dev/null 2>&1 && [ -n "$DOLI_SECRET" ]; then
  kubectl patch secret -n apps dolibarr-secret \
    -p "{\"stringData\":{\"OIDC_CLIENT_SECRET\":\"$DOLI_SECRET\"}}" >/dev/null
  ok "dolibarr-secret.OIDC_CLIENT_SECRET updated"
fi
if kubectl get secret -n apps orangehrm-secret >/dev/null 2>&1 && [ -n "$SAML_CERT" ]; then
  kubectl patch secret -n apps orangehrm-secret \
    -p "{\"stringData\":{\"SAML_IDP_CERT\":\"$SAML_CERT\"}}" >/dev/null
  ok "orangehrm-secret.SAML_IDP_CERT updated"
fi
if kubectl get secret -n monitoring grafana-secret >/dev/null 2>&1 && [ -n "$GRAF_SECRET" ]; then
  kubectl patch secret -n monitoring grafana-secret \
    -p "{\"stringData\":{\"OIDC_CLIENT_SECRET\":\"$GRAF_SECRET\"}}" >/dev/null
  ok "grafana-secret.OIDC_CLIENT_SECRET updated"
fi
if kubectl get secret -n security wazuh-secret >/dev/null 2>&1 && [ -n "$WAZ_SECRET" ]; then
  kubectl patch secret -n security wazuh-secret \
    -p "{\"stringData\":{\"OIDC_CLIENT_SECRET\":\"$WAZ_SECRET\"}}" >/dev/null
  ok "wazuh-secret.OIDC_CLIENT_SECRET updated"
fi

# --- 7. Rolling restart if apps deployed ---
for ns_app in apps:nextcloud apps:dolibarr apps:orangehrm monitoring:grafana security:wazuh-dashboard; do
  ns=${ns_app%%:*}; app=${ns_app##*:}
  if kubectl get deploy -n "$ns" "$app" >/dev/null 2>&1; then
    kubectl rollout restart deploy/"$app" -n "$ns" >/dev/null
    ok "deploy/$ns/$app restarted"
  fi
done

echo
log "Done."
echo "Admin console: https://auth.optavim.corp/admin/master/console/ (user: admin)"
echo
echo "Next manual steps:"
echo "  • Sync the AD users: console -> $REALM -> User federation -> AD-OPTAVIM -> Sync all users"
echo "  • Check that TOTP is prompted at first login"
