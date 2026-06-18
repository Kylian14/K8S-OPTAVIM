# Security posture, OPTAVIM

> Security posture of the OPTAVIM Kubernetes manifests: secret hygiene, the workload hardening baseline, the accepted exceptions (with justification), and the scanners that run in CI.

This document describes the security posture of the repository: how secrets are managed, which hardening baseline is applied to workloads, and **which exceptions are accepted**, each with its justification. The goal is **explicit triage**, not suppression: every uncorrected alert is tracked and motivated below, and everything else fails CI.

---

## 1. Secret management

- **Every credential in the tree is a placeholder** of the form `CHANGE_ME` / `CHANGE_ME_*` (e.g. `CHANGE_ME_password`, `CHANGE_ME_ldap_bind_password`, `CHANGE_ME_minio_secret_key`). They must be filled in before any `kubectl apply`.
- **The real credentials from the original lab were removed and then rotated** before publication: no value in this repository grants access to anything.
- The versioned `Secret` manifests (e.g. [`07-keycloak/00-namespace-secret.yaml`](../07-keycloak/00-namespace-secret.yaml)) and the templates under [`07-keycloak/secrets-templates/`](../07-keycloak/secrets-templates/) exist only to **show the shape** of a secret, never to carry a real value.
- **CI guardrail: gitleaks.** The scan runs on every `push` / `pull_request`. The configuration ([`.gitleaks.toml`](../.gitleaks.toml)) extends the default ruleset (`[extend] useDefault = true`) and **only allows** the placeholders (`CHANGE_ME[_A-Za-z0-9]*`) and the template paths. Any value that is not a placeholder (in other words, a real secret left behind) **fails** CI.

---

## 2. Workload hardening baseline

Except for the exceptions documented in section 3, workloads apply the following `securityContext`, at the pod and/or container level:

| Control | Target value | Scope |
|---|---|---|
| `allowPrivilegeEscalation` | `false` | all containers |
| `capabilities.drop` | `["ALL"]` | all containers |
| `seccompProfile.type` | `RuntimeDefault` | all pods |
| `runAsNonRoot` | `true` | everywhere the image supports it |
| `readOnlyRootFilesystem` | `true` | everywhere it is safe (otherwise `emptyDir` on the writable paths) |
| `resources.limits` / `requests` | defined | all containers (anti-noisy-neighbor + per-namespace ResourceQuota) |
| `NetworkPolicy` | default-deny + explicit flows | per namespace |

This baseline matches the controls expected by **kube-linter** and **trivy config** (Pod Security `restricted` / KSV-*). The residual gaps are listed below.

---

## 3. Accepted exceptions (explicit triage)

Each line is a **deliberate gap justified by a technical constraint**, not an oversight. The exceptions are materialized in the code by the mechanisms honored in CI: `ignore-check.kube-linter.io/...` annotations, inline `# trivy:ignore:<id>` comments, per-folder `.trivyignore` files, and an optional `.kube-linter.yaml`.

| # | Workload | Gap | Justification |
|--:|---|---|---|
| 1 | **node-exporter** (`09-monitoring/node-exporter`) | `hostNetwork` / `hostPID` / `hostPort` + host mounts `/`, `/proc`, `/sys` in **read-only** | Required to read **node-level** metrics (host CPU/memory/disk/network). The host mounts are `readOnly: true`. |
| 2 | **wazuh indexer** (`10-security/wazuh/04-indexer.yaml`) | **privileged** initContainer | Sets `vm.max_map_count=262144` (sysctl), an OpenSearch prerequisite without which it refuses to start. The privilege is limited to the init container; the main container stays hardened. |
| 3 | **blackbox-exporter** (`09-monitoring/exporters/blackbox-exporter`) | **`NET_RAW`** capability | Required for **ICMP** probes (ping). Only this capability is added; all others are `drop ALL`. |
| 4 | **traefik ClusterRole** (`06-ingress/traefik/02-traefik-rbac.yaml`) | `get` / `list` / `watch` on `secrets` | Traefik needs to read the **TLS certificate secrets** to serve HTTPS. Read-only RBAC, no `create`/`update`/`delete`. |
| 5 | **ldap-sync CronJobs** (`08-apps/dolibarr/05-ldap-sync-cronjob.yaml`, `08-apps/orangehrm/04-ldap-sync-cronjob.yaml`) | `pods/exec` RBAC | Documented **idempotent** LDAP import, run via `kubectl exec` inside the application pod (`occ` / `symfony` CLI). RBAC limited to `exec` within the app namespace. |
| 6 | **LAMP applications** (`08-apps/nextcloud`, `08-apps/dolibarr`, `08-apps/orangehrm`) | `root` + **writable** rootfs | The official Apache images require a root entrypoint and a writable web root. Isolated by **dedicated namespace + NetworkPolicy + `allowPrivilegeEscalation: false` + `seccompProfile: RuntimeDefault`**. |
| 7 | **ConfigMaps flagged KSV-0109** (`08-privacyidea/05-radius-configmap.yaml`, `08-apps/dolibarr/04-oidc-patch-configmap.yaml`) | "secret" detected in a ConfigMap | False positive: the word `secret` is a **configuration template variable** (RADIUS) or **PHP code** (OIDC patch), not a stored credential. |

> Agents and maintainers may add exceptions to this table, but **only with the same rigor**: targeted workload, precise gap, technical justification, and mitigation.

---

## 4. Scanners run in CI

The [`.github/workflows/security.yml`](../.github/workflows/security.yml) workflow runs the following guards on every `push` and `pull_request` (`permissions: contents: read`):

| Scanner | Role | Configuration / exceptions |
|---|---|---|
| **gitleaks** | Secret detection in git history | [`.gitleaks.toml`](../.gitleaks.toml), allowlist of `CHANGE_ME*` placeholders |
| **trivy** (`config`) | Kubernetes misconfigurations (`CRITICAL,HIGH`, `exit-code 1`) | inline `# trivy:ignore:` comments + per-folder `.trivyignore` |
| **kube-linter** | Workload hardening lint | `ignore-check.kube-linter.io/...` annotations + `.kube-linter.yaml` |
| **kubeconform** | Manifest schema validation (`-strict`) | `-ignore-missing-schemas`; `helm-install.sh` scripts and pure CRD/issuer files (with no published schema) excluded |

**checkov** is also used as a complementary analysis (IaC / Kubernetes) on the same rule baseline; its findings are triaged with the same logic as the table in section 3.

---

_Spot a real secret left behind, or a poorly justified exception? Please report it privately (see [SECURITY.md](../SECURITY.md)) rather than opening a public issue._
