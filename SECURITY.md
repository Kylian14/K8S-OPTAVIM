# Security

This repository is a **homelab / portfolio** project: it documents a multi-site
enterprise IT architecture study and hosts no real production data or service.

## Secrets and credentials

- Every credential in the tree is a **placeholder** (`CHANGE_ME_*`) or an example
  value. They must be filled in before any `apply`.
- The passwords from the original lab have been **removed / rotated**: they grant
  access to nothing.
- The original public IP addresses have been replaced with placeholders. The
  RFC1918 ranges (`10.x` / `172.16-31.x` / `192.168.x`) are kept because they are
  part of the architecture story and are not routable.

## Reporting a security issue

If you spot a real leftover secret or any other security issue in this
repository, please report it privately by email to **kylian.nezan@gmail.com**
rather than opening a public issue.
