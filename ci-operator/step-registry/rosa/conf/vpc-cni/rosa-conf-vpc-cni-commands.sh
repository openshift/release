#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Installs the AWS VPC CNI onto a ROSA HCP cluster that was created with
# NO_CNI=true (rosa-cluster-provision --no-cni), following the procedure from
# https://github.com/phbergsmann/rosa-vpc-cni:
#   1. IRSA role trusting system:serviceaccount:kube-system:aws-node, with the
#      AWS-managed AmazonEKS_CNI_Policy attached
#   2. hostaccess/privileged SCCs for the aws-node service account
#   3. ip_forward=1 tuning config (must go through the rosa CLI: on HCP the
#      Node Tuning Operator reconciles away Tuned CRs applied with oc)
#   4. helm install eks/aws-vpc-cni with ROSA/CRI-O host-path overrides
# After a successful install the step records cni=aws-vpc-cni in the SHARED_DIR
# contract (cluster-metadata.json) so the provisioner-agnostic validation tail
# can condition on the CNI type (ROSAENG-67432, ROSAENG-308).

umask 0077

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

if [[ ! -s "${SHARED_DIR}/cluster-id" ]]; then
  log "ERROR: ${SHARED_DIR}/cluster-id is missing; rosa-cluster-provision must run before this step"
  exit 1
fi
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

# ---- AWS credentials and rosa login (cluster profile) ----
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
else
  log "ERROR: no ${AWSCRED} in the cluster profile; cannot configure the AWS CLI"
  exit 1
fi

# Do not trace credential reads / rosa login.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with an offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  $WAS_TRACING && set -x
  log "ERROR: no rosa/OCM credentials found in cluster profile (sso-client-id/secret or ocm-token)"
  exit 1
fi
$WAS_TRACING && set -x

# The cluster is not functional yet (nodes NotReady), so use the breakglass
# admin kubeconfig rather than the customer kubeconfig. The test container
# ships an ambient KUBECONFIG pointing at the CI namespace service account,
# which has no rights on the cluster under test — always override it. If no
# kubeconfig was produced yet, fetch one from the OCM credentials API (the
# osd-ccs admin-kubeconfig step is not usable here: it requires an ocm-token
# in the cluster profile, while the rosa profiles carry SSO client
# credentials).
if [[ ! -s "${SHARED_DIR}/kubeconfig.kubeadmin" && ! -s "${SHARED_DIR}/kubeconfig" ]]; then
  # Do not trace the OCM login.
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    log "Logging into OCM (${OCM_LOGIN_ENV}) with SSO credentials"
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
  elif [[ -n "${ROSA_TOKEN}" ]]; then
    log "Logging into OCM (${OCM_LOGIN_ENV}) with an offline token"
    ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  else
    $WAS_TRACING && set -x
    log "ERROR: no OCM credentials found in cluster profile (sso-client-id/secret or ocm-token)"
    exit 1
  fi
  $WAS_TRACING && set -x
  ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" \
    | jq -r .kubeconfig > "${SHARED_DIR}/kubeconfig.kubeadmin"
  chmod 0600 "${SHARED_DIR}/kubeconfig.kubeadmin"
  log "Fetched the breakglass admin kubeconfig from OCM"
