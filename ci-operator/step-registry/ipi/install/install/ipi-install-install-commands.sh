#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function set-cluster-version-spec-update-service() {
    local payload_version
    local jsonpath_flag

    if oc adm release info --help | grep "\-\-output=" -A 1 | grep -q jsonpath; then
        jsonpath_flag=true
    else
        echo "this oc does not support jsonpath output"
        oc adm release info --help | grep "\-o, \-\-output=" -A 1
        jsonpath_flag=false
    fi

    if [[ "${jsonpath_flag}" == "true" ]]; then
        payload_version="$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o "jsonpath={.metadata.version}")"
    else
        payload_version="$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" | grep -oP '(?<=^  Version:  ).*$')"
    fi
    echo "Release payload version: ${payload_version}"

    if [[ ! -f ${dir}/manifests/cvo-overrides.yaml ]]; then
        echo "No CVO overrides file found, will not configure OpenShift Update Service"
        return
    fi

    # Using OSUS in upgrade jobs would be tricky (we would need to know the channel with both versions)
    # and the use case has little benefits (not many jobs that update between two released versions)
    # so we do not need to support it. We still need to channel clear to avoid tripping the
    # CannotRetrieveUpdates alert on one of the versions.
    # Not all steps that use this script expose OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE so we need to default it
    # If we are in a step that exposes it and it differs from OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE, we are likely
    # running an upgrade job.
    if [[ -n "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}" ]] &&
       [[ "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" != "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
        echo "This is likely an upgrade job (OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE differs from nonempty OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE)"
        echo "Cluster cannot query OpenShift Update Service (OSUS/Cincinnati), cleaning the channel"
        sed -i '/^  channel:/d' "${dir}/manifests/cvo-overrides.yaml"
        return
    fi

    # Determine architecture that Cincinnati would use: check metadata for release.openshift.io/architecture key
    # and fall back to manifest-declared architecture
    local payload_arch
    if [[ "${jsonpath_flag}" == "true" ]]; then
        payload_arch="$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o "jsonpath={.metadata.metadata.release\.openshift\.io/architecture}")"
        if [[ -z "${payload_arch}" ]]; then
            echo 'Payload architecture not found in .metadata.metadata["release.openshift.io/architecture"], using .config.architecture'
            payload_arch="$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o "jsonpath={.config.architecture}")"
        fi
    else
        payload_arch="$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" | grep "^OS/Arch: " | cut -d/ -f3)"
    fi
    local payload_arch_param
    if [[ -n "${payload_arch}" ]]; then
        echo "Release payload architecture: ${payload_arch}"
        payload_arch_param="&arch=${payload_arch}"
    else
        echo "Unable to determine payload architecture"
        payload_arch_param=""
    fi


    local channel
    if ! channel="$(grep -E --only-matching '(stable|eus|fast|candidate)-4.[0-9]+' "${dir}/manifests/cvo-overrides.yaml")"; then
        echo "No known OCP channel found in CVO manifest, clearing the channel"
        sed -i '/^  channel:/d' "${dir}/manifests/cvo-overrides.yaml"
        return
    fi

    # The candidate channel is most likely to contain the versions we are interested in, so transfer the current channel
    # into a candidate one.
    echo "Original channel from CVO manifest: ${channel}"
    local candidate_channel
    candidate_channel="$(echo "${channel}" | sed -E 's/(stable|eus|fast)/candidate/')"
    echo "Matching candidate channel: ${candidate_channel}"

    # If the version is known to OSUS, it is safe for the CI cluster to query it, so we will query the integration OSUS
    # instance maintained by OTA team. Otherwise, the cluster would trip the CannotRetrieveUpdates alert, so we need
    # to clear the channel to make the cluster *not* query any OSUS instance.
    local query
    query="https://api.integration.openshift.com/api/upgrades_info/graph?channel=${candidate_channel}${payload_arch_param}"
    echo "Querying $query for version ${payload_version}"
    if curl --silent "$query" | grep --quiet '"version":"'"$payload_version"'"'; then
        echo "Version ${payload_version} is available in ${candidate_channel}, cluster can query OpenShift Update Service (OSUS/Cincinnati)"
        echo "Setting channel to $candidate_channel and upstream to https://api.integration.openshift.com/api/upgrades_info/graph "
        sed -i "s|^  channel: .*|  channel: $candidate_channel|" "${dir}/manifests/cvo-overrides.yaml"
        echo '  upstream: https://api.integration.openshift.com/api/upgrades_info/graph' >> "${dir}/manifests/cvo-overrides.yaml"
    else
        echo "Version ${payload_version} is not available in ${candidate_channel}"
        echo "Cluster cannot query OpenShift Update Service (OSUS/Cincinnati)"
        echo "Clearing the channel"
        sed -i '/^  channel:/d' "${dir}/manifests/cvo-overrides.yaml"
    fi
}

