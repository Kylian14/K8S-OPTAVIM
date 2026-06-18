#!/usr/bin/env python3
"""
Restriction de l'accès VPN road-warrior aux membres de GRP_VPN_Teletravail + admins.

À exécuter DANS le pod privacyidea-server (il a le contexte app + accès DB Galera) :
    POD=$(kubectl get pods -n identity -o name | grep privacyidea-server | head -1 | cut -d/ -f2)
    kubectl cp 07-vpn-group-restriction.py identity/$POD:/tmp/
    kubectl exec -n identity $POD -- python3 /tmp/07-vpn-group-restriction.py
    # puis rollout restart deployment/privacyidea-server -n identity (recharge le resolver)

Idempotent. La config est stockée en DB (privacyidea_db sur Galera) → durable aux reboots.
Ce script ne sert qu'à RE-créer la config si la DB privacyIDEA est repartie de zéro.

Mécanisme :
  1. Le resolver LDAP OPTAVIM-AD expose memberOf via le userinfo key "groups"
     (USERINFO += {"groups":"memberOf"}, MULTIVALUEATTRIBUTES=["groups"]).
  2. 5 policies scope=authorization :
       - vpn-authz-deny-default  (deny_access, prio 100, catch-all)
       - vpn-authz-teletravail   (grant_access, prio 10, groups contains GRP_VPN_Teletravail)
       - vpn-authz-admins-da/it/sec (grant_access, prio 10, groups contains Admins du domaine / IT_ADMINS / SECURITY_ADMINS)
  Priorité basse = précédence haute : un membre autorisé matche un grant (prio 10) qui l'emporte
  sur le deny (prio 100). Un non-membre ne matche que le deny → RADIUS reject → OpenVPN AUTH_FAILED.

NB : le resolver memberOf mapping (étape 1) n'est PAS fait ici (touche resolverconfig en DB) ;
voir le runbook. Ce script applique uniquement les policies (étape 2).
"""
from privacyidea.app import create_app
app = create_app(config_name="production", silent=True)

DN_VPN = "CN=GRP_VPN_Teletravail,OU=Groupes_VPN_SaaS,OU=Groupes_Securite,OU=OPTAVIM,DC=optavim,DC=corp"
DN_DA  = "CN=Admins du domaine,CN=Users,DC=optavim,DC=corp"
DN_IT  = "CN=IT_ADMINS,OU=Groupes_Securite,OU=OPTAVIM,DC=optavim,DC=corp"
DN_SEC = "CN=SECURITY_ADMINS,OU=Groupes_Securite,OU=OPTAVIM,DC=optavim,DC=corp"

with app.app_context():
    from privacyidea.lib.policy import set_policy

    def cond(dn):
        return [["userinfo", "groups", "contains", dn, True]]

    set_policy("vpn-authz-deny-default", scope="authorization",
               action="authorized=deny_access", priority=100)
    set_policy("vpn-authz-teletravail", scope="authorization",
               action="authorized=grant_access", priority=10, conditions=cond(DN_VPN))
    set_policy("vpn-authz-admins-da", scope="authorization",
               action="authorized=grant_access", priority=10, conditions=cond(DN_DA))
    set_policy("vpn-authz-admins-it", scope="authorization",
               action="authorized=grant_access", priority=10, conditions=cond(DN_IT))
    set_policy("vpn-authz-admins-sec", scope="authorization",
               action="authorized=grant_access", priority=10, conditions=cond(DN_SEC))
    print("VPN authorization policies applied (GRP_VPN_Teletravail + admins only).")
