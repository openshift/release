#!/bin/bash
set -euo pipefail

# Set cloud-specific defaults
if [[ "${CLOUD_PROVIDER}" == "Azure" ]]; then
  export KUBECONFIG=/etc/hypershift-kubeconfig-azure/hypershift-ops-admin.kubeconfig
  AZURE_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-self-managed-azure/credentials.json"
  DEFAULT_BASE_DOMAIN=hcp-sm-azure.azure.devcluster.openshift.com
  HYPERSHIFT_INSTANCE_TYPE=Standard_D16s_v5
  HYPERSHIFT_AZURE_LOCATION=${HYPERSHIFT_AZURE_LOCATION:-centralus}
else
  AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"
  DEFAULT_BASE_DOMAIN=ci.hypershift.devcluster.openshift.com
  export KUBECONFIG=/etc/hypershift-kubeconfig/hypershift-ops-admin.kubeconfig

  if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
    AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    DEFAULT_BASE_DOMAIN=origin-ci-int-aws.dev.rhcloud.com
  fi
fi

DOMAIN=${HYPERSHIFT_BASE_DOMAIN:-$DEFAULT_BASE_DOMAIN}
DEFAULT_RELEASE_STREAM=4-stable
HYPERSHIFT_HC_RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-quay.io/openshift-release-dev/ocp-release:4.22.0-ec.5-multi}

CLUSTER_NAME_PREFIX="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-10)"
if [[ -n "${HYPERSHIFT_CLUSTER_ROLE}" ]]; then
  if [[ ! "${HYPERSHIFT_CLUSTER_ROLE}" =~ ^[a-z0-9-]+$ ]]; then
    echo "HYPERSHIFT_CLUSTER_ROLE must contain only lowercase letters, digits, or hyphens" >&2
    exit 1
  fi
  CLUSTER_NAME="${CLUSTER_NAME_PREFIX}-${HYPERSHIFT_CLUSTER_ROLE}-mgmt"
  MANAGEMENT_CLUSTER_KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig_${HYPERSHIFT_CLUSTER_ROLE}"
  KUBECONFIG_OUTPUT="${SHARED_DIR}/kubeconfig_${HYPERSHIFT_CLUSTER_ROLE}"
  MANAGEMENT_CLUSTER_NAMESPACE_FILE="${SHARED_DIR}/management_cluster_namespace_${HYPERSHIFT_CLUSTER_ROLE}"
  MANAGEMENT_CLUSTER_NAME_FILE="${SHARED_DIR}/management_cluster_name_${HYPERSHIFT_CLUSTER_ROLE}"
  KUBEADMIN_PASSWORD_FILE="${SHARED_DIR}/kubeadmin-password_${HYPERSHIFT_CLUSTER_ROLE}"
  CONSOLE_URL_FILE="${SHARED_DIR}/console.url_${HYPERSHIFT_CLUSTER_ROLE}"
else
  CLUSTER_NAME="${CLUSTER_NAME_PREFIX}-mgmt"
  MANAGEMENT_CLUSTER_KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
  KUBECONFIG_OUTPUT="${SHARED_DIR}/kubeconfig"
  MANAGEMENT_CLUSTER_NAMESPACE_FILE="${SHARED_DIR}/management_cluster_namespace"
  MANAGEMENT_CLUSTER_NAME_FILE="${SHARED_DIR}/management_cluster_name"
  KUBEADMIN_PASSWORD_FILE="${SHARED_DIR}/kubeadmin-password"
  CONSOLE_URL_FILE="${SHARED_DIR}/console.url"
fi

# Create the management cluster based on cloud provider
if [[ "${CLOUD_PROVIDER}" == "Azure" ]]; then
  echo "Creating Azure management cluster ${CLUSTER_NAME} with ${HYPERSHIFT_NODE_COUNT} nodes"
  AZURE_WORKLOAD_IDENTITIES_FILE="/etc/hypershift-ci-jobs-self-managed-azure-e2e-mc/workload-identities.json"
  AZURE_OIDC_ISSUER_URL="https://smazure.blob.core.windows.net/smazure"
  AZURE_SA_TOKEN_ISSUER_KEY_PATH="/etc/hypershift-ci-jobs-self-managed-azure/serviceaccount-signer.private"
  # Ensure Premium SSD v2 StorageClass exists on the ops cluster for mgmt cluster etcd
  oc apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi-premium-v2