function populate_artifact_dir() {
  set +e
  echo "Copying log bundle..."

  current_time=$(date +%s)
  cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${dir}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install-${current_time}.log"

  # terraform may not exist now
  if [ -f "${dir}/terraform.txt" ]; then
    sed -i '
      s/password: .*/password: REDACTED/;
      s/X-Auth-Token.*/X-Auth-Token REDACTED/;
      s/UserData:.*,/UserData: REDACTED,/;
      ' "${dir}/terraform.txt"
    tar -czvf "${ARTIFACT_DIR}/terraform-${current_time}.tar.gz" --remove-files "${dir}/terraform.txt"
  fi
  case "${CLUSTER_TYPE}" in
    alibabacloud)
      awk -F'id=' '/alicloud_instance.*Creation complete/ && /master/{ print $2 }' "${dir}/.openshift_install.log" | tr -d ']"' > "${SHARED_DIR}/alibaba-instance-ids.txt";;
  *) >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}' to collect machine IDs"
  esac

  # Copy CAPI-generated artifacts if they exist
  if [ -d "${dir}/.clusterapi_output" ]; then
    echo "Copying Cluster API generated manifests..."
    mkdir -p "${ARTIFACT_DIR}/clusterapi_output-${current_time}"
    cp -rpv "${dir}/.clusterapi_output/"{,**/}*.{log,yaml} "${ARTIFACT_DIR}/clusterapi_output-${current_time}" 2>/dev/null
  fi

  # Capture infrastructure issue log to help gather the datailed failure message in junit files
  if [[ "$ret" == "4" ]] || [[ "$ret" == "5" ]]; then
    grep -Er "Throttling: Rate exceeded|\
rateLimitExceeded|\
The maximum number of [A-Za-z ]* has been reached|\
The number of .* is larger than the maximum allowed size|\
Quota .* exceeded|\
Cannot create more than .* for this subscription|\
The request is being throttled as the limit has been reached|\
SkuNotAvailable|\
Exceeded limit .* for zone|\
Operation could not be completed as it results in exceeding approved .* quota|\
A quota has been reached for project|\
LimitExceeded.*exceed quota" ${ARTIFACT_DIR} > "${SHARED_DIR}/install_infrastructure_failure.log" || true
  fi
}


function capi_envtest_monitor() {
  set +e
  local dir=${1}
  echo "waiting for ${dir}/auth/envtest.kubeconfig to exist"
  while [ ! -s  "${dir}/auth/envtest.kubeconfig" ]
  do
    if [ -f "${dir}/terraform.txt" ]; then
      echo "installation is terraform-based not capi, exit capi envtest monitor"
      return 0
    fi
    sleep 5
  done
  echo 'envtest kubeconfig received!'

  echo 'waiting for envtest api to be available'
  until env KUBECONFIG="${dir}/auth/envtest.kubeconfig" oc get --raw / >/dev/null 2>&1; do
    sleep 5
  done
  echo 'envtest api available'

  mkdir -p "${ARTIFACT_DIR}/envtest"

  while true
  do
    apiresources=$(KUBECONFIG="${dir}/auth/envtest.kubeconfig" oc api-resources --verbs=list -o name | grep -v 'secrets\|customresourcedefinitions')

    for api in ${apiresources}; do
      filename=$(echo "$api" | awk -F. '{print $1}')
      KUBECONFIG="${dir}/auth/envtest.kubeconfig" oc get "${api}" -A -o yaml > "${ARTIFACT_DIR}/envtest/${filename}.yaml"
    done

    sleep 60

    # Is the envtest api still avaible?
    KUBECONFIG="${dir}/auth/envtest.kubeconfig" oc get --raw / >/dev/null 2>&1
    ret=$?
    if [ $ret -ne 0 ]; then
      break
    fi
  done
  set -e
}

