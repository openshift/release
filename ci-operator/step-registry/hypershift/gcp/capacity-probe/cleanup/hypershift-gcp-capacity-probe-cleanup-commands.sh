#!/usr/bin/env bash

set -euo pipefail

# Cleanup-phase validation for hypershift-gcp-capacity-probe.
#
# The probe step deletes its own VM on every exit path, but if that step was
# killed before its EXIT trap completed (e.g. SIGKILL after grace period), a
# probe VM may still exist in the ephemeral hosted cluster project. This step
# deletes any leaked instance by its deterministic name (sweeping all zones
# of the region, since the recorded zone may be missing or stale) and then
# verifies none remain.
#
# This step is best_effort: a failure is logged prominently but does not
# change the job result. hypershift-gcp-gke-deprovision and Hosted Cluster
# project deletion are further backstops.

# Authenticate with GCP via WIF credential written by hypershift-gcp-wif-auth.
# If the credential is unavailable there is nothing this step can do; the
# deprovision step (which can re-derive the credential) remains the backstop.
if [[ ! -f "${SHARED_DIR}/wif-cred.json" ]]; then
  echo "WARNING: ${SHARED_DIR}/wif-cred.json not found — skipping probe VM validation (hypershift-gcp-gke-deprovision remains the backstop)"
  exit 0
fi
gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json"

GCP_REGION="$(<"${SHARED_DIR}/gcp-region")"
HC_PROJECT_ID="$(<"${SHARED_DIR}/hosted-cluster-project-id")"

# Probe VM name: read from SHARED_DIR when available, otherwise reconstruct
# deterministically from PROW_JOB_ID (same derivation as the probe step).
if [[ -s "${SHARED_DIR}/gcp-capacity-probe-vm" ]]; then
  PROBE_VM_NAME="$(<"${SHARED_DIR}/gcp-capacity-probe-vm")"
elif [[ -n "${PROW_JOB_ID:-}" ]]; then
  PROBE_VM_NAME="ci-probe-$(echo -n "${PROW_JOB_ID}" | sha256sum | cut -c1-11)"
else
  echo "WARNING: cannot determine probe VM name (no SHARED_DIR file, no PROW_JOB_ID) — skipping probe VM validation"
  exit 0
fi

# Delete any leaked instance, sweeping all zones of the region (the recorded
# zone may be missing or the instance may linger in an earlier zone).
for zone in "${GCP_REGION}-a" "${GCP_REGION}-b" "${GCP_REGION}-c"; do
  gcloud compute instances delete "${PROBE_VM_NAME}" \
    --project="${HC_PROJECT_ID}" \
    --zone="${zone}" \
    --quiet || true
done

# Validation: no instance with the probe VM name may remain in the project.
REMAINING="$(gcloud compute instances list \
  --project="${HC_PROJECT_ID}" \
  --filter="name=${PROBE_VM_NAME}" \
  --format="value(name, zone)")"

if [[ -n "${REMAINING}" ]]; then
  echo "ERROR: GCP_CAPACITY_PROBE_VM_LEAK: probe VM still present after cleanup:"
  echo "${REMAINING}"
  exit 1
fi

echo "Probe VM validation passed: no leaked instance named ${PROBE_VM_NAME} in ${HC_PROJECT_ID}"
