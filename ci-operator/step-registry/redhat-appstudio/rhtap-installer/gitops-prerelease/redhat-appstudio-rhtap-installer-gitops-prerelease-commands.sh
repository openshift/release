#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail


export OPENSHIFT_API \
  OPENSHIFT_PASSWORD \
  QUAY_ROBOT_PASSWORD \
  BREW_USER \
  BREW_PASSWORD

OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"
QUAY_ROBOT_PASSWORD=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-robot-password)
BREW_USER=$(cat /usr/local/rhtap-ci-secrets/rhtap/brew-user)
BREW_PASSWORD=$(cat /usr/local/rhtap-ci-secrets/rhtap/brew-password)

echo "yq -i"
yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' "$KUBECONFIG"
OPENSHIFT_PASSWORD="$(cat $KUBEADMIN_PASSWORD_FILE)"

echo "while loop"
timeout --foreground 5m bash  <<- "EOF"
    while ! oc login "$OPENSHIFT_API" -u kubeadmin -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
            sleep 20
    done
EOF

if [ $? -ne 0 ]; then
  echo "Timed out waiting for login"
  exit 1
fi

setup_catalog_source(){
  echo "[INFO]Install pre-release gitops..."

  # shellcheck disable=SC1083
  oc get secret pull-secret -n openshift-config -o jsonpath={.data."\.dockerconfigjson"} | base64 -d > authfile
  # shellcheck disable=SC1083
  oc get secret pull-secret -n openshift-config -o jsonpath={.data."\.dockerconfigjson"} | base64 -d > authfile-orig
  oc get secret pull-secret -n openshift-config -o yaml > pull-secret.yaml

  sed -i '/namespace:/d' pull-secret.yaml
  sed -i '/resourceVersion:/d' pull-secret.yaml
  sed -i '/uid:/d' pull-secret.yaml
  oc apply -f pull-secret.yaml -n openshift-marketplace

  oc registry login --insecure=true --registry=quay.io --auth-basic=rhtap_qe+rhtap_qe_robot:$QUAY_ROBOT_PASSWORD --to=authfile
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=authfile
  oc set data secret/pull-secret -n openshift-marketplace --from-file=.dockerconfigjson=authfile

  # Define the ImageContentSourcePolicy YAML content
  cat <<EOF | oc apply -f -
  apiVersion: operator.openshift.io/v1alpha1
  kind: ImageContentSourcePolicy
  metadata:
    name: brew-registry
  spec:
    repositoryDigestMirrors:
    - mirrors:
      - brew.registry.redhat.io/rh-osbs/openshift-gitops-1-gitops-operator-bundle
      source: registry-proxy.engineering.redhat.com/rh-osbs/openshift-gitops-1-gitops-operator-bundle
    - mirrors:
      - brew.registry.redhat.io/openshift-gitops-1/gitops-operator-bundle
      source: registry.stage.redhat.io/openshift-gitops-1/gitops-operator-bundle
    - mirrors:
      - brew.registry.redhat.io/openshift-gitops-1/gitops-rhel8-operator
      source: registry.redhat.io/openshift-gitops-1/gitops-rhel8-operator
    - mirrors:
      - brew.registry.redhat.io/openshift-gitops-1/gitops-rhel8
      source: registry.redhat.io/openshift-gitops-1/gitops-rhel8
    - mirrors:
      - brew.registry.redhat.io/openshift-gitops-1/argocd-rhel8
      source: registry.redhat.io/openshift-gitops-1/argocd-rhel8
    - mirrors:
      - brew.registry.redhat.io/openshift-gitops-1/kam-delivery-rhel8
      source: registry.redhat.io/openshift-gitops-1/kam-delivery-rhel8
    - mirrors:
      - brew.registry.redhat.io/openshift-gitops-1/dex-rhel8
      source: registry.redhat.io/openshift-gitops-1/dex-rhel8
    - mirrors:
      - brew.registry.redhat.io/openshift-gitops-1/console-plugin-rhel8
      source: registry.redhat.io/openshift-gitops-1/console-plugin-rhel8
    - mirrors:
      - brew.registry.redhat.io/openshift-gitops-1/argo-rollouts-rhel8
      source: registry.redhat.io/openshift-gitops-1/argo-rollouts-rhel8
EOF
  
  oc patch operatorhub.config.openshift.io/cluster -p='{"spec":{"disableAllDefaultSources":true}}' --type=merge

  cat <<EOF | oc apply -f -
  apiVersion: operators.coreos.com/v1alpha1
  kind: CatalogSource
  metadata:
    name: custom-operators
    namespace: openshift-marketplace
  spec:
    sourceType: grpc
    image: $GITOPS_IIB_IMAGE
    imagePullSecrets:
      - name: pull-secret
    displayName: gitops-iib
    publisher: RHTAP-QE
EOF

  sleep 15
  echo "waiting for pods in namespace openshift-marketplace to be ready...."
  pods=$(oc -n openshift-marketplace get pods | awk '{print $1}' | grep custom-operators)
  for pod in ${pods}; do
      echo "waiting for pod $pod in openshift-marketplace to be in ready state"
      oc wait --for=condition=Ready -n openshift-marketplace pod $pod --timeout=15m
  done
}

install_prerelease_gitops(){

  oc registry login --insecure=true --registry=brew.registry.redhat.io --auth-basic="$BREW_USER":"$BREW_PASSWORD" --to=authfile-orig
  oc set data secret/pull-secret -n openshift-marketplace --from-file=.dockerconfigjson=authfile-orig
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=authfile-orig

  echo "Apply subscription"

  cat <<EOF | oc apply -f -
  apiVersion: operators.coreos.com/v1alpha1
  kind: Subscription
  metadata:
    annotations:
      helm.sh/resource-policy: keep
    name: openshift-gitops-operator
    namespace: openshift-operators
  spec:
    channel: latest
    installPlanApproval: Automatic
    name: openshift-gitops-operator
    source: custom-operators 
    sourceNamespace: openshift-marketplace
    config:
      env:
        - name: ARGOCD_CLUSTER_CONFIG_NAMESPACES
          value: openshift-gitops,rhtap
EOF

  echo "GitOps operator status check"
  # Calculate the timeout end time in seconds
  END_TIME=$((SECONDS + 900))

  set +e
  while true; do

    # Run oc wait command and capture the output
    wait_output=$(oc wait --for=condition=Ready pod -l control-plane=gitops-operator -n openshift-operators --timeout=15m 2>&1)

    # Check if oc wait command succeeded
    if [ $? -eq 0 ]; then
      echo "Pod with label control-plane=gitops-operator is now ready."
      break
    fi

    # Check if the output indicates no resources found
    if echo "$wait_output" | grep -q "no matching resources found"; then
      echo "No pods found with label control-plane=gitops-operator yet. Checking again in 10 seconds..."
    else
      echo "Error waiting for pod with label control-plane=gitops-operator:"
      echo "$wait_output"
      echo "Retrying in 10 seconds..."
    fi

    if [ $SECONDS -ge $END_TIME ]; then
      echo "Timeout reached. Pod with label control-plane=gitops-operator is not ready after 15m."
      break
    fi

    echo "Pod with label control-plane=gitops-operator is not ready yet. Checking again in 10 seconds..."
    sleep 10
  done
  set -e

  echo "patch back operatorhub"
  oc patch operatorhub.config.openshift.io/cluster -p='{"spec":{"disableAllDefaultSources":false}}' --type=merge
}

setup_catalog_source
install_prerelease_gitops
