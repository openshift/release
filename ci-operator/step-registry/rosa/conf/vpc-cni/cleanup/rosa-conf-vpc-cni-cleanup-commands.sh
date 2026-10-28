#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Cleans up after rosa-conf-vpc-cni: removes the IRSA IAM role the standard
# deprovision chain does not know about, and undoes the in-cluster changes
# (SCCs for the aws-node service account) while the cluster is still up. Run
# it before rosa-cluster-deprovision. The helm release and the tuning config
# are in-cluster only and are removed with the cluster itself.

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# AWS credentials from the cluster profile; without them the aws iam calls
# below would fail unauthenticated.
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
else
  log "ERROR: no ${AWSCRED} in the cluster profile; cannot configure the AWS CLI"
  exit 1
fi

# ---- Remove the SCCs granted to the aws-node service account ----
# In-cluster only, but undo it here so the step is symmetric with
# rosa-conf-vpc-cni and the pattern is reusable on a cluster that survives.
# Best-effort: the cluster may already be unreachable (e.g. an earlier post
# step failed hard), and this must not block the IAM cleanup below.
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -s "${SHARED_DIR}/kubeconfig.kubeadmin" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig.kubeadmin"
  elif [[ -s "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  fi
fi
if [[ -n "${KUBECONFIG:-}" ]]; then
  for scc in hostaccess privileged; do
    if oc adm policy remove-scc-from-user "${scc}" -z aws-node -n kube-system; then
      log "Removed SCC ${scc} from the aws-node service account"
    else
      log "WARN: could not remove SCC ${scc} (cluster unreachable or already cleaned up)"
    fi
  done
else
  log "No kubeconfig in ${SHARED_DIR}; skipping the SCC cleanup"
fi

# ---- Delete the IRSA role ----
if [[ ! -s "${SHARED_DIR}/aws-vpc-cni-role-name" ]]; then
  log "No aws-vpc-cni-role-name in ${SHARED_DIR}; nothing to do"
  exit 0
fi
IAM_ROLE_NAME=$(cat "${SHARED_DIR}/aws-vpc-cni-role-name")

# Only a NoSuchEntity get-role failure means the role is already gone; any
# other failure (credentials, throttling, network) must fail the step rather
# than silently delete the marker and leak the role.
if err=$(aws iam get-role --role-name "${IAM_ROLE_NAME}" 2>&1 >/dev/null); then
  aws iam detach-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy || true
  aws iam delete-role --role-name "${IAM_ROLE_NAME}"
  log "Deleted IAM role ${IAM_ROLE_NAME}"
elif grep -q 'NoSuchEntity' <<<"${err}"; then
  log "IAM role ${IAM_ROLE_NAME} already gone"
else
  log "ERROR: cannot query IAM role ${IAM_ROLE_NAME}: ${err}"
  exit 1
fi
rm -f "${SHARED_DIR}/aws-vpc-cni-role-name"