provisioner: disk.csi.azure.com
parameters:
  skuName: PremiumV2_LRS
  cachingMode: None
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
  bin/hypershift create cluster azure \
    --annotations=hypershift.openshift.io/prow-job-id=${PROW_JOB_ID} \
    --pull-secret=/etc/ci-pull-credentials/.dockerconfigjson \
    --azure-creds=${AZURE_GUEST_INFRA_CREDENTIALS_FILE} \
    --workload-identities-file=${AZURE_WORKLOAD_IDENTITIES_FILE} \
    --oidc-issuer-url=${AZURE_OIDC_ISSUER_URL} \
    --sa-token-issuer-private-key-path=${AZURE_SA_TOKEN_ISSUER_KEY_PATH} \
    --name=${CLUSTER_NAME} \
    --location=${HYPERSHIFT_AZURE_LOCATION} \
    --infra-id=${CLUSTER_NAME} \
    --base-domain=${DOMAIN} \
    --instance-type=${HYPERSHIFT_INSTANCE_TYPE} \
    --marketplace-publisher=${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER} \
    --marketplace-offer=${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER} \
    --marketplace-sku=${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_SKU} \
    --marketplace-version=${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_VERSION} \
    --service-cidr=172.29.0.0/16 \
    --cluster-cidr=10.124.0.0/14 \
    --node-pool-replicas=${HYPERSHIFT_NODE_COUNT} \
    --availability-zones=1,2,3 \
    --release-image=${HYPERSHIFT_HC_RELEASE_IMAGE} \
    --release-stream=${DEFAULT_RELEASE_STREAM} \
    --namespace=${HYPERSHIFT_NAMESPACE} \
    --assign-service-principal-roles \
    --dns-zone-rg-name=os4-common \
    --etcd-storage-class=managed-csi-premium-v2