# copy_kubeconfig_minimal runs in the background to monitor kubeconfig file
# As soon as kubeconfig file is available, it copes it to shared dir as kubeconfig-minimal
# Installer might still amend the file. But this is a minimally working kubeconfig and is
# useful for components like observers. In the end, the complete kubeconfig will be copies
# as before.
function copy_kubeconfig_minimal() {
  local dir=${1} temp_dir
  echo "waiting for ${dir}/auth/kubeconfig to exist"
  while [ ! -s  "${dir}/auth/kubeconfig" ]
  do
    sleep 5
  done
  echo 'kubeconfig received!'

  echo 'waiting for api to be available'
  until env KUBECONFIG="${dir}/auth/kubeconfig" oc get --raw / >/dev/null 2>&1; do
    sleep 5
  done
  echo 'api available'

  echo 'waiting for bootstrap to complete'
  # create a temporary install working dir to avoid installer log combination
  temp_dir=$(mktemp -d)
  cp -rf "${dir}"/* "${temp_dir}/"
  ${INSTALLER_BINARY} --dir="${temp_dir}" wait-for bootstrap-complete &
  wait "$!"
  ret=$?
  if [ $ret -eq 0 ]; then
    echo "Copying kubeconfig to shared dir as kubeconfig-minimal"
    cp "${dir}/auth/kubeconfig" "${SHARED_DIR}/kubeconfig-minimal"
  fi
}

function write_install_status() {
  #Save exit code for must-gather to generate junit
  echo "$ret" >> "${SHARED_DIR}/install-status.txt"
}

function prepare_next_steps() {
  write_install_status
  set +e
  echo "Tear down the backgroup process of copying kube config"
  if [[ -v copy_kubeconfig_pid ]]; then
    if ps -p $copy_kubeconfig_pid &> /dev/null; then
        echo "Kill the backgroup process - $copy_kubeconfig_pid"
        kill $copy_kubeconfig_pid
    else
        echo "The process - $copy_kubeconfig_pid is not existing any more"
    fi
  fi

  echo "Setup phase finished, prepare env for next steps"
  populate_artifact_dir

  echo "Copying required artifacts to shared dir"
  #Copy the auth artifacts to shared dir for the next steps
  cp \
      -t "${SHARED_DIR}" \
      "${dir}/auth/kubeconfig" \
      "${dir}/auth/kubeadmin-password" \
      "${dir}/metadata.json"
  if [[ "${CLUSTER_TYPE}" == "vsphere" ]] && [[ -f ${SHARED_DIR}/template.yaml.patch ]]; then
      grep -A 10 'Creating infrastructure resources...' "${dir}/.openshift_install.log" > "${SHARED_DIR}/.openshift_install.log"
  fi
  if [[ "${CLUSTER_TYPE}" == "nutanix" ]] && [[ -f ${SHARED_DIR}/install-config-patch-preloadedOSImageName.yaml ]]; then
      grep -A 10 'Creating infrastructure resources...' "${dir}/.openshift_install.log" > "${SHARED_DIR}/nutanix-preload-image-openshift_install.log"
  fi
  # capture install duration for post e2e-analysis
  awk '/Time elapsed per stage:/,/Time elapsed:/' "${dir}/.openshift_install.log" > "${SHARED_DIR}/install-duration.log"

  # For private cluster, the bootstrap address is private, installer cann't gather log-bundle directly even if proxy is set
  # the workaround is gather log-bundle from bastion host
  # copying install folder to bastion host for gathering logs
  publish=$(grep "publish:" ${SHARED_DIR}/install-config.yaml | awk '{print $2}')
  if [[ "${publish}" == "Internal" ]] && [[ ! $(grep "Bootstrap status: complete" "${dir}/.openshift_install.log") ]]; then
    echo "Copying install dir to bastion host."
    echo > "${SHARED_DIR}/REQUIRE_INSTALL_DIR_TO_BASTION"
    if [[ -s "${SHARED_DIR}/bastion_ssh_user" ]] && [[ -s "${SHARED_DIR}/bastion_public_address" ]]; then
      bastion_ssh_user=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")
      bastion_public_address=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
      if [[ -n "${bastion_ssh_user}" ]] && [[ -n "${bastion_public_address}" ]]; then

        # Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
        # to be able to SSH.
        if ! whoami &> /dev/null; then
          if [[ -w /etc/passwd ]]; then
            echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
          else
            echo "/etc/passwd is not writeable, and user matching this uid is not found."
            exit 1
          fi
        fi

        # this required rsync daemon is running on ${bastion_public_address} and /tmp dir is configured
        cmd="rsync -rtv ${dir}/ ${bastion_public_address}::tmp/installer/"
        echo "Running Command: ${cmd}"
        eval "${cmd}"
        echo > "${SHARED_DIR}/COPIED_INSTALL_DIR_TO_BASTION"
      else
        echo "ERROR: Can not get bastion user/host, skip to copy install dir."
      fi
    else
      echo "ERROR: File bastion_ssh_user or bastion_public_address is empty or not exist, skip to copy install dir."
    fi
  fi

  # TODO: remove once BZ#1926093 is done and backported
  if [[ "${CLUSTER_TYPE}" == "ovirt" ]]; then
    cp -t "${SHARED_DIR}" "${dir}"/terraform.*
  fi
}

function inject_promtail_service() {
  export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME}/${BUILD_ID}"
  export PROMTAIL_IMAGE="quay.io/openshift-logging/promtail"
  export PROMTAIL_VERSION="v3.4.3"
  export LOKI_ENDPOINT=https://logging-loki-openshift-operators-redhat.apps.cr.j7t7.p1.openshiftapps.com/api/logs/v1/openshift-trt/loki/api/v1

  config_dir=/tmp/promtail
  mkdir "${config_dir}"
  cat >> "${config_dir}/promtail-prod-creds" << EOF
AUDIENCE=$(cat /var/run/loki-secret/audience)
CLIENT_ID=$(cat /var/run/loki-secret/client-id)
CLIENT_SECRET=$(cat /var/run/loki-secret/client-secret)
EOF
  cat >> "${config_dir}/promtail_config.yml" << EOF
clients:
  - backoff_config:
      max_period: 5m
      max_retries: 20
      min_period: 1s
    batchsize: 102400
    batchwait: 10s
    bearer_token_file: /tmp/shared/prod_bearer_token
    timeout: 10s
    url: ${LOKI_ENDPOINT}/push
positions:
  filename: "/run/promtail/positions.yaml"
scrape_configs:
- job_name: kubernetes-pods-static
  pipeline_stages:
  - cri: {}
  - static_labels:
      type: static-pod
  - match:
      selector: '{type="static-pod"}'
      stages:
      - regex:
          source: filename
          expression: "/var/log/pods/(?P<namespace>\\\S+?)_(?P<pod>\\\S+)_(?P<uid>\\\S+)/(?P<container>\\\S+)/.*"
  - labels:
      namespace:
      pod:
      container:
  - labeldrop:
    - filename
  - pack:
      labels:
      - namespace
      - pod
      - host
  - labelallow:
      - invoker
      - type
  static_configs:
  - labels:
      type: static-pod
      __path__: /var/log/pods/**/*.log
- job_name: journal
  journal:
    path: /var/log/journal
    labels:
      job: systemd-journal
  pipeline_stages:
  - labeldrop:
    - filename
    - stream
  - pack:
      labels:
      - boot_id
      - systemd_unit
      - host
  - labelallow:
      - invoker
      - systemd_unit
  - static_labels:
      type: systemd-journal
  relabel_configs:
  - action: labelmap
    regex: __journal__(.+)
server:
  http_listen_port: 3101
target_config:
  sync_period: 10s
EOF

  cat >> "${config_dir}/fcct.yml" << EOF
variant: fcos
version: 1.1.0
ignition:
  config:
    merge:
      - local: bootstrap_initial.ign
storage:
  files:
    - path: /etc/promtail/promtail-prod-creds
      contents:
        local: promtail-prod-creds
      mode: 0644
    - path: /etc/promtail/config.yaml
      contents:
        local: promtail_config.yml
      mode: 0644
systemd:
  units:
    - name: promtail.service
      enabled: true
      contents: |
        [Unit]
        Description=promtail
        Wants=network-online.target prod-bearer-token.service
        After=network-online.target prod-bearer-token.service

        [Service]
        ExecStartPre=/bin/mkdir -p /run/promtail /var/log/pods
        ExecStartPre=/usr/bin/podman create --rm --name=promtail -v /var/log/journal/:/var/log/journal/:z -v /var/log/pods/:/var/log/pods/:z -v /etc/machine-id:/etc/machine-id -v /run/promtail:/run/promtail:z -v /etc/promtail:/etc/promtail:z -v /tmp/shared:/tmp/shared:z ${PROMTAIL_IMAGE}:${PROMTAIL_VERSION} -config.file=/etc/promtail/config.yaml -client.external-labels=invoker='${OPENSHIFT_INSTALL_INVOKER},host=%H'
        ExecStart=/usr/bin/podman start -a promtail
        ExecStop=-/usr/bin/podman stop -t 10 promtail
        Restart=always
        RestartSec=60

        [Install]
        WantedBy=multi-user.target
    - name: prod-bearer-token.service
      enabled: true
      contents: |
        [Unit]
        Description=prod-bearer-token
        Wants=network-online.target
        After=network-online.target

        [Service]
        EnvironmentFile=/etc/promtail/promtail-prod-creds
        ExecStartPre=/bin/mkdir /tmp/shared
        ExecStartPre=/bin/chmod 777 /tmp/shared
        ExecStartPre=/usr/bin/podman create --rm --name=prod-bearer-token -v /tmp/shared:/tmp/shared:z quay.io/observatorium/token-refresher --oidc.audience=\${AUDIENCE} --oidc.client-id=\${CLIENT_ID} --oidc.client-secret=\${CLIENT_SECRET} --oidc.issuer-url=https://sso.redhat.com/auth/realms/redhat-external --margin=10m --file=/tmp/shared/prod_bearer_token
        ExecStart=/usr/bin/podman start -a prod-bearer-token
        ExecStop=-/usr/bin/podman stop -t 10 prod-bearer-token
        Restart=always
        RestartSec=60

        [Install]
        WantedBy=multi-user.target
EOF

  cp "${dir}/bootstrap.ign" "${config_dir}/bootstrap_initial.ign"
  # We're using ancient fcct as glibc in installer container is 1.28
  curl -sL https://github.com/coreos/butane/releases/download/v0.7.0/fcct-"$(uname -m)"-unknown-linux-gnu >/tmp/fcct && chmod ug+x /tmp/fcct
  /tmp/fcct --pretty --strict -d "${config_dir}" "${config_dir}/fcct.yml" > "${dir}/bootstrap.ign"
}

