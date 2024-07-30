#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"

# This was taken from other Hypershift jobs, this is how the hosted cluster
# is named in CI.
HASH="$(echo -n $PROW_JOB_ID|sha256sum)"
CLUSTER_NAME=${HASH:0:20}

echo "Creating the Ingress floating IP for the Hypershift Hosted Cluster"
HCP_INGRESS_FIP=$(openstack floating ip create "$OPENSTACK_EXTERNAL_NETWORK" --description "HCP Ingress FIP created by CI for hypershift/e2e cluster $CLUSTER_NAME" -f value -c floating_ip_address)
if [ -z "$HCP_INGRESS_FIP" ]; then
  echo "Failed to create the Ingress floating IP for the Hypershift Hosted Cluster"
  exit 1
fi
echo "$HCP_INGRESS_FIP" > ${SHARED_DIR}/HCP_INGRESS_FIP
echo "$HCP_INGRESS_FIP" >> ${SHARED_DIR}/DELETE_FIPS

echo "Creating the Ingress service with Octavia"
cat <<EOF | oc apply -f -
---
kind: Service
apiVersion: v1
metadata:
  name: octavia-ingress
  namespace: openshift-ingress
spec:
  loadBalancerIP: "${HCP_INGRESS_FIP}"
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
    - name: https
      protocol: TCP
      port: 443
      targetPort: 443
  selector:
    ingresscontroller.operator.openshift.io/deployment-ingresscontroller: default
  type: LoadBalancer
EOF

echo "Waiting 5 minutes for the Ingress service to be ready"
for _ in {1..30}; do
  EXTERNAL_IP=$(oc get svc octavia-ingress -n openshift-ingress --no-headers  | awk '{print $4}')
  if [ -n "$EXTERNAL_IP" ]; then
    echo "Ingress service is ready with external IP: $EXTERNAL_IP"
    break
  fi
  sleep 10
done
if [ -n "$EXTERNAL_IP" ]; then
  echo "Ingress service was not ready after 5 minutes"
  exit 1
fi

if [ "$EXTERNAL_IP" != "$HCP_INGRESS_FIP" ]; then
  echo "Ingress service external IP $EXTERNAL_IP does not match the expected IP $HCP_INGRESS_FIP"
  exit 1
fi

echo "Wait HostedCluster ready..."
if ! oc wait --timeout=5m clusterversion/version --for='condition=Available=True'; then
  echo "HostedCluster is not ready after 5 minutes"
  exit 1
fi

CANARY_HOST=$(oc get route canary -n openshift-ingress-canary -o jsonpath='{.status.ingress[0].host}')
echo "Check the route reachability via the custom ingresscontroller LB"
curl -kI --resolve "${CANARY_HOST}:443:${HCP_INGRESS_FIP}" "https://${CANARY_HOST}"

echo "Done"