# OPTAVIM, documentation index

> Index of the `docs/` folder. Component-level deep dives live next to their manifests (links at the bottom).

This index lists the documents in `docs/`, grouped by topic. One sentence per document describes what it covers.

## Overview

- [**Project write-up (article)**](https://knezan.fr/articles/optavim-si-entreprise-complet) Building a fictional company's IT system from scratch, from the firewall to the line-of-business applications, with security as the guiding thread. Hosted on knezan.fr.

## Architecture

- [`CARTOGRAPHY_OPTAVIM.md`](CARTOGRAPHY_OPTAVIM.md) Infrastructure cartography: the datacenter that is actually deployed (pfSense, K8s cluster, AD, NFS HA, Rennes branch office) and the three scenario site types that extend the architecture into a multi-site enterprise IT system.

## Observability

- [`MONITORING_DASHBOARDS.md`](MONITORING_DASHBOARDS.md) The homelab Grafana suite: the Prometheus / node-exporter / kube-state-metrics stack and the associated dashboards.

## Security

- [`SECURITY-posture.md`](SECURITY-posture.md) Security posture of the repository: secret hygiene, the workload hardening baseline, the accepted exceptions (with justification), and the scanners that run in CI.

---

## Component-level deep dives (outside `docs/`)

Some building blocks are documented directly next to their manifests:

- [`08-apps/README.md`](../08-apps/README.md) Overview of the deployed line-of-business applications.
- [`08-apps/dolibarr/03-oidc-patch.md`](../08-apps/dolibarr/03-oidc-patch.md) Dolibarr OIDC patch.
- [`08-apps/nextcloud/03-ldap-failover.md`](../08-apps/nextcloud/03-ldap-failover.md) Nextcloud LDAP failover.
- [`08-privacyidea/README.md`](../08-privacyidea/README.md) privacyIDEA deployment (2FA / OTP).
