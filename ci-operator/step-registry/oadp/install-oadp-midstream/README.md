# oadp-install-oadp-midstream-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)

## Purpose

Install OADP operator from upstream (midstream) by running the OADP QE automation script `deploy_latest_upstream.sh`.

## Process

This step runs `operator/oadp/deploy_latest_upstream.sh` from the oadp-qe-automation repo. That script clones the oadp-operator repo from GitHub and deploys it (e.g. via OLM or direct manifests).

### Environment Variables

- `OWNER`
  - GitHub org/owner for the oadp-operator repo (default: openshift).
- `OADP_DEPLOY_BY_UPSTREAM_COMMIT`
  - Branch or commit to deploy from upstream (default: oadp-dev)
