# Keycloak deployment: Phase 6
## Apply order

```bash
# 1. Namespace + Secret
kubectl apply -f 00-namespace-secret.yaml

# 2. ResourceQuota
kubectl apply -f 04-resourcequota.yaml

# 2b. Provider .jar (sventorben/keycloak-restrict-client-auth v25.0.0 extension
#     for per-client OIDC RBAC: composite realm-role->client-role).
#     The binary is not in git; the ConfigMap is recreated by hand:
curl -sL -o /tmp/restrict.jar \
  'https://github.com/sventorben/keycloak-restrict-client-auth/releases/download/v25.0.0/keycloak-restrict-client-auth.jar'
kubectl create configmap keycloak-providers -n auth \
  --from-file=restrict-client-auth.jar=/tmp/restrict.jar

# 3. StatefulSet + Services
kubectl apply -f 01-statefulset.yaml

# 4. Traefik IngressRoute
kubectl apply -f 02-ingressroute.yaml

# 5. Check that the pods start (wait ~2-3 min)
kubectl get pods -n auth -w

# 6. Once both pods are Running, configure the Realm
chmod +x 03-post-deploy-realm.sh
./03-post-deploy-realm.sh
```

## Checks

```bash
# Pod status
kubectl get pods -n auth

# keycloak-0 logs
kubectl logs -n auth keycloak-0 -f

# Test access
curl -vk https://auth.optavim.corp/realms/master
```

## Parameters used

| Parameter         | Value                                               |
|-------------------|-----------------------------------------------------|
| Image             | quay.io/keycloak/keycloak:24.0.3                    |
| Replicas          | 2 (node anti-affinity)                              |
| Database          | keycloak_db on Galera (databases namespace)         |
| Domain            | auth.optavim.corp                                   |
| TLS               | optavim-wildcard-tls                                |
| LDAPS             | ldaps://10.1.20.1:636                               |
| Bind DN           | CN=svc_keycloak_ldap,OU=Comptes_Services,...        |
| User base         | OU=OPTAVIM,DC=optavim,DC=corp                       |
| Realm             | OPTAVIM                                             |
| MFA               | TOTP required                                       |
