# Phase 6 — Applications

Three collaborative applications, all in `namespace=apps`, 2 replicas each,
persistent data on NFS (RWX PVCs already created in Phase 4).

| App | Image | Host | DB | Keycloak SSO | User backend |
|---|---|---|---|---|---|
| Nextcloud | `nextcloud:33-apache` | `cloud.optavim.corp` | `nextcloud_db` | OIDC (plugin `user_oidc`) | LDAP AD (user_ldap) |
| Dolibarr  | `dolibarr/dolibarr:19` | `erp.optavim.corp`   | `dolibarr_db`  | OIDC (driver `functions_openid_connect.php`) | Local DB (AD users created manually) |
| OrangeHRM | `orangehrm/orangehrm:5.7` | `rh.optavim.corp` | `orangehrm_db` | OIDC (plugin `orangehrmOpenidAuthenticationPlugin`) | Local DB (LDAP sync `orangehrm:ldap-sync-user`) |

All apps use the **same AD login via Keycloak** (`kylian.nezan` + AD password). The Keycloak OIDC clients are created by `07-keycloak/03-post-deploy-realm.sh`.

## Prerequisites (to validate)

- [ ] Galera Ready (`kubectl get sts -n databases galera` → 3/3)
- [ ] Keycloak Ready (`kubectl get sts -n auth keycloak` → 2/2) with the `OPTAVIM` realm + the 3 clients created (see `07-keycloak/03-post-deploy-realm.sh`)
- [ ] DNS: `cloud.optavim.corp`, `erp.optavim.corp`, `rh.optavim.corp` point to the HAProxy VIP `10.1.50.100`
- [ ] Wildcard certificate `optavim-wildcard-tls` present in the `apps` namespace (already in `ingress`, copy it over)

## Apply order

```bash
# 1. Fill in the secrets (for each app, replace the CHANGE_ME values)
vim 08-apps/nextcloud/01-secret.yaml
vim 08-apps/dolibarr/01-secret.yaml
vim 08-apps/orangehrm/01-secret.yaml

# 2. Copy the wildcard cert from ingress to apps (Traefik v2 IngressRoute with TLS)
kubectl get secret -n ingress optavim-wildcard-tls -o yaml \
  | sed 's/namespace: ingress/namespace: apps/' \
  | kubectl apply -f -

# 3. Apply in order
kubectl apply -f 08-apps/nextcloud/
kubectl apply -f 08-apps/dolibarr/
kubectl apply -f 08-apps/orangehrm/

# 4. Follow the startups (DB schema init + Nextcloud download takes 2-5 min)
kubectl get pods -n apps -w
```

## SSO wiring (post-startup)

Order: Keycloak first (realm + clients), retrieve the client_secrets, update
the K8s Secrets, restart the pods.

### Nextcloud (OIDC) — procedure validated 2026-04-24

```bash
POD=$(kubectl get pods -n apps -l app=nextcloud -o name | head -1)

# 1. Install user_oidc + configure the OPTAVIM provider (OIDC secret auto
#    via 07-keycloak/03-post-deploy-realm.sh)
kubectl exec -n apps $POD -- su -s /bin/bash www-data -c "php occ app:install user_oidc"
CS=$(kubectl get secret -n apps nextcloud-secret -o jsonpath='{.data.OIDC_CLIENT_SECRET}' | base64 -d)
kubectl exec -n apps $POD -- su -s /bin/bash www-data -c "
  php occ user_oidc:provider OPTAVIM \
    --clientid=nextcloud --clientsecret='$CS' \
    --discoveryuri=https://auth.optavim.corp/realms/OPTAVIM/.well-known/openid-configuration \
    --scope='openid email profile' \
    --mapping-uid=preferred_username \
    --mapping-display-name=name \
    --mapping-email=email"

# 2. SSRF: allow private IPs (auth.optavim.corp resolves to the HAProxy VIP
#    in RFC1918). Without this: "violates local access rules" at OIDC login.
kubectl exec -n apps $POD -- su -s /bin/bash www-data -c \
  "php occ config:system:set allow_local_remote_servers --value=true --type=boolean"

# 3. Trust the AD CS root CA (the wildcard cert *.optavim.corp is signed by
#    optavim-DC-AD-DC-01-CA, not recognized by the default Guzzle CA bundle).
kubectl get clusteradcsissuer adcs-optavim -o jsonpath='{.spec.caBundle}' | base64 -d > /tmp/optavim-ca.pem
kubectl cp /tmp/optavim-ca.pem apps/${POD#pod/}:/tmp/optavim-ca.pem
kubectl exec -n apps $POD -- su -s /bin/bash www-data -c \
  "php occ security:certificates:import /tmp/optavim-ca.pem"
```

