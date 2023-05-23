# oadp-annotate-volsync-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)

## Purpose

 To add the `volsync.backube/privileged-movers='true'` annotation to the `openshift-adp` namespace in the test cluster.

 > **NOTE:**
 > 
 > This step is removed from other steps because it is not needed for OADP v1.0.x testing.

## Process

This script uses `oc` to create the annotation required.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  - This cluster should have a `openshift-adp` namespace.
  - This cluster should have the OADP operator installed in the `openshift-adp` namespace.
  - This cluster should have the Volsync operator installed in the `openshift-storage` namespace.