fi
if [[ -s "${SHARED_DIR}/kubeconfig.kubeadmin" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig.kubeadmin"
elif [[ -s "${SHARED_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
else
  log "ERROR: no kubeconfig found in ${SHARED_DIR} (kubeconfig.kubeadmin or kubeconfig)"
  exit 1
fi
log "Using kubeconfig ${KUBECONFIG} for cluster ${CLUSTER_ID}"

# AWS region from the contract, falling back to the REGION env.
REGION_FALLBACK="${REGION:-}"
REGION=$(jq -r '.region // empty' "${SHARED_DIR}/cluster-metadata.json" 2>/dev/null || true)
REGION="${REGION:-${REGION_FALLBACK}}"
if [[ -z "${REGION}" ]]; then
  log "ERROR: no AWS region available (cluster-metadata.json or REGION env)"
  exit 1
fi
export AWS_DEFAULT_REGION="${REGION}"

# ---- IAM role for the VPC CNI (IRSA) ----
CLUSTER_JSON=$(rosa describe cluster -c "${CLUSTER_ID}" -o json)
OIDC_PROVIDER=$(jq -r '.aws.sts.oidc_endpoint_url' <<<"${CLUSTER_JSON}" | sed 's|https://||')
if [[ -z "${OIDC_PROVIDER}" || "${OIDC_PROVIDER}" == "null" ]]; then
  log "ERROR: cluster ${CLUSTER_ID} has no OIDC endpoint; AWS VPC CNI needs an STS cluster"
  exit 1
fi
# Prefer the account id from the cluster profile; fall back to the logged-in
# rosa user (profiles without an aws-account-id file).
if [[ -s "${CLUSTER_PROFILE_DIR}/aws-account-id" ]]; then
  AWS_ACCOUNT_ID=$(head -n 1 "${CLUSTER_PROFILE_DIR}/aws-account-id")
else
  AWS_ACCOUNT_ID=$(rosa whoami --output json | jq -r '."AWS Account ID"')
fi
IAM_ROLE_NAME="${CLUSTER_ID}-vpc-cni"

# The AWS-managed policy is required: custom policies with tag conditions do
# not work because the VPC CNI tags ENIs with node.k8s.amazonaws.com/* and the
# primary ENI (created by AWS) carries no CNI-managed tags.
TRUST_POLICY=$(mktemp)
cat > "${TRUST_POLICY}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:aws-node"
        }
      }
    }
  ]
}
EOF

# Remember the role for the post steps before creating it: if create-role or
# attach-role-policy fails, rosa-conf-vpc-cni-role-delete must still be able
# to find and remove it. rosa-aws-sts-hcp-deprovision does not know about it
# and would leak it.
echo -n "${IAM_ROLE_NAME}" > "${SHARED_DIR}/aws-vpc-cni-role-name"

if aws iam get-role --role-name "${IAM_ROLE_NAME}" >/dev/null 2>&1; then
  log "IAM role ${IAM_ROLE_NAME} already exists, reusing it"
else
  aws iam create-role \
    --role-name "${IAM_ROLE_NAME}" \
    --assume-role-policy-document "file://${TRUST_POLICY}" \
    --description "IAM Role for AWS VPC CNI on ROSA (CI cluster ${CLUSTER_ID})"
fi
aws iam attach-role-policy \
  --role-name "${IAM_ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
rm -f "${TRUST_POLICY}"

# ---- SCCs for the aws-node service account ----
oc adm policy add-scc-to-user hostaccess -z aws-node -n kube-system
oc adm policy add-scc-to-user privileged -z aws-node -n kube-system

# ---- IP forwarding tuning config (required by the VPC CNI) ----
# RHCOS nodes disable IP forwarding by default. On HCP, Tuned CRs applied with
# oc are reconciled away by the hosted Node Tuning Operator, so the rosa CLI
# tuning-config must be used instead.
IP_FORWARD_SPEC=$(mktemp)
cat > "${IP_FORWARD_SPEC}" <<'EOF'
{
  "profile": [
    {
      "name": "ip-forward-vpc-cni",
      "data": "[main]\nsummary=Enable IP forwarding for AWS VPC CNI\ninclude=openshift-node\n[sysctl]\nnet.ipv4.ip_forward=1\n"
    }
  ],
  "recommend": [
    {
      "profile": "ip-forward-vpc-cni",
      "priority": 5
    }
  ]
}
EOF
rosa create tuning-config -c "${CLUSTER_ID}" --name ip-forward --spec-path "${IP_FORWARD_SPEC}"
rosa edit machinepool -c "${CLUSTER_ID}" workers --tuning-configs ip-forward
rm -f "${IP_FORWARD_SPEC}"