function get_yq() {
  if [ ! -f /tmp/yq ]; then
    curl -L "https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_$( get_arch )" \
    -o /tmp/yq && chmod +x /tmp/yq || exit 1
  fi
}

# inject_boot_diagnostics is an azure specific function for enabling boot diagnostics on Azure workers.
function inject_boot_diagnostics() {
  local dir=${1}

  get_yq

  PATCH="${SHARED_DIR}/machinesets-boot-diagnostics.yaml.patch"
  cat > "${PATCH}" << EOF
spec:
  template:
    spec:
      providerSpec:
        value:
          diagnostics:
            boot:
              storageAccountType: AzureManaged
EOF

  for MACHINESET in $dir/openshift/99_openshift-cluster-api_worker-machineset-*.yaml; do
    /tmp/yq m -x -i "${MACHINESET}" "${PATCH}"
  done
}

# inject_spot_instance_config is an AWS specific option that enables the
# use of AWS spot instances.
# PARAMS:
# $1: Path to base output directory of `openshift-install create manifests`
# $2: Either "workers" or "masters" to enable spot instances on the
#     compute or control machines, respectively.
function inject_spot_instance_config() {
  local dir=${1}
  local mtype=${2}

  get_yq

  # Find manifest files
  local manifests=
  case "${mtype}" in
    masters)
      manifests="${dir}/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml \
        ${dir}/openshift/99_openshift-cluster-api_*-machines-*.yaml"
      # Spot masters works for
      # - CAPA, always -- discover by existence of the cluster-api directory
      # - Terraform, only for newer installer binaries containing https://github.com/openshift/installer/pull/8349
      if [[ -d ${dir}/cluster-api/machines ]]; then
        echo "Spot masters supported via CAPA"
        manifests="${dir}/cluster-api/machines/10_inframachine_*.yaml $manifests"
      elif ${INSTALLER_BINARY} list-hidden-features 2>/dev/null | grep -q terraform-spot-masters; then
        echo "Spot masters supported via terraform"
      else
        echo "Spot masters are not supported in this configuration!"
        exit 1
      fi
      ;;
    workers)
      manifests="${dir}/openshift/99_openshift-cluster-api_*-machineset-*.yaml"
      ;;
    *)
      echo "ERROR: Invalid machine type '$mtype' passed to inject_spot_instance_config; expected 'masters' or 'workers'"
      exit 1
      ;;
  esac

  # Inject spotMarketOptions into the appropriate manifests
  local prefix=
  local found=false
  # Don't rely on file names; iterate through all the manifests and match
  # by kind.
  for manifest in $manifests; do
    # E.g, CPMS is not present for single node clusters
    if [[ ! -f ${manifest} ]]; then
      continue
    fi
    kind=$(/tmp/yq r "${manifest}" kind)
    case "${kind}" in
      MachineSet)  # Workers, both tf and CAPA, run through MachineSet today.
          [[ "${mtype}" == "workers" ]] || continue
          prefix='spec.template.spec.providerSpec.value'
          ;;
      AWSMachine)  # CAPA masters
          [[ "${mtype}" == "masters" ]] || continue
          prefix='spec'
          ;;
      Machine)  # tf masters during install
          [[ "${mtype}" == "masters" ]] || continue
          prefix='spec.providerSpec.value'
          ;;
      ControlPlaneMachineSet)  # masters reconciled after install
          [[ "${mtype}" == "masters" ]] || continue
          prefix='spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value'
          ;;
      *)
          continue
          ;;
    esac
    found=true
    echo "Using spot instances for ${kind} in ${manifest}"
    /tmp/yq w -i --tag '!!str' "${manifest}" "${prefix}.spotMarketOptions.maxPrice" ''
  done

  if $found; then
    echo "Enabled AWS Spot instances for ${mtype}"
  else
    echo "ERROR: Spot instances were requested for ${mtype}, but no such manifests were found!"
    exit 1
  fi
}

