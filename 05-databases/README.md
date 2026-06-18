# 05-databases: OPTAVIM database

> Signpost: which implementation is current and which is legacy.

## Current state

The database is now **MariaDB Operator** (`mariadb-operator/`). This is the **target** and the **current** implementation.

- **`mariadb-operator/`**: **TARGET / CURRENT.** MariaDB cluster managed by the operator (Galera mode). The whole stack is driven by CRDs (`MariaDB`, `Database`, `User`, `Grant`, `Connection`, `Backup`).
- **`galera/`**: **LEGACY, being decommissioned.** Hand-rolled Galera StatefulSet (Secret + ConfigMap + Services + StatefulSet). Kept during the cutover, slated for removal.

> Compatibility note: the volumes and the `Service` keep `galera-*` names so that applications connecting by DNS name are not broken. **The name is historical, the underlying technology is the operator.** Do not infer that the current database is the Galera StatefulSet.

## Consistency fix

Any residual mention of "**Galera (StatefulSet 3r)**" as the current database (in docs, diagrams, or comments) is **wrong** and must be corrected to:

> **MariaDB Operator** (Galera = legacy).