After these 3 steps, `https://cloud.optavim.corp` → the "Login with OPTAVIM" button works.

### Nextcloud — LDAP provisioning (AD users + groups)

Goal: synchronize the AD users + groups as the Nextcloud backend, then let user_oidc authenticate via Keycloak by reusing the LDAP identifier. Result: a single Nextcloud user per AD user, with its AD groups attached.

**100% CLI procedure validated on 2026-04-24**: the Nextcloud 33 "LDAP/AD integration" UI has several silent pitfalls (see "Pitfalls encountered" at the bottom of the section). Configuration via `occ ldap:set-config` is reliable and reproducible.

#### Step 1 — svc_nextcloud service account in AD

On DC-01 (RDP or SSH):
```powershell
New-ADUser -Name "SVC Nextcloud" `
  -SamAccountName "svc_nextcloud" `
  -UserPrincipalName "svc_nextcloud@optavim.corp" `
  -Path "OU=Comptes_Services,OU=Administration,OU=OPTAVIM,DC=optavim,DC=corp" `
  -AccountPassword (ConvertTo-SecureString -AsPlainText 'CHANGE_ME_password' -Force) `
  -Enabled $true -PasswordNeverExpires $true
Set-ADUser -Identity svc_nextcloud -CannotChangePassword $true
```

**Pitfall**: `-Name` becomes the CN (`CN=SVC Nextcloud,…`) so it is **different** from the `sAMAccountName`. Do not bind on the CN, bind on the UPN `svc_nextcloud@optavim.corp` (see step 4, the `ldapAgentName` line).

#### Step 2 — ConfigMap with the AD CS root CA

PHP LDAP validates the LDAPS cert against `/etc/ldap/ldap.conf`, so the CA is injected there:

```bash
kubectl get clusteradcsissuer adcs-optavim -o jsonpath='{.spec.caBundle}' | base64 -d > /tmp/optavim-ca.pem
kubectl create configmap -n apps nextcloud-ldap-ca \
  --from-file=optavim-ca.pem=/tmp/optavim-ca.pem \
  --from-literal=ldap.conf="TLS_CACERT /etc/ldap/optavim-ca.pem