function get_arch() {
  ARCH=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/')
  echo "${ARCH}"
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'prepare_next_steps' EXIT TERM INT

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  CUSTOM_PAYLOAD_DIGEST=$(oc adm release info "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -a "${CLUSTER_PROFILE_DIR}/pull-secret" --output=jsonpath="{.digest}")
  CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE%:*}"@"$CUSTOM_PAYLOAD_DIGEST"
  echo "Overwrite OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} for cluster installation"
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
  echo "Extracting installer from ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
  --command=openshift-install --to="/tmp" || exit 1
  export INSTALLER_BINARY="/tmp/openshift-install"
else
  export INSTALLER_BINARY="openshift-install"
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp

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

case "${CLUSTER_TYPE}" in
aws|aws-arm64|aws-usgov)
    if [[ -f "${SHARED_DIR}/aws_minimal_permission" ]]; then
        echo "Setting AWS credential with minimal permision for installer"
        export AWS_SHARED_CREDENTIALS_FILE=${SHARED_DIR}/aws_minimal_permission
    else
        export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
    fi
    ;;
azure4|azuremag|azure-arm64)
    if [[ -f "${SHARED_DIR}/azure_minimal_permission" ]]; then
        echo "Setting AZURE credential with minimal permissions for installer"
        export AZURE_AUTH_LOCATION=${SHARED_DIR}/azure_minimal_permission
    elif [[ -f "${SHARED_DIR}/azure-sp-contributor.json" ]]; then
        echo "Setting AZURE credential with Contributor role only for installer"
        export AZURE_AUTH_LOCATION=${SHARED_DIR}/azure-sp-contributor.json
    else
        export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
    fi
    ;;
