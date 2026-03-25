# openshift-pipelines-cleanup<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

Post-test best-effort cleanup step for OpenShift Pipelines e2e jobs.
Removes PipelineRuns, PersistentVolumeClaims, and test namespaces that carry the
label `openshift-pipelines.tekton.dev/test=true`.

Because the step is marked `best_effort: true`, any failure here will **not**
cause the overall CI job to fail — the cleanup result is informational only.

## Process

1. Set `KUBECONFIG` from `$SHARED_DIR/kubeconfig`.
2. Collect all namespaces labelled `openshift-pipelines.tekton.dev/test=true`.
3. If `CLEANUP_PIPELINERUNS=true`: delete all PipelineRuns in every labelled
   namespace (`--ignore-not-found=true`); log warnings on error.
4. If `CLEANUP_PVCS=true`: delete all PVCs in every labelled namespace;
   log warnings on error.
5. If `CLEANUP_NAMESPACES=true`: delete every labelled namespace
   (`--wait=false`) then wait up to 120 s for deletion; log warnings on error.

> **Note**: `set -o errexit` is intentionally **not** set. Every `oc` call is
> followed by `|| echo WARNING` so that a single failure does not abort the
> remainder of the cleanup.

## Prerequisite(s)

### Infrastructure

- A cluster that was targeted by the e2e test step (kubeconfig in `$SHARED_DIR`).

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CLEANUP_PIPELINERUNS` | `true` | Delete all PipelineRuns in labelled test namespaces. |
| `CLEANUP_PVCS` | `true` | Delete all PersistentVolumeClaims in labelled test namespaces. |
| `CLEANUP_NAMESPACES` | `true` | Delete all namespaces labelled `openshift-pipelines.tekton.dev/test=true`. |