else
  echo "Creating AWS management cluster ${CLUSTER_NAME} with $((${HYPERSHIFT_NODE_COUNT} * 3)) nodes"
  AWS_CREATE_ARGS=(
    "--annotations=hypershift.openshift.io/prow-job-id=${PROW_JOB_ID}"
    --pull-secret=/etc/ci-pull-credentials/.dockerconfigjson
    "--aws-creds=${AWS_GUEST_INFRA_CREDENTIALS_FILE}"
    --additional-tags="expirationDate=$(date -d '4 hours' --iso=minutes --utc)"
    "--name=${CLUSTER_NAME}"
    --region=us-east-1
    "--infra-id=${CLUSTER_NAME}"
    "--base-domain=${DOMAIN}"
    --oidc-issuer-url=https://hypershift-ci-2-oidc.s3.us-east-1.amazonaws.com/shared-mgmt
    --sa-token-issuer-private-key-path=/etc/hypershift-ci-jobs-awscreds/serviceaccount-signer.private
    "--instance-type=${HYPERSHIFT_INSTANCE_TYPE}"
    "--zones=${HYPERSHIFT_ZONES}"
    --service-cidr=172.29.0.0/16
    --cluster-cidr=10.124.0.0/14
    "--node-pool-replicas=${HYPERSHIFT_NODE_COUNT}"
    --node-selector=hypershift.openshift.io/control-plane=true
    "--release-image=${HYPERSHIFT_HC_RELEASE_IMAGE}"
    "--release-stream=${DEFAULT_RELEASE_STREAM}"
    --public-only
    --shared-role
    "--namespace=${HYPERSHIFT_NAMESPACE}"
  )

  if [[ -z "${HYPERSHIFT_MGMT_ADDITIONAL_TRUST_BUNDLE:-}" ]]; then
    bin/hypershift create cluster aws "${AWS_CREATE_ARGS[@]}"
  else
    # The management cluster must trust an extra CA (for example the e2e v2
    # mirror registry CA, see hypershift-mirror-registry-ca-generate) in two
    # places:
    #   - its nodes: HostedCluster spec.additionalTrustBundle;
    #   - its image.config.openshift.io/cluster spec.additionalTrustedCA, which
    #     the HyperShift operator installed later reads at start and hands to
    #     every control plane operator. This is the documented disconnected
    #     setup, but this management cluster is itself a hosted cluster: its
    #     image.config is owned by the parent HostedCluster (an admission policy
    #     rejects direct changes), so it must be set through HostedCluster
    #     spec.configuration.image. It is set at creation because the image
    #     config, including this ConfigMap reference, is part of the NodePool
    #     configuration hash: adding the reference later would roll the nodes.
    # Both references point to the same ConfigMap. The operator reads every key
    # of the additionalTrustedCA ConfigMap, so the trust bundle key works.
    #
    # Why not just pass --additional-trust-bundle to "create cluster"? The CLI
    # always stores the bundle in a ConfigMap named "user-ca-bundle" in the
    # HostedCluster namespace (cmd/cluster/core/create.go,
    # applyTrustBundleAndImageSources), and "destroy cluster" does not delete
    # it. Here that namespace is shared by every concurrent CI job on the parent
    # cluster, so two jobs would overwrite each other's CA and the ConfigMap
    # would be left behind. The CLI has no flag to choose the name.
    #
    # So we render the manifests instead of applying them, give the ConfigMap a
    # per-job name, add the image config reference, and apply them ourselves.
    # Rendering still creates the AWS infrastructure (and "destroy cluster"
    # still removes it) and produces the same objects. What we must replicate from
    # the CLI apply step (cmd/cluster/core/create.go, func apply) is:
    #   - the label hypershift.openshift.io/auto-created-for-infra=<infra ID> on
    #     every object, set before the objects are created. "destroy cluster"
    #     deletes the CLI secrets (pull secret, SSH key, etcd encryption key) by
    #     that label, and the operator uses it to set their owner reference, so
    #     without it they would leak;
    #   - server-side apply with field manager "hypershift-cli".
    # Keep this in sync with func apply if it changes. The ConfigMap itself is
    # deleted by hypershift-destroy-nested-management-cluster.
    TRUST_BUNDLE_FILE="${SHARED_DIR}/${HYPERSHIFT_MGMT_ADDITIONAL_TRUST_BUNDLE}"
    if [[ ! -s "${TRUST_BUNDLE_FILE}" ]]; then
      echo "HYPERSHIFT_MGMT_ADDITIONAL_TRUST_BUNDLE is set but ${TRUST_BUNDLE_FILE} is missing or empty" >&2
      exit 1
    fi
    TRUST_BUNDLE_CONFIGMAP="${CLUSTER_NAME}-additional-trust-bundle"
    RENDER_DIR="$(mktemp -d)"
    # The rendered file contains secrets: keep it out of SHARED_DIR and ARTIFACT_DIR.
    trap 'rm -rf "${RENDER_DIR}"' EXIT
    RENDERED="${RENDER_DIR}/management-cluster.yaml"

    echo "Management cluster nodes will trust ${TRUST_BUNDLE_FILE} (ConfigMap ${HYPERSHIFT_NAMESPACE}/${TRUST_BUNDLE_CONFIGMAP})"
    bin/hypershift create cluster aws "${AWS_CREATE_ARGS[@]}" \
      --additional-trust-bundle="${TRUST_BUNDLE_FILE}" \
      --render-into="${RENDERED}" --render-sensitive

    # Label the objects before applying them, as the CLI does, so the secrets
    # never exist without the label that destroy relies on. "oc label --local"
    # works offline and converts the YAML into a stream of JSON objects.
    LABELED="${RENDER_DIR}/management-cluster-labeled.json"
    oc label --local -f "${RENDERED}" -o json \
      "hypershift.openshift.io/auto-created-for-infra=${CLUSTER_NAME}" > "${LABELED}"

    # Edit the objects structurally (python3 comes with the UBI base image; jq
    # does not): rename the ConfigMap and the HostedCluster reference to it, and
    # add the image config reference. Fail rather than apply a partly edited
    # set if the rendered objects are not the expected ones.
    FINAL="${RENDER_DIR}/management-cluster.json"
    python3 - "${LABELED}" "${FINAL}" "${TRUST_BUNDLE_CONFIGMAP}" <<'EOF'
import json
import sys

src, dst, name = sys.argv[1:4]
with open(src) as f:
    text = f.read()
decoder, pos, objs = json.JSONDecoder(), 0, []
while True:
    while pos < len(text) and text[pos].isspace():
        pos += 1
    if pos == len(text):
        break
    obj, pos = decoder.raw_decode(text, pos)
    objs.append(obj)

cms = [o for o in objs if o.get("kind") == "ConfigMap" and o["metadata"].get("name") == "user-ca-bundle"]
hcs = [o for o in objs if o.get("kind") == "HostedCluster"]
if len(cms) != 1 or len(hcs) != 1:
    sys.exit(f"expected 1 user-ca-bundle ConfigMap and 1 HostedCluster, found {len(cms)} and {len(hcs)}")
spec = hcs[0]["spec"]
if (spec.get("additionalTrustBundle") or {}).get("name") != "user-ca-bundle":
    sys.exit("HostedCluster spec.additionalTrustBundle does not reference user-ca-bundle")