TLS_REQCERT allow
" --dry-run=client -o yaml | kubectl apply -f -
```

The ConfigMap is mounted automatically into the pods via `02-deployment.yaml` (volumes + volumeMounts `ldap-ca`). Trust test from a pod:
```bash
POD=$(kubectl get pods -n apps -l app=nextcloud -o name | head -1)
kubectl exec -n apps $POD -- bash -c 'openssl s_client -connect DC-AD-DC-01.optavim.corp:636 -CAfile /etc/ldap/optavim-ca.pem </dev/null 2>&1 | grep "Verify return code"'
# Expected: Verify return code: 0 (ok)
```

#### Step 3 — Force user_ldap into eager-load mode (NC33 + user_oidc bug)

On Nextcloud 33 with user_oidc already installed, the user_ldap app stays enabled but its `User_Proxy` backend does NOT register in the UserManager at boot. Symptom: `occ user:list` only sees `admin`, and the logs show `backend: OCA\UserOIDC\User\Backend` + `OC\User\Database` only, no User_LDAP.

Fix: mark user_ldap as an authentication app (auto-load at startup):

```bash
POD=$(kubectl get pods -n apps -l app=nextcloud -o name | head -1)
kubectl exec -n apps $POD -- su -s /bin/bash www-data -c 'php -r "
require_once \"/var/www/html/lib/base.php\";
\OC::\$CLI = true;
\$db = \OC::\$server->getDatabaseConnection();
\$q = \$db->getQueryBuilder();
\$q->insert(\"appconfig\")->values([
  \"appid\" => \$q->createNamedParameter(\"user_ldap\"),
  \"configkey\" => \$q->createNamedParameter(\"types\"),
  \"configvalue\" => \$q->createNamedParameter(\"authentication,prelogin\")
]);
try { \$q->executeStatement(); echo \"OK types inseré\n\"; } catch (\Exception \$e) { echo \"Deja present (OK)\n\"; }
"'
kubectl rollout restart deployment -n apps nextcloud
kubectl rollout status deployment -n apps nextcloud --timeout=120s
```

Verify the registered backend:
```bash
POD=$(kubectl get pods -n apps -l app=nextcloud -o name | head -1)
kubectl exec -n apps $POD -- su -s /bin/bash www-data -c 'php -r "
require_once \"/var/www/html/lib/base.php\";
\OC::\$CLI = true;
foreach (\OC::\$server->getUserManager()->getBackends() as \$b) echo get_class(\$b) . PHP_EOL;
"'
# Expected: must include "OCA\User_LDAP\User_Proxy"
```

#### Step 4 — Configure LDAP via occ (100% CLI, reproducible)

```bash
POD=$(kubectl get pods -n apps -l app=nextcloud -o name | head -1)

# Create config s01 if it does not exist
kubectl exec -n apps $POD -- su -s /bin/bash www-data -c 'php occ ldap:create-empty-config 2>/dev/null || true'

# Server (bind via UPN, NOT via CN, the CN is "SVC Nextcloud" with a space)
kubectl exec -n apps $POD -- su -s /bin/bash www-data -c '
php occ ldap:set-config s01 ldapHost "ldaps://DC-AD-DC-01.optavim.corp"
php occ ldap:set-config s01 ldapPort "636"
php occ ldap:set-config s01 ldapAgentName "svc_nextcloud@optavim.corp"
php occ ldap:set-config s01 ldapAgentPassword "CHANGE_ME_password"
php occ ldap:set-config s01 ldapBase "DC=optavim,DC=corp"

# User filters
php occ ldap:set-config s01 ldapUserFilterObjectclass "user"
php occ ldap:set-config s01 ldapUserFilter "(&(objectClass=user)(sAMAccountName=*))"
php occ ldap:set-config s01 ldapUserFilterMode 1

# Login filter
php occ ldap:set-config s01 ldapLoginFilter "(&(objectClass=user)(sAMAccountName=%uid))"
php occ ldap:set-config s01 ldapLoginFilterMode 1
php occ ldap:set-config s01 ldapLoginFilterAttributes "sAMAccountName"
php occ ldap:set-config s01 ldapLoginFilterUsername 1
php occ ldap:set-config s01 ldapLoginFilterEmail 1

# Groups
php occ ldap:set-config s01 ldapGroupFilterObjectclass "group"
php occ ldap:set-config s01 ldapGroupFilter "(&(objectClass=group)(cn=*))"
php occ ldap:set-config s01 ldapGroupFilterMode 1
php occ ldap:set-config s01 ldapGroupMemberAssocAttr "member"

# Separate user/group bases
php occ ldap:set-config s01 ldapBaseUsers "OU=OPTAVIM,DC=optavim,DC=corp"
php occ ldap:set-config s01 ldapBaseGroups "OU=Groupes_Securite,OU=OPTAVIM,DC=optavim,DC=corp"

# Search attributes — separated by NEWLINE (not space, not comma!)
php occ ldap:set-config s01 ldapAttributesForUserSearch "sAMAccountName
displayName
mail"
php occ ldap:set-config s01 ldapAttributesForGroupSearch "cn"

# Display & email
php occ ldap:set-config s01 ldapUserDisplayName "displayName"
php occ ldap:set-config s01 ldapEmailAttribute "mail"

# Expert — CRITICAL: internal username = sAMAccountName for user_oidc matching
php occ ldap:set-config s01 ldapExpertUsernameAttr "sAMAccountName"
php occ ldap:set-config s01 ldapExpertUUIDUserAttr "objectGUID"
php occ ldap:set-config s01 ldapExpertUUIDGroupAttr "objectGUID"
php occ ldap:set-config s01 ldapExperiencedAdmin 1
php occ ldap:set-config s01 ldapConfigurationActive 1

# Groups — CRITICAL: without hasMemberOfFilterSupport=1, AD groups do not show up (pitfall #5)
php occ ldap:set-config s01 hasMemberOfFilterSupport 1
php occ ldap:set-config s01 useMemberOfToDetectMembership 1
'

# Test bind + search
kubectl exec -n apps $POD -- su -s /bin/bash www-data -c 'php occ ldap:test-config s01'
# Expected: "The configuration is valid and the connection could be established!"

kubectl exec -n apps $POD -- su -s /bin/bash www-data -c 'php occ user:list'
# Expected: list of AD users (kylian.nezan, camille.martin, eric.bernard, thomas.petit, ...)
```

#### Step 5 — user_oidc reuses the LDAP users

```bash
kubectl exec -n apps $POD -- su -s /bin/bash www-data -c \
  'php occ user_oidc:provider OPTAVIM --unique-uid=0 --mapping-uid=preferred_username'
```

With `unique-uid=0` + `mapping-uid=preferred_username` (Keycloak claim) + `sAMAccountName` as the LDAP internal username, at OIDC login user_oidc looks for an existing user whose UID = `preferred_username`, finds the LDAP user, and opens the session without creating a duplicate.

#### E2E verification

1. **Users**: `kubectl exec … occ user:list` must include `kylian.nezan: Kylian Nézan`, `camille.martin: Camille Martin`, etc.
2. **Groups**: `occ group:list` must include `GG_Direction`, `GG_IT`, `DL_Partage_Finance_RW`, `GRP_Nextcloud`…
3. **SSO**: `https://cloud.optavim.corp` → "Login with OPTAVIM" → Keycloak login → back to Nextcloud authenticated, user = `kylian.nezan` (not a new account) with its AD groups attached.

#### Post-provisioning notes (optional — done on the AD side)

**AD users only have Nextcloud groups if they are members of groups located in `OU=Groupes_Securite,OU=OPTAVIM`.** A user only in "Domain Admins" (AD built-in under `CN=Users`) will see `groups: []` in Nextcloud. To attach business groups to a user:

```powershell
# On DC-01
Add-ADGroupMember -Identity GG_IT -Members kylian.nezan
Add-ADGroupMember -Identity GRP_Nextcloud -Members kylian.nezan
```

**To grant Nextcloud admin rights to an AD group** (instead of leaving only the `admin: admin` Database account):
```bash
kubectl exec -n apps $POD -- su -s /bin/bash www-data -c \
  'php occ ldap:set-config s01 ldapAdminGroup "GG_IT"'
```
All members of the AD group `GG_IT` then become Nextcloud admins (effective after the 600s cache TTL, or `occ ldap:set-config s01 ldapCacheTTL 0` to flush).

#### Pitfalls encountered (NC 33 + Optavim AD)

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `data 52e` Invalid credentials on every bind | `ldapAgentName` configured with `CN=svc_nextcloud,...` while the real CN is `CN=SVC Nextcloud,...` (space + capitals) | Bind via UPN: `svc_nextcloud@optavim.corp` |
| 2 | `getUsers()` returns 0 while `ldap:test-config` is OK and a direct PHP bind is OK | `ldapAttributesForUserSearch` stored as a single attribute "sAMAccountName displayName mail" → malformed filter `(sAMAccountName displayName mail=*)` | Pass the attributes separated by **newline** (`$'...\\n...'` in bash) |
| 3 | `user:list` only sees `admin`, loaded backends = only UserOIDC+Database | NC33 bug: when user_oidc is present, user_ldap stays enabled but its bootstrap is not called at the boot of `occ` commands | INSERT into `appconfig`: `appid=user_ldap, configkey=types, configvalue=authentication,prelogin` |
| 4 | CA ConfigMap OK, openssl OK, but `ldap:test-config` "bind failed" | Password contained `!` or `"` → bash escaping mangled the character | Re-set via stdin or via file: `echo -n 'PW' > /tmp/p; set-config s01 ldapAgentPassword "$(cat /tmp/p)"` — or use a password without special characters |
| 5 | `user:info kylian.nezan` shows `groups: []` while kylian.nezan is in GRP_Nextcloud on the AD side (memberOf confirms it) | The `hasMemberOfFilterSupport` flag is **0** by default → user_ldap does not use the `(memberOf=...)` filter on the AD side and falls back to `(member=<userDN>)` which does not match (case/UTF-8) | `occ ldap:set-config s01 hasMemberOfFilterSupport 1` — without this, groups do not show up in Nextcloud despite `useMemberOfToDetectMembership=1` |

### Dolibarr — Keycloak OIDC (native driver `functions_openid_connect.php`)

Dolibarr 19 has a native OIDC driver but it is **not enabled by default**. 100% SQL/CLI procedure validated in Session 2.

#### Step 1 — Keycloak OIDC client

Created by `07-keycloak/03-post-deploy-realm.sh` as a standard OIDC client. Verify:
```bash
KCAP=$(kubectl get secret -n auth keycloak-secret -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)
kubectl exec -n auth keycloak-0 -- /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password "$KCAP"
CID=$(kubectl exec -n auth keycloak-0 -- /opt/keycloak/bin/kcadm.sh get clients -r OPTAVIM --query clientId=dolibarr --fields id --format csv --noquotes | grep -E "^[a-f0-9-]{36}")
kubectl exec -n auth keycloak-0 -- /opt/keycloak/bin/kcadm.sh update clients/$CID -r OPTAVIM -s 'redirectUris=["https://erp.optavim.corp/","https://erp.optavim.corp/*"]'
DOLI_SECRET=$(kubectl exec -n auth keycloak-0 -- /opt/keycloak/bin/kcadm.sh get clients/$CID/client-secret -r OPTAVIM | grep -oE '"value" : "[^"]+"' | cut -d'"' -f4)
echo "DOLI_SECRET=$DOLI_SECRET"
```

#### Step 2 — Trust the AD CS root CA (so Dolibarr can reach Keycloak)

ConfigMap `dolibarr-ca` + initContainer `inject-ca` that appends the CA to the pod's system bundle. See `08-apps/dolibarr/02-deployment.yaml` (already done, only replay if the ConfigMap is lost):
```bash
kubectl get clusteradcsissuer adcs-optavim -o jsonpath='{.spec.caBundle}' | base64 -d > /tmp/optavim-ca.pem
kubectl create configmap -n apps dolibarr-ca --from-file=optavim-ca.pem=/tmp/optavim-ca.pem --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f 08-apps/dolibarr/02-deployment.yaml
```

#### Step 3 — Enable the driver (env var + DB constants)

```bash
# 1. Deployment env var (already in 02-deployment.yaml): DOLI_AUTH=openid_connect,dolibarr
# If an existing conf.php still has only 'dolibarr', force a rollout after the env change:
kubectl rollout restart deployment -n apps dolibarr

# 2. OIDC constants in llx_const
GPW=$(kubectl get secret -n databases galera-secret -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)
OIDC_START="https://auth.optavim.corp/realms/OPTAVIM/protocol/openid-connect/auth?client_id=dolibarr&response_type=code&redirect_uri=https%3A%2F%2Ferp.optavim.corp%2F%3Fafteroauthloginreturn%3D1&scope=openid+profile+email"
kubectl exec -n databases galera-0 -- mariadb -uroot -p"$GPW" dolibarr_db -e "
DELETE FROM llx_const WHERE name LIKE 'MAIN_AUTHENTICATION_%';
INSERT INTO llx_const (name, entity, value, type, visible) VALUES
  ('MAIN_AUTHENTICATION_OIDC_CLIENT_ID', 1, 'dolibarr', 'chaine', 0),
  ('MAIN_AUTHENTICATION_OIDC_CLIENT_SECRET', 1, '$DOLI_SECRET', 'chaine', 0),
  ('MAIN_AUTHENTICATION_OIDC_AUTHORIZE_URL', 1, 'https://auth.optavim.corp/realms/OPTAVIM/protocol/openid-connect/auth', 'chaine', 0),
  ('MAIN_AUTHENTICATION_OIDC_TOKEN_URL', 1, 'https://auth.optavim.corp/realms/OPTAVIM/protocol/openid-connect/token', 'chaine', 0),
  ('MAIN_AUTHENTICATION_OIDC_USERINFO_URL', 1, 'https://auth.optavim.corp/realms/OPTAVIM/protocol/openid-connect/userinfo', 'chaine', 0),
  ('MAIN_AUTHENTICATION_OIDC_REDIRECT_URL', 1, 'https://erp.optavim.corp/?afteroauthloginreturn=1', 'chaine', 0),
  ('MAIN_AUTHENTICATION_OIDC_SCOPE', 1, 'openid profile email', 'chaine', 0),
  ('MAIN_AUTHENTICATION_OIDC_LOGIN_CLAIM', 1, 'preferred_username', 'chaine', 0),
  ('MAIN_AUTHENTICATION_OPENID_URL', 1, '$OIDC_START', 'chaine', 0);
"
```

#### Step 4 — PHP patch (SSRF bypass + logging error)

By default Dolibarr refuses to contact a URL whose IP is RFC1918 (SSRF pitfall). You must pass `$localurl=2` to the driver's `getURLContent` calls:

```bash
POD=$(kubectl get pods -n apps -l app=dolibarr -o name | head -1)
kubectl exec -n apps $POD -- cat /var/www/html/core/login/functions_openid_connect.php > /tmp/oidc.php
sed -i "s|getURLContent(\$conf->global->MAIN_AUTHENTICATION_OIDC_TOKEN_URL, 'POST', http_build_query(\$auth_param));|getURLContent(\$conf->global->MAIN_AUTHENTICATION_OIDC_TOKEN_URL, 'POST', http_build_query(\$auth_param), 1, array(), array('http','https'), 2);|" /tmp/oidc.php
sed -i "s|getURLContent(\$conf->global->MAIN_AUTHENTICATION_OIDC_USERINFO_URL, 'GET', '', 1, \$userinfo_headers);|getURLContent(\$conf->global->MAIN_AUTHENTICATION_OIDC_USERINFO_URL, 'GET', '', 1, \$userinfo_headers, array('http','https'), 2);|" /tmp/oidc.php
# Push to both pods
for p in $(kubectl get pods -n apps -l app=dolibarr -o name); do
  cat /tmp/oidc.php | kubectl exec -i -n apps $p -- bash -c "chmod 644 /var/www/html/core/login/functions_openid_connect.php; cat > /var/www/html/core/login/functions_openid_connect.php"
done
```

⚠️ This patch is **in the container rootfs** (not on the PVC), so it must be replayed after every image upgrade.

#### Step 5 — Create the AD users in `llx_user`

Dolibarr has no automatic LDAP sync, create the users manually:
```bash
kubectl exec -n databases galera-0 -- mariadb -uroot -p"$GPW" dolibarr_db -e "
INSERT INTO llx_user (login, lastname, firstname, email, admin, statut, entity, datec) VALUES
  ('kylian.nezan', 'Nézan', 'Kylian', '', 1, 1, 1, NOW()),
  ('eric.bernard', 'Bernard', 'Éric', '', 0, 1, 1, NOW()),
  ('camille.martin', 'Martin', 'Camille', '', 0, 1, 1, NOW()),
  ('thomas.petit', 'Petit', 'Thomas', '', 0, 1, 1, NOW());"
```

#### Verification

`https://erp.optavim.corp/` → the **"Se connecter par OpenID"** button → Keycloak login (`kylian.nezan` + AD password) → back to Dolibarr as admin.

#### Pitfalls encountered

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Return from Keycloak → Dolibarr login page (flow ignored) | `checkLoginPassEntity` is only called if certain GET params are present | Add `?afteroauthloginreturn=1` to the `redirect_uri` |
| 2 | `OIDC token null (http 400)` + message "Error bad hostname IP (private or reserved range)" | Dolibarr SSRF guard refuses RFC1918 | Pass `$localurl=2` to the driver's `getURLContent()` calls |
| 3 | conf.php stays at `dolibarr` despite env `DOLI_AUTH=openid_connect,dolibarr` | The entrypoint only regenerates conf.php if it is absent | Delete `/var/www/html/conf/conf.php` in the pod + rollout restart |
| 4 | Keycloak login OK but "user not found" | AD user not in `llx_user` or mismatch on `preferred_username` | Create the AD user manually in `llx_user` (login=sAMAccountName) |

---

### OrangeHRM — Keycloak OIDC (native plugin `orangehrmOpenidAuthenticationPlugin`)

**Discovery in Session 2**: OSS 5.7 has a native OIDC plugin under **Admin → Configuration → Social Media Authentication** (despite the "SAML-only Enterprise feature" reputation). The config is stored in `ohrm_openid_provider` + `ohrm_auth_provider_extra_details`.

#### Step 1 — Keycloak OIDC client (recreate if it exists as SAML)

```bash
KCAP=$(kubectl get secret -n auth keycloak-secret -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)
kubectl exec -n auth keycloak-0 -- /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password "$KCAP"
# If the existing client is SAML, delete it then recreate as OIDC:
SAML_CID=$(kubectl exec -n auth keycloak-0 -- /opt/keycloak/bin/kcadm.sh get clients -r OPTAVIM --query clientId=orangehrm --fields id --format csv --noquotes | grep -E "^[a-f0-9-]{36}")
kubectl exec -n auth keycloak-0 -- /opt/keycloak/bin/kcadm.sh delete clients/$SAML_CID -r OPTAVIM

cat <<JSON | kubectl exec -i -n auth keycloak-0 -- bash -c "cat > /tmp/ohrm.json"
{
  "clientId": "orangehrm", "protocol": "openid-connect", "enabled": true,
  "clientAuthenticatorType": "client-secret", "publicClient": false,
  "standardFlowEnabled": true, "directAccessGrantsEnabled": false,
  "redirectUris": ["https://rh.optavim.corp/web/index.php/openidauth/openIdCredentials", "https://rh.optavim.corp/*"],
  "webOrigins": ["https://rh.optavim.corp"]
}
JSON
kubectl exec -n auth keycloak-0 -- /opt/keycloak/bin/kcadm.sh create clients -r OPTAVIM -f /tmp/ohrm.json
CID=$(kubectl exec -n auth keycloak-0 -- /opt/keycloak/bin/kcadm.sh get clients -r OPTAVIM --query clientId=orangehrm --fields id --format csv --noquotes | grep -E "^[a-f0-9-]{36}")
OHRM_SECRET=$(kubectl exec -n auth keycloak-0 -- /opt/keycloak/bin/kcadm.sh get clients/$CID/client-secret -r OPTAVIM | grep -oE '"value" : "[^"]+"' | cut -d'"' -f4)
echo "OHRM_SECRET=$OHRM_SECRET"
```

#### Step 2 — Trust CA + Apache X-Forwarded-Proto + initContainer inject-ca

See `08-apps/orangehrm/02-deployment.yaml` (initContainer `inject-ca` + ConfigMap `orangehrm-ldap-ca` already in place). In addition:
```bash
# On the PVC: .htaccess for HTTPS awareness behind Traefik
POD=$(kubectl get pods -n apps -l app=orangehrm -o name | head -1)
kubectl exec -n apps $POD -- bash -c '
if ! grep -q X-Forwarded-Proto /var/www/html/.htaccess; then
  sed -i "1i SetEnvIfNoCase X-Forwarded-Proto https HTTPS=on" /var/www/html/.htaccess
fi'
```

#### Step 3 — PHP patch: `email` → `preferred_username` + scope `profile`

The AD users have no email, so OrangeHRM must match on `preferred_username`:
```bash
POD=$(kubectl get pods -n apps -l app=orangehrm -o name | head -1)
kubectl exec -n apps $POD -- sed -i 's|requestUserInfo(.email.)|requestUserInfo("preferred_username")|' \
  /var/www/html/src/plugins/orangehrmOpenidAuthenticationPlugin/Controller/OpenIdConnectRedirectController.php
kubectl exec -n apps $POD -- sed -i 's|SCOPE = .email.|SCOPE = "email profile"|' \
  /var/www/html/src/plugins/orangehrmOpenidAuthenticationPlugin/Service/SocialMediaAuthenticationService.php
kubectl rollout restart deployment -n apps orangehrm  # PHP OpCache
```

⚠️ Must be replayed after every image upgrade.

#### Step 4 — Insert the OIDC provider into the DB

```bash
GPW=$(kubectl get secret -n databases galera-secret -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)
kubectl exec -n databases galera-0 -- mariadb -uroot -p"$GPW" orangehrm_db -e "
INSERT INTO ohrm_openid_provider (provider_name, provider_url, status) VALUES ('OPTAVIM Keycloak', 'https://auth.optavim.corp/realms/OPTAVIM', 1);
SET @pid = LAST_INSERT_ID();
INSERT INTO ohrm_auth_provider_extra_details (provider_id, provider_type, client_id, client_secret)
  VALUES (@pid, 1, 'orangehrm', '$OHRM_SECRET');"
```

#### Step 5 — Sync AD users via LDAP (separate from SSO)

LDAP config (Admin → Configuration → LDAP Configuration) then sync:
```bash
# Config via SQL (see Session 2 details — dataMapping.employeeId=null, filter excludes svc_*/admin_t*)
kubectl exec -n apps $POD -- php bin/console orangehrm:ldap-sync-user
# → 4 Employees + System Users created (default ESS role, promote to admin via UI)
```

#### Verification

`https://rh.optavim.corp/` → login with the "OPTAVIM Keycloak" button → back authenticated as `kylian.nezan`.

#### Pitfalls encountered

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `installer/api/installation/pre-migration` → 500 "Invalid result" | The OrangeHRM installer expects sequential SQL IDs 1-10 but Galera produces 1,4,7... | Use `installer/cli_install.php` (bypass the UI) + patch the CRUD assertions during install |
| 2 | Collation `utf8mb3 vs utf8mb4` during the LDAP sync (ldap_user_unique_id) | Mix of collations in the schema | `ALTER TABLE ohrm_user ohrm_user_auth_provider CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_uca1400_ai_ci` |
| 3 | LDAP sync: `Incorrect string value '\x85...'` in ldap_user_unique_id | `objectGUID` is non-UTF8 binary | `userUniqueIdAttribute: sAMAccountName` (not objectGUID) |
| 4 | "Multiple User Returned" after Keycloak login | OrangeHRM searches by `email` which is NULL for AD users | Patch `requestUserInfo('email')` → `requestUserInfo('preferred_username')` |
| 5 | redirect_uri in HTTP instead of HTTPS → Keycloak refuses | Apache behind Traefik ignores X-Forwarded-Proto | Add `SetEnvIfNoCase X-Forwarded-Proto https HTTPS=on` to `.htaccess` |

---

### Wazuh Dashboard — API Connected + OIDC (optional)

The Wazuh dashboard has an OpenSearch Security plugin with native OIDC support (already configured via the `wazuh-dashboard-config` ConfigMap). The SSO setup is only documented here for the **dashboard → manager API connection** (a prerequisite before SSO).

#### Trust the manager API cert (avoids dashboard AxiosError)

```bash
# 1. Regenerate the manager cert with proper SANs (the default cert has SAN=DNS:localhost only)
kubectl exec -n security wazuh-manager-0 -- bash -c "
cd /var/ossec/api/configuration/ssl
openssl req -x509 -newkey rsa:2048 -nodes -keyout server.key -out server.crt -days 3650 \
  -subj '/CN=wazuh-manager' \
  -addext 'subjectAltName=DNS:wazuh-manager,DNS:wazuh-manager.security,DNS:wazuh-manager.security.svc.cluster.local,DNS:localhost,IP:127.0.0.1'
chown wazuh:wazuh server.key server.crt && chmod 640 server.key server.crt
/var/ossec/bin/wazuh-control restart"

# 2. Extract + mount into the dashboard via ConfigMap (the 06-dashboard.yaml deployment already has the mount + postStart lifecycle)
kubectl exec -n security wazuh-manager-0 -- cat /var/ossec/api/configuration/ssl/server.crt > /tmp/w.crt
kubectl create configmap -n security wazuh-manager-api-ca --from-file=wazuh-manager-api-ca.crt=/tmp/w.crt --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment -n security wazuh-dashboard
# → the postStart lifecycle patches wazuh.yml with `ca: /usr/share/wazuh-dashboard/config/wazuh-manager-api-ca.crt`
```

#### Fix "Wazuh not ready yet" (API offline)

The uid of the `wazuh` user in the 4.8.x image is **999** (it used to be 1000). If `/var/ossec/var` was chowned to 1000 by an earlier version, the API crashes at startup:
```bash
kubectl exec -n security wazuh-manager-0 -- chown -R wazuh:wazuh /var/ossec/var /var/ossec/queue /var/ossec/logs
kubectl exec -n security wazuh-manager-0 -- rm -f /var/ossec/var/run/wazuh-apid.failed
kubectl exec -n security wazuh-manager-0 -- /var/ossec/bin/wazuh-control restart
```

The `10-security/wazuh/05-manager.yaml` manifest was fixed so the seed-pv initContainer detects the uid dynamically (`WAZUH_UID=$(awk -F: '/^wazuh:/{print $3":"$4}' /etc/passwd)`), so the fix survives future restarts.

## End-to-end tests

```bash
# Network: the app responds on its VIP
curl -I https://cloud.optavim.corp
curl -I https://erp.optavim.corp
curl -I https://rh.optavim.corp

# SSO: redirect to Keycloak
curl -sLI https://cloud.optavim.corp/apps/files/ | grep Location
# → must redirect to auth.optavim.corp
```
