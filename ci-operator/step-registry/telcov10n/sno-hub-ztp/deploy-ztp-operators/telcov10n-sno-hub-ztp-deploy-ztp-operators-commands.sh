#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function fix_uid {
  echo "************ telcov10n cluster setup via agent command ************"
  # Fix user IDs in a container
  [ -e "$HOME/fix_uid.sh" ] && "$HOME/fix_uid.sh" || echo "$HOME/fix_uid.sh was not found" >&2
}
 
function run_cmd {
  [[ "${HIGHLIGHT_MODE:='no'}" == "yes" ]] && \
    echo -e "\e[1;33mRunning: \033[1;37m${*}\e[0m" || \
    ( echo && echo -e "Running: ${*}" && echo )
  eval "$@"
}

function load_settings {
  echo "************ telcov10n Load ENV vars ************"
}

function install_dependencies {
  # install_ansible_modules_and_roles
  install_extra_tools
}

function install_ansible_modules_and_roles {
  echo "************ telcov10n install ansible modules and roles ************"
  run_cmd ansible-galaxy collection install redhatci.ocp --ignore-certs
}

function install_extra_tools {

  (
    set -x; cd "$(mktemp -d)" &&
    OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
    ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
    KREW="krew-${OS}_${ARCH}" &&
    curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
    tar zxvf "${KREW}.tar.gz" &&
    ./"${KREW}" install krew
  )

  run_cmd export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
  run_cmd oc krew install operator

}

function install_ztp_operator {

  op_name=$1 ; shift
  op_channel=$1 ; shift
  op_namespace=$1

  echo
  echo "************ telcov10n install ZTP Operator ${op_name} ************"

  run_cmd " \
    oc create ns ${op_namespace} && \
    oc operator install ${op_name} \
      --create-operator-group \
      --channel ${op_channel} \
      --namespace ${op_namespace}"
}

function install_ztp_operators {

  echo "************ telcov10n install ZTP Operators ************"

  install_ztp_operator local-storage-operator stable openshift-local-storage
  install_ztp_operator advanced-cluster-management release-2.10 open-cluster-management
  install_ztp_operator topology-aware-lifecycle-manager stable openshift-talm
  install_ztp_operator openshift-gitops-operator latest openshift-gitops-operator

  create_multiclusterhub

  run_cmd oc get operators

}

function create_multiclusterhub {

  echo "************ telcov10n Create MultiClusterHub ************"

  run_cmd oc apply -f - <<EOF
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec:
  availabilityConfig: High
  enableClusterBackup: false
  ingress: {}
  overrides:
    components:
    - enabled: true
      name: app-lifecycle
    - enabled: true
      name: cluster-lifecycle
    - enabled: true
      name: cluster-permission
    - enabled: true
      name: console
    - enabled: true
      name: grc
    - enabled: true
      name: insights
    - enabled: true
      name: multicluster-engine
    - enabled: true
      name: multicluster-observability
    - enabled: true
      name: search
    - enabled: true
      name: submariner-addon
    - enabled: true
      name: volsync
    - enabled: false
      name: cluster-backup
  separateCertificateManagement: false
EOF
}

function wait_for_the_cluster_to_stabilize {
  max_attempts=15
  attempts=0
  # Wait for 20s x 15 times = 5 min
  echo
  while [ ${attempts} -lt ${max_attempts} ] ; do
    ((attempts=$attempts+1))
    echo Waiting until cluster operators get ready... Attempt[${attempts}/${max_attempts}]
    oc get co | grep "True.*False.*False" && \
    break ; \
    sleep 20
  done

  if [ ${attempts} -eq ${max_attempts} ]; then
    echo "Cluster Operators are not ready. Check them out"
    run_cmd oc get co
    exit 1
  fi

  namespaces_to_check=(
    "openshift-gitops"
    "openshift-local-storage"
    "open-cluster-management"
    "multicluster-engine"
  )

  echo
  for ns in "${namespaces_to_check[@]}"; do
    echo "Waiting until PODs in ${ns} namespace get ready..."
    pods_list=$(oc -n ${ns} get pod -ojsonpath='{.items[*].metadata.name}')
    for pod in $( echo ${pods_list} | tr ' ' '\n' ) ; do
      run_cmd oc -n ${ns} wait --for=condition=Ready pod/${pod} --timeout=10m || \
      echo It is ok if it fails due to the timeout expired since this is just for stabilization phase...
    done
  done
}

function uninstall_ztp_operators {
  run_cmd oc operator uninstall local-storage-operator --delete-all --namespace openshift-local-storage && \
  run_cmd oc delete ns openshift-local-storage
}

function main {
  load_settings
  install_dependencies
  install_ztp_operators
  wait_for_the_cluster_to_stabilize
}

main

set -x
while sleep 10m; do
  date
  test -f ecascaz.done && exit 0
done