configuration = spec.get("configuration") or {}
image = configuration.get("image") or {}
if (image.get("additionalTrustedCA") or {}).get("name"):
    sys.exit("HostedCluster spec.configuration.image.additionalTrustedCA is already set")

cms[0]["metadata"]["name"] = name
spec["additionalTrustBundle"]["name"] = name
image["additionalTrustedCA"] = {"name": name}
configuration["image"] = image
spec["configuration"] = configuration

with open(dst, "w") as f:
    json.dump({"apiVersion": "v1", "kind": "List", "items": objs}, f)
EOF
    oc apply --server-side --force-conflicts --field-manager=hypershift-cli -f "${FINAL}"
  fi
fi

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=${HYPERSHIFT_NAMESPACE} hostedcluster/${CLUSTER_NAME}
echo "Cluster became available, creating kubeconfig"

# Data for cluster bot.
# The kubeadmin-password secret is reconciled only after the kas is available so giving a few seconds to avoid racing and move forward otherwise.
sleep 15
echo "Getting ${CLUSTER_NAME}-kubeadmin-password from namespace ${HYPERSHIFT_NAMESPACE}"
until \
  oc get secret -n "${HYPERSHIFT_NAMESPACE}" "${CLUSTER_NAME}-kubeadmin-password" 2> /dev/null; do
    echo "$(date --rfc-3339=seconds) kubeadmin password not yet available"
    sleep 5
done
oc get secret -n "${HYPERSHIFT_NAMESPACE}" "${CLUSTER_NAME}-kubeadmin-password" --template='{{.data.password}}' | base64 -d > "${KUBEADMIN_PASSWORD_FILE}"

bin/hypershift create kubeconfig --namespace=${HYPERSHIFT_NAMESPACE} --name=${CLUSTER_NAME} >"${MANAGEMENT_CLUSTER_KUBECONFIG}"
bin/hypershift create kubeconfig --namespace=${HYPERSHIFT_NAMESPACE} --name=${CLUSTER_NAME} >"${KUBECONFIG_OUTPUT}"
echo "${HYPERSHIFT_NAMESPACE}" > "${MANAGEMENT_CLUSTER_NAMESPACE_FILE}"
echo "${CLUSTER_NAME}" > "${MANAGEMENT_CLUSTER_NAME_FILE}"
echo "Waiting for clusteroperators to be ready"
export KUBECONFIG="${MANAGEMENT_CLUSTER_KUBECONFIG}"
until \
  oc wait clusterversion/version --for='condition=Available=True' > /dev/null; do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    oc get clusterversion 2>/dev/null || true
    sleep 1s
done
# Data for cluster bot.
echo "https://$(oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${CONSOLE_URL_FILE}"

# The HyperShift operator reads the image.config CA only when it starts, so
# make sure the parent has propagated it before hypershift-install runs. The
# cluster version is Available at this point, so HCCO has long reconciled the
# global configuration: a short budget is enough and keeps the step within its
# timeout, which the waits above already use most of.
if [[ -n "${TRUST_BUNDLE_CONFIGMAP:-}" ]]; then
  echo "Waiting for image.config.openshift.io/cluster to trust ConfigMap openshift-config/${TRUST_BUNDLE_CONFIGMAP}"
  deadline=$((SECONDS + 300))
  until [[ "$(oc get image.config.openshift.io/cluster -o jsonpath='{.spec.additionalTrustedCA.name}' 2> /dev/null)" == "${TRUST_BUNDLE_CONFIGMAP}" ]] &&
    oc get configmap -n openshift-config "${TRUST_BUNDLE_CONFIGMAP}" > /dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "The management cluster image.config does not trust ConfigMap openshift-config/${TRUST_BUNDLE_CONFIGMAP} after 5 minutes" >&2
      oc get image.config.openshift.io/cluster -o jsonpath='{.spec.additionalTrustedCA}{"\n"}' >&2 || true
      exit 1
    fi
    echo "$(date --rfc-3339=seconds) image.config or ConfigMap openshift-config/${TRUST_BUNDLE_CONFIGMAP} not yet reconciled"
    sleep 10
  done
  echo "The management cluster image.config trusts the bundle in ${TRUST_BUNDLE_CONFIGMAP}"
fi

# Create a Premium SSD v2 storage class on Azure management clusters for etcd
if [[ "${CLOUD_PROVIDER}" == "Azure" ]]; then
  echo "Creating managed-csi-premium-v2 StorageClass on management cluster"
  oc apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi-premium-v2
provisioner: disk.csi.azure.com
parameters:
  skuName: PremiumV2_LRS
  cachingMode: None
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
fi