azurestack)
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/osServicePrincipal.json
    if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
        export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/ca.pem"
    fi
    ;;
gcp)
    export GOOGLE_CLOUD_KEYFILE_JSON=${CLUSTER_PROFILE_DIR}/gce.json
    if [ -f "${SHARED_DIR}/gcp_min_permissions.json" ]; then
      echo "$(date -u --rfc-3339=seconds) - Using the IAM service account for the minimum permissions testing on GCP..."
      export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/gcp_min_permissions.json"
    elif [ -f "${SHARED_DIR}/user_tags_sa.json" ]; then
      echo "$(date -u --rfc-3339=seconds) - Using the IAM service account for the userTags testing on GCP..."
      export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/user_tags_sa.json"
    elif [ -f "${SHARED_DIR}/xpn_min_perm_passthrough.json" ]; then
      echo "$(date -u --rfc-3339=seconds) - Using the IAM service account of minimal permissions for deploying OCP cluster into GCP shared VPC..."
      export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/xpn_min_perm_passthrough.json"
    elif [ -f "${SHARED_DIR}/xpn_min_perm_cco_manual.json" ]; then
      echo "$(date -u --rfc-3339=seconds) - Using the IAM service account of minimal permissions for deploying OCP cluster into GCP shared VPC with CCO in Manual mode..."
      export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/xpn_min_perm_cco_manual.json"
    elif [ -f "${SHARED_DIR}/xpn_byo-hosted-zone_min_perm_passthrough.json" ]; then
      echo "$(date -u --rfc-3339=seconds) - Using the IAM service account of minimal permissions for deploying OCP cluster into GCP shared VPC using BYO hosted zone..."
      export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/xpn_byo-hosted-zone_min_perm_passthrough.json"
    fi
    ;;
