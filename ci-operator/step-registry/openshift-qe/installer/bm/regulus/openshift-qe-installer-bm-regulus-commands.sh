#!/bin/bash
# Install, config and execute Regulus, the dataplane test suite.
#
# Background:
#   For BM we support multiple profiles. Currently there are 2 profiles: metal-perscale-cpt (cloud31)
#   and metal-perfscale-jetlag (cloud48). More profiles are coming. Multiple profiles ramifications are:
#       1. The current BM Prow design has cloud31 as the only cloud reachable from Prow pod.
#       2. Dictated by "1.", jetlag always runs on cloud31 bastion to instantiatep cloud31 or cloud48 cluster.
#   Notable impacts to the Regulus Step are:
#      If the profile is cloud31, we ssh from Prow to cloud31's bastion and run Regulus there, a standard case.
#      If the profile is cloud48, we have to double/nested ssh to get to cloud48's bastion. A more complicate situation.
#      For this 2-hop scenario, we refer to cloud31's bastion as "bastion" and the second hop bastion as "true" bastion.
#      On the true bastion, we do not have the private key to ssh to its nodes (ssh core@worker_ip). This key
#      is on the bastion (where jetlag ran).
#
#      In summary, for Regulus some operations are 1-hop ssh, some are 2-hop ssh, and some need jetlag build-time
#      private key that we need to set up.
#
set -o errexit
set -o nounset
set -o pipefail
set -x

REPO_NAME=${REPO_NAME:-}
BASTION="${BASTION:-}"                          # first level which always is cloud31 bastion
TRUE_BASTION_HOST="${TRUE_BASTION_HOST:-}"      # second level such as cloud48 bastion
LAB_CLOUD="${LAB_CLOUD:-}"
LAB="${LAB:-}"

# Enable debug mode with environment variable
DEBUG_MODE="${DEBUG_MODE:-false}"
debug_echo() {
    if [[ "${DEBUG_MODE}" == "true" ]]; then
        echo "DEBUG: $*"
    fi
}
# example: debug_echo "assignment: '${REG_BRANCH}'"

# 1-level ssh 
function do_ssh() {
    local user_host="$1"
    shift
    ssh ${SSH_ARGS} ${user_host} "$@"
    return $?
}

# 2-level, nested/jump ssh
# Prerequisite:  on bastion, ssh root@true_bastion must work (ssh-copy-id by admin)
function do_jssh() {
    local user_host="$1"
    shift
    # Use ProxyCommand for nested SSH to control options for both connections
    ssh ${SSH_ARGS} \
        -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p ${user_host}" \
        root@${TRUE_BASTION_HOST} "$@"
    return $?
}

# 2-level, nested scp
function do_jscp() {
    local user_host="$1"
    shift
    local src_file="$1"
    shift
    local dst_file="$1"
    local user host
    user=$(echo "$user_host" | awk -F@ '{print $1}')
    host=$(echo "$user_host" | awk -F@ '{print $2}')
    
    if [ -z "$user" ] || [ -z "$host" ]; then
        echo "Error: Invalid user/host: $user_host" >&2
        return 1
    fi
    
    # Use ProxyCommand 
    scp -q ${SSH_ARGS} \
        -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p ${user_host}" \
        "$src_file" "${user}@$TRUE_BASTION_HOST:$dst_file"
    return $?
} 

# RUNLOCAL is devel mode that invokes openshift-qe-installer-bm-regulus-commands.sh on local machine
# instead of going thru Prow/ci-tools.
if [ -z "${RUNLOCAL:-}" ]; then
  if [ -f "${CLUSTER_PROFILE_DIR}/lab_cloud" ]; then
    LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud)
    LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
    bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
    SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  else 
    echo "Error: No valid CLUSTER_PROFILE_DIR" >&2
    exit 1
  fi
else
  bastion=$BASTION
  SSH_ARGS="-i $PRIVATE_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
fi

if [ -n "$LAB" ] && [ -n "$LAB_CLOUD" ]; then
    jetlag_repo=$(do_ssh root@${bastion} "ls -dt /tmp/jetlag-$LAB-$LAB_CLOUD* 2>/dev/null | head -n1")
    if [ -z "$jetlag_repo" ]; then
      echo "Error: No jetlag repo found matching pattern: /tmp/jetlag-$LAB-$LAB_CLOUD*" >&2
      exit 1
    fi
else
    echo "Error: LAB or LAB_CLOUD variables are empty" >&2
    exit 1
fi

