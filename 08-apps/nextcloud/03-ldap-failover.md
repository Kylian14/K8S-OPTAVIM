# Nextcloud — LDAP failover config across 3 DCs

## Failover pattern

Nextcloud `user_ldap` supports several simultaneous LDAP configurations
(s01, s02, s03...). On each request, the plugin iterates sequentially over
all active configs until it finds the user.

For OPTAVIM (3 AD DCs: DC-01, DC-02, DC-03):

| Config | LDAP Host | Role |
|---|---|---|
| s01 | `ldaps://DC-AD-DC-01.optavim.corp:636` | primary |
| s02 | `ldaps://DC-AD-DC-02.optavim.corp:636` | failover #1 |
| s03 | `ldaps://DC-AD-DC-03.optavim.corp:636` | failover #2 |

## Critical timeout

Without a short timeout, if DC-01 goes down, every Nextcloud HTTP request
waits 30s (default LDAP) before failing over to DC-02 → the user sees a timeout.

**Fix**: `ldapNetworkTimeout=3` on each config. With a DC down, the worst
case is 3s of waiting on the config that times out, then failover to the
next one. If DC-01+DC-02 are down: 6s max added latency, then DC-03
responds. Acceptable.

## Apply

From the Nextcloud pod:

```bash
NEXT=$(kubectl get pod -n apps -l app=nextcloud -o jsonpath='{.items[0].metadata.name}')

# Re-enable the 3 configs (in case some are active=0)
for ID in s01 s02 s03; do
  kubectl exec -n apps $NEXT -- runuser -u www-data -- \
    php /var/www/html/occ ldap:set-config "$ID" ldapConfigurationActive 1
done

# Force the network timeout to 3s (fast failover)
for ID in s01 s02 s03; do
  kubectl exec -n apps $NEXT -- runuser -u www-data -- \
    php /var/www/html/occ ldap:set-config "$ID" ldapNetworkTimeout 3
done

# Verify
kubectl exec -n apps $NEXT -- runuser -u www-data -- \
  php /var/www/html/occ ldap:show-config | \
  grep -E 'Configuration|ldapHost|ldapConfigurationActive|ldapNetworkTimeout'
```

## Logs / debug

A recurring "Lost connection to LDAP server" error in
`/var/www/html/data/nextcloud.log` = a DC declared active is down.
Check the hostnames via `ldap:show-config` and `getent hosts dc-ad-dc-XX`.

Direct connectivity test from the pod:
```bash
kubectl exec -n apps $NEXT -- bash -c '
  for ip in 10.1.20.1 10.1.20.2 10.1.20.3; do
    timeout 3 bash -c "echo > /dev/tcp/$ip/636" 2>&1 \
      && echo "$ip LDAPS UP" || echo "$ip LDAPS DOWN"
  done'
```

## Real failover test

```bash
# Take down DC-01 → check that login still works (via s02 or s03)
# Expected RTO: 3-6 seconds max
```