ibmcloud*)
    if [ -f "${SHARED_DIR}/ibmcloud-min-permission-api-key" ]; then
      IC_API_KEY="$(< "${SHARED_DIR}/ibmcloud-min-permission-api-key")"
      echo "using the specified key for minimal permission!!"
    else
      IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
    fi
    export IC_API_KEY
    ;;
alibabacloud) export ALIBABA_CLOUD_CREDENTIALS_FILE=${SHARED_DIR}/alibabacreds.ini;;
kubevirt) export KUBEVIRT_KUBECONFIG=${HOME}/.kube/config;;
vsphere*)
    export VSPHERE_PERSIST_SESSION=true
    cp /var/run/vsphere-ibmcloud-ci/vcenter-certificate /tmp/ca-bundle.pem
    if [ -f "${SHARED_DIR}/additional_ca_cert.pem" ]; then
      echo "additional CA bundle found, appending it to the bundle from vault"
      echo -n $'\n' >> /tmp/ca-bundle.pem
      cat "${SHARED_DIR}/additional_ca_cert.pem" >> /tmp/ca-bundle.pem
    fi
    export SSL_CERT_FILE=/tmp/ca-bundle.pem
    ;;
openstack-osuosl) ;;
openstack-ppc64le) ;;
openstack*) export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml ;;
ovirt) export OVIRT_CONFIG="${SHARED_DIR}/ovirt-config.yaml" ;;
nutanix)
    if [[ -f "${CLUSTER_PROFILE_DIR}/prismcentral.pem" ]]; then
      export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/prismcentral.pem"
    fi
    ;;
*) >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}'"
esac

dir=/tmp/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/install-config.yaml

# Don't require the installer to run in a FIPS-enabled environment
if [ "${FIPS_ENABLED:-false}" = "true" ]; then
    export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

set +o errexit
echo "=============== openshift-install version =============="
${INSTALLER_BINARY} version
${INSTALLER_BINARY} --dir="${dir}" create manifests &
wait "$!"
ret="$?"
if test "${ret}" -ne 0 ; then
	echo "Create manifests exit code: $ret"
	exit "${ret}"
fi
set -o errexit

# Platform specific manifests adjustments
case "${CLUSTER_TYPE}" in
azure4|azure-arm64)
    if [[ "${BOOT_DIAGNOSTICS:-}" == "true" ]]; then
      inject_boot_diagnostics ${dir}
    fi
    ;;