# Use the jetlag_repo artifact to discover the true bastion identity.
if [ -z "${TRUE_BASTION_HOST}" ] ; then
  TRUE_BASTION_HOST=$(do_ssh root@${bastion} "
    cd $jetlag_repo;
    source bootstrap.sh
    ansible -i ansible/inventory/$LAB_CLOUD.local bastion --list-hosts  2>/dev/null | tail -n +2 | sed 's/^[[:space:]]*//'; 
    deactivate
    rm -rf .ansible
  ")
fi
# Trim ansible bootstrap.sh garbage. Get the the hostname only.
TRUE_BASTION_HOST=$(echo "$TRUE_BASTION_HOST" | tail -1)

if [ -z "${bastion}" ] ||  [ -z "${TRUE_BASTION_HOST}" ] ; then
    echo "Error: Invalid bastion:$bastion TRUE_BASTION_HOST: $TRUE_BASTION_HOST" >&2
    exit 1
fi

# Bail out if Crucible does not exist on the true bastion. the bm-deploy step should have installed it.
if do_jssh root@${bastion} 'command -v crucible >/dev/null'; then
    debug_echo "crucible exists"
else
    echo "crucible not found" >&2
    exit 1
fi

# install regulus on the true bastion. 
regulus_repo="/root/REGULUS/regulus-${LAB_CLOUD}-$(date "+%Y-%m-%d-%H-%M-%S")"
install-regulus() {
  do_jssh root@${bastion} "
    export REG_PR='${REG_PR}' REPO_NAME='${REPO_NAME}' REG_BRANCH='${REG_BRANCH}'
    regulus_repo='${regulus_repo}'
    set -e
    set -o pipefail
    if [ -d \${regulus_repo} ] ; then
        rm -fr \${regulus_repo}
    fi
    dnf install -y bc
    git clone https://github.com/redhat-performance/regulus.git --depth=1 --branch=\"\${REG_BRANCH:-main}\" ${regulus_repo}
    cd \${regulus_repo}
    if [[ -n \"\${REG_PR}\" ]]; then
        git pull origin pull/\${REG_PR}/head:\${REG_PR} --rebase
        git switch \${REG_PR}
    fi
    git branch
  "
}

# Install fresh Regulus always
install-regulus 

# ─────────────────────────────────────────────────────────────────────────────
# Generate Regulus lab.config 
# ─────────────────────────────────────────────────────────────────────────────
vars=(
  KUBECONFIG
  REG_KNI_USER
  REG_OCPHOST
  REG_DP
  OCP_WORKER_0
  OCP_WORKER_1
  OCP_WORKER_2
  BM_HOSTS
  REG_SRIOV_NIC
  REG_SRIOV_MTU
  REG_SRIOV_NIC_MODEL
  REG_MACVLAN_NIC
  REG_MACVLAN_MTU
  REG_DPDK_NIC_1
  REG_DPDK_NIC_2
  REG_DPDK_NIC_MODEL
  TREX_HOSTS
  TREX_SRIOV_INTERFACE_1
  TREX_SRIOV_INTERFACE_2
  TREX_DPDK_NIC_MODEL
  REM_DPDK_CONFIG
)

if [ -e  /tmp/lab.config ]; then
    rm /tmp/lab.config
fi

cat > /tmp/lab.config <<EOF
# This file was generated by openshift-qe-installer-bm-regulus-commands.sh
# It will be sourced by other Regulus scripts to import environment values.
EOF
for v in "${vars[@]}"; do
  # "${!v}" expands the variable whose name is in $v
  if [[ "$v" == "KUBECONFIG" ]]; then
    val=$KUBECONFIG_PATH
  elif [[ "$v" == "REG_OCPHOST" ]]; then
    val=$TRUE_BASTION_HOST
  else
    val="${!v:-}"
  fi

  # Expand tilda i.e. var=~/something to /root/something. Example  KUBECONFIG_PATH=~/mno/kubeconfig
  if [[ "$val" == ~* ]]; then
    val="${val/#\~\//\/root/}"
  fi

  # Escape any embedded double-quotes
  safe_val=${val//\"/\\\"}
  printf 'export %s="%s"\n' "$v" "$safe_val" >> /tmp/lab.config
done

# ───────────────────────────────────────────────────────────────────────────
# Launch Regulus (tests are listed in regulus_repo/jobs.config)
# ───────────────────────────────────────────────────────────────────────────
run-regulus() {
  # Pass jetlag's build-time private key and Regulus lab.config the to true bastion
  do_ssh root@$bastion "scp /root/.ssh/id_rsa root@$TRUE_BASTION_HOST:/tmp/private_key"
  do_jscp "root@${bastion}" "/tmp/lab.config" "${regulus_repo}/lab.config"

  # Kick off Regulus.
  do_jssh "root@${bastion}" "
    set -e
    set -o pipefail
    cd ${regulus_repo}
    bash ./run_cpt.sh
  "
}
run-regulus

#clean up
do_ssh root@${bastion} "
    set -e
    set -o pipefail
    if [ -f '/tmp/clean-resources.sh' ]; then
        echo bash /tmp/clean-resources.sh
    fi 
"

# EOF