# ---- Install the AWS VPC CNI helm chart ----
# ROSA uses CRI-O, which keeps CNI binaries and configs in different host
# paths than the containerd-based EKS defaults the chart assumes:
#   binaries: /var/lib/cni/bin (EKS: /opt/cni/bin)
#   config:   /run/multus/cni/net.d (EKS: /etc/cni/net.d)
# The values below mount those host paths and point the init and node agent
# containers at them via HOST_CNI_BIN_PATH / HOST_CNI_CONFDIR_PATH.
if ! command -v helm >/dev/null 2>&1; then
  log "Installing helm ${HELM_VERSION}"
  curl -sSfL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz
  tar -C /tmp -xzf /tmp/helm.tgz
  install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
  rm -rf /tmp/helm.tgz /tmp/linux-amd64
fi

VALUES_FILE=$(mktemp)
cat > "${VALUES_FILE}" <<EOF
init:
  image:
    region: ${REGION}
  env:
    HOST_CNI_BIN_PATH: /host/var/lib/cni/bin
    HOST_CNI_CONFDIR_PATH: /host/run/multus/cni/net.d

nodeAgent:
  image:
    region: ${REGION}

image:
  region: ${REGION}

env:
  AWS_VPC_ENI_MTU: "1500"
  ENI_CONFIG_LABEL_DEF: "failure-domain.beta.kubernetes.io/zone"
  POD_SECURITY_GROUP_ENFORCING_MODE: "standard"
  HOST_CNI_BIN_PATH: /host/var/lib/cni/bin
  HOST_CNI_CONFDIR_PATH: /host/run/multus/cni/net.d

extraVolumeMounts:
  - name: cni-bin-dir-rosa
    mountPath: /host/var/lib/cni/bin
  - name: multus-cni-dir
    mountPath: /host/run/multus/cni/net.d

extraVolumes:
  - name: cni-bin-dir-rosa
    hostPath:
      path: /var/lib/cni/bin
  - name: multus-cni-dir
    hostPath:
      path: /run/multus/cni/net.d

serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}
EOF

helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-vpc-cni \
  --namespace kube-system \
  eks/aws-vpc-cni \
  --version "${VPC_CNI_CHART_VERSION}" \
  --values "${VALUES_FILE}"
rm -f "${VALUES_FILE}"

# ---- Wait for the aws-node DaemonSet and the nodes ----
# Rollout wait rather than waiting on pods: right after helm install the
# DaemonSet controller may not have created any pods yet, and oc wait on pods
# would fail with "no matching resources found".
log "Waiting for the aws-node DaemonSet rollout"
oc rollout status daemonset/aws-node -n kube-system --timeout=15m

log "Waiting for nodes to become Ready"
oc wait --for=condition=Ready node --all --timeout=30m

# ---- Record the CNI in the SHARED_DIR contract ----
# Write the marker first: rosa-e2e-rosa-cli-publish-contract (which may run
# after this step and rebuild cluster-metadata.json) includes it as the
# contract's cni field. If cluster-metadata.json already exists (a workflow
# that published the contract before swapping the CNI), update it in place
# too. Additive to the ROSAENG-67580 schema: validators ignore unknown fields,
# so heads that do not run this step are unaffected.
echo -n "aws-vpc-cni" > "${SHARED_DIR}/cni"
if [[ -s "${SHARED_DIR}/cluster-metadata.json" ]]; then
  jq '. + {cni: "aws-vpc-cni"}' "${SHARED_DIR}/cluster-metadata.json" > "${SHARED_DIR}/cluster-metadata.json.tmp" \
    && mv "${SHARED_DIR}/cluster-metadata.json.tmp" "${SHARED_DIR}/cluster-metadata.json"
  log "Recorded cni=aws-vpc-cni in cluster-metadata.json"
fi

log "AWS VPC CNI installed successfully"