aws|aws-arm64|aws-usgov)
    if [[ "${SPOT_INSTANCES:-}"  == 'true' ]]; then
      inject_spot_instance_config "${dir}" "workers"
    fi
    if [[ "${SPOT_MASTERS:-}" == 'true' ]]; then
      inject_spot_instance_config "${dir}" "masters"
    fi
    ;;
vsphere*)

    if [[ $JOB_NAME =~ .*okd-scos.* ]]; then
    cat >> "${dir}/openshift/99_openshift-samples-operator-config.yaml" << EOF
apiVersion: samples.operator.openshift.io/v1
kind: Config
metadata:
  name: cluster
spec:
  architectures:
  - x86_64
  skippedImagestreams:
  - openliberty
EOF
    fi
    ;;
esac

set-cluster-version-spec-update-service

echo "Will include manifests:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)

find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \)

mkdir -p "${dir}/tls"
while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/tls/${manifest##tls_}"
done <   <( find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \) -print0)

echo "Will include following openshift config files:"
find "${SHARED_DIR}" \( -name "openshift_manifests_[0-9]*.yml" -o -name "openshift_manifests_[0-9]*.yaml" \)

while IFS= read -r -d '' item
do
  ocp_config_file="$( basename "${item}" )"
  cp "${item}" "${dir}/openshift/${ocp_config_file##openshift_manifests_}"
done <   <( find "${SHARED_DIR}" \( -name "openshift_manifests_[0-9]*.yml" -o -name "openshift_manifests_[0-9]*.yaml" \) -print0)

# Collect bootstrap logs for all azure clusters
case "${CLUSTER_TYPE}" in
azure4|azure-arm64) OPENSHIFT_INSTALL_PROMTAIL_ON_BOOTSTRAP=${OPENSHIFT_INSTALL_PROMTAIL_ON_BOOTSTRAP:-true} ;;
esac
if [ "${OPENSHIFT_INSTALL_PROMTAIL_ON_BOOTSTRAP:-}" == "true" ]; then
  set +o errexit
  # Inject promtail in bootstrap.ign
  ${INSTALLER_BINARY} --dir="${dir}" create ignition-configs &
  wait "$!"
  ret="$?"
  if test "${ret}" -ne 0 ; then
	  echo "Create ignition-configs exit code: $ret"
	  exit "${ret}"
  fi
  set -o errexit
  inject_promtail_service
fi

if [ "${OPENSHIFT_INSTALL_AWS_PUBLIC_ONLY:-}" == "true" ]; then
	echo "Cluster will be created with public subnets only"
fi

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
export TF_LOG_PATH="${dir}/terraform.txt"

# Cloud infrastructure problems are common, instead of failing and
# forcing a retest of the entire job, try the installation again if
# the installer exits with 4, indicating an infra problem.
case $CLUSTER_TYPE in
  *)
  # Installs are stable enough to not benefit from retries; and not all platforms support retries.
  # If a platform could benefit from retries (e.g. flaking due to resource contention), add a case for the platform above.
    max=1
    ;;
esac
ret=4
tries=1
set +o errexit
backup=/tmp/install-orig
cp -rfpv "$dir" "$backup"
while [ $ret -eq 4 ] && [ $tries -le $max ]
do
  echo "Install attempt $tries of $max"
  if [ $tries -gt 1 ]; then
    write_install_status
    populate_artifact_dir
    ${INSTALLER_BINARY} --dir="${dir}" destroy cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
    wait "$!"
    ret="$?"
    if test "${ret}" -ne 0 ; then
      echo "Failed to destroy cluster, aborting retries."
      ret=4
      break
    fi
    if [[ -v copy_kubeconfig_pid ]]; then
      kill $copy_kubeconfig_pid
    fi

    rm -rf "$dir"
    cp -rfpv "$backup" "$dir"
  else
    date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
  fi

  copy_kubeconfig_minimal "${dir}" &
  copy_kubeconfig_pid=$!
  ${INSTALLER_BINARY} --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
  wait "$!"
  ret="$?"
  echo "Installer exit with code $ret"

  tries=$((tries+1))
done
set -o errexit

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

if test "${ret}" -eq 0 ; then
  touch  "${SHARED_DIR}/success"
  # Save console URL in `console.url` file so that ci-chat-bot could report success
  echo "https://$(env KUBECONFIG=${dir}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
fi

exit "$ret"
