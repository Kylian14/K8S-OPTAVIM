# 08-privacyidea — TOTP MFA for the teleworking OpenVPN

Deployment of [privacyIDEA](https://privacyidea.org) in the OPTAVIM K8s cluster to add **TOTP MFA (RFC 6238)** to the pfSense client-to-site OpenVPN.

## Architecture

```
OpenVPN client (laptop)
  │ AD password + TOTP via Tunnelblick/OpenVPN Connect
  ▼
pfSense (NAT WAN <BASTION_PUBLIC_IP>:10449/UDP)
  │ Auth backend = RADIUS_pi
  ▼
nginx UDP stream on HAP-01/02 (VIP 10.1.50.100:1812)
  │
  ▼
NodePort UDP 31812 on the 3 K8s workers
  │
  ▼
Pod privacyidea-radius (FreeRADIUS + rlm_exec → curl API)
  │ POST /validate/check
  ▼
Pod privacyidea-server (Flask + Gunicorn)
  │
  ├─► LDAPS DC-01:636 (AD resolver, bind svc_privacyidea_ldap)
  │   → users imported on the fly
  │
  └─► MariaDB Galera (DB privacyidea_db, encrypted TOTP secrets)

SELF-SERVICE PORTAL: https://mfa.optavim.corp
  → user logs in with AD password → enrolls TOTP via QR code
```

## Files

| File | Role |
|---|---|
| `00-namespace.yaml` | Namespace `identity` |
| `01-certificate.yaml` | Wildcard cert `*.optavim.corp` via cert-manager + AD CS issuer |
| `02-pvc.yaml` | NFS PV/PVC for `/etc/privacyidea` (configs + enckey + audit keys) |
| `03-server-deployment.yaml` | Deployment + ClusterIP Service for the web server (Python Gunicorn) |
| `04-ingressroute.yaml` | Traefik IngressRoute for `mfa.optavim.corp` (HTTPS) |
| `05-radius-configmap.yaml` | FreeRADIUS config (NAS clients + exec module + default site) |
| `06-radius-deployment.yaml` | Deployment + NodePort UDP 31812 Service for the RADIUS module |

## Custom Docker image

The official `freeradius/freeradius-server:latest` image is buggy (0-byte binary). A custom image is used:

```
FROM ubuntu:22.04
RUN apt-get install -y freeradius freeradius-utils curl ca-certificates
CMD ["freeradius", "-X", "-d", "/etc/freeradius/3.0"]
```

Tag: `optavim/freeradius-pi:2.0`. Built on the bastion + distributed to the 3 workers via `ctr -n=k8s.io images import`.

If the images are lost on a worker (re-image, etc.), rebuild and redistribute.

## K8s Secret `privacyidea-secret`

Created manually (kept out of the repo because it contains passwords). 5 keys:

| Key | Detail |
|---|---|
| `PI_DB_PASSWORD` | Galera user `privacyidea@%` for the `privacyidea_db` DB |
| `PI_ADMIN_PASSWORD` | privacyIDEA local admin for the portal |
| `PI_RADIUS_SHARED_SECRET` | RADIUS shared secret pfSense ↔ FreeRADIUS pod |
| `PI_ENCKEY` | Symmetric key to encrypt the TOTP secrets in the DB |
| `LDAP_BIND_PASSWORD` | Password of the service account `svc_privacyidea_ldap@optavim.corp` |

The passwords are stored in the admin password manager (out of repo).

## Required external components (pre-deployment)

- AD account `svc_privacyidea_ldap` (created in `OU=Comptes_Services,OU=Administration,OU=OPTAVIM`)
- AD group `VPN-Break-Glass` (in `OU=Groupes_Securite,OU=OPTAVIM`)
- DB `privacyidea_db` managed by MariaDB Operator (cf. `05-databases/mariadb-operator/04-databases.yaml`)
- NFS export `/data/exports/privacyidea` on NFS-01 (DRBD primary)
- DNS A-record `mfa.optavim.corp` → `10.1.50.100` (HAProxy VIP)
- nginx UDP stream installed on HAP-01 and HAP-02 (forward `*:1812` → workers `*:31812`)
- pfSense firewall rule `OPT_HAPROXY → OPT_K8S:31812/UDP`
- pfSense firewall rule `OPT_AD → any UDP/TCP 53` (external DNS recursion for pulls)

## pfSense OpenVPN — final config

| Field | Value |
|---|---|
| Backend for authentication | `RADIUS_pi` (then `LDAP_AD_break_glass` as admin fallback) |
| `RADIUS_pi` host | `10.1.50.100:1812` (HAProxy VIP) |
| `RADIUS_pi` shared secret | (= `PI_RADIUS_SHARED_SECRET` from the K8s Secret) |
| Strict User-CN Matching | ❌ unchecked |

OpenVPN user: a single "vpn-shared" cert distributed in the `.ovpn`. RADIUS authenticates the user via RADIUS PAP with the AD password + the 6-digit TOTP appended.

## privacyIDEA configuration (initial, via API)

See `07-post-deploy.sh` (to be created if a from-scratch redeploy is needed). Steps:

1. LDAP resolver `OPTAVIM-AD` (bind `svc_privacyidea_ldap`)
2. Realm `OPTAVIM` (default)
3. Policy `concat-pin-otp`: `otppin=userstore` (PIN = LDAP password, OTP concatenated)

## User self-service procedure

See `USER_GUIDE.md` in this directory.
