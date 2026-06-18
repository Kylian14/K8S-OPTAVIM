# Dolibarr 19 — OIDC patch (3 cumulative fixes)

## Context

The `htdocs/core/login/functions_openid_connect.php` file of Dolibarr 19.0.4
has 3 distinct bugs that break OIDC auth in the OPTAVIM context. The patch
is applied via a ConfigMap mount (`04-oidc-patch-configmap.yaml`).

### Bug 1 — TypeError null check (incident 2026-06-07)
PHP 8 crashes with `property_exists(null, ...)` when `$token_content` or
`$userinfo_content` is null.

### Bug 2 — The 'aZ09' filter mangles the OIDC code (incident 2026-06-08)
`GETPOST('code', 'aZ09')` filter = strict alphanum, strips `.` and `-`.
But Keycloak codes have the format `UUID.UUID.UUID` (3 UUIDs separated
by dots, each containing dashes). Mangled → Keycloak rejects with
"invalid_grant".

### Bug 3 — getURLContent anti-SSRF (incident 2026-06-08)
`getURLContent()` rejects by default any URL resolving to a private IP:
> `Error bad hostname IP (private or reserved range). Must be an external URL.`

`auth.optavim.corp` resolves to `10.1.50.100` (internal HAProxy) → blocked.
Symptom: "Token request error 400" (http_code=400 comes from the Dolibarr
wrapper itself, not from Keycloak — Keycloak NEVER receives the request).
Fix: pass `$localurl=1` as the 7th param.

Stack trace observed (2026-06-07):
```
PHP Fatal error: Uncaught TypeError: property_exists(): Argument #1 ($object_or_class)
must be of type object|string, null given in /var/www/html/core/login/functions_openid_connect.php:74
```

## Possible causes of token_content = null

- `MAIN_AUTHENTICATION_OIDC_TOKEN_URL` not defined → POST to an empty URL
- Broken network between the Dolibarr pod and auth.optavim.corp
- HTTPS cert verify failure (incomplete CA bundle)
- Empty Keycloak response body (rare)

## Applied fix

The `functions_openid_connect.php` file is mounted read-only via the
ConfigMap `dolibarr-oidc-patch` (ns `apps`). The 2 occurrences of
`property_exists($x, ...)` are prefixed with `is_object($x) && ...`:

```diff
-if (property_exists($token_content, 'access_token')) {
+if (is_object($token_content) && property_exists($token_content, "access_token")) {
     ...
 }

-if (property_exists($userinfo_content, $login_claim)) {
+if (is_object($userinfo_content) && property_exists($userinfo_content, $login_claim)) {
     ...
 }
```

Apply via `kubectl patch`:
```bash
# Mount via ConfigMap volume
kubectl patch deployment -n apps dolibarr --type=json -p='[
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{
    "name":"oidc-patch","configMap":{"name":"dolibarr-oidc-patch"}}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{
    "name":"oidc-patch",
    "mountPath":"/var/www/html/core/login/functions_openid_connect.php",
    "subPath":"functions_openid_connect.php","readOnly":true}}
]'
```

## Maintenance

When Dolibarr ships a version that fixes this bug (upstream PR to follow),
remove the volumeMount + delete the ConfigMap.

## OIDC config required in Dolibarr (DB llx_const, ns apps)

```sql
INSERT INTO llx_const (name, type, value, entity) VALUES
('MAIN_AUTHENTICATION_OIDC_TOKEN_URL', 'chaine', 'https://auth.optavim.corp/realms/OPTAVIM/protocol/openid-connect/token', 1),
('MAIN_AUTHENTICATION_OIDC_USERINFO_URL', 'chaine', 'https://auth.optavim.corp/realms/OPTAVIM/protocol/openid-connect/userinfo', 1)
ON DUPLICATE KEY UPDATE value=VALUES(value);
```

Without these 2 rows, the OAuth POST goes to an empty URL → token_content=null
→ PHP crash.
