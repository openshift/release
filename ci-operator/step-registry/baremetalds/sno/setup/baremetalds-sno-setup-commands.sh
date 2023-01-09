#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds single-node setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "Creating Ansible inventory file"
cat > "${SHARED_DIR}/inventory" <<-EOF

[all]
${IP} ansible_user=root ansible_ssh_user=root ansible_ssh_private_key_file=${CLUSTER_PROFILE_DIR}/packet-ssh-key ansible_ssh_common_args="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"

EOF

# Copy assisted-test-infra source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/sno.tar.gz"

# Prepare configuration and run
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:pull-secret"

# Additional mechanism to inject sno additional variables directly
# from a multistage step configuration.
# Backward compatible with the previous approach based on creating the
# sno-additional-config file from a multistage step command
if [[ -n "${SNO_CONFIG:-}" ]]; then
  readarray -t config <<< "${SNO_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      echo "export ${var}" >> "${SHARED_DIR}/sno-additional-config"
    fi
  done
fi

if [[ -e "${SHARED_DIR}/sno-additional-config" ]]
then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/sno-additional-config" "root@${IP}:sno-additional-config"
fi

# Copy additional manifests
ssh "${SSHOPTS[@]}" "root@${IP}" "rm -rf /root/sno-additional-manifests && mkdir /root/sno-additional-manifests"
while IFS= read -r -d '' item
do
  echo "Copying ${item}"
  scp "${SSHOPTS[@]}" "${item}" "root@${IP}:sno-additional-manifests/"
done < <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)
echo -e "\nThe following manifests will be included at installation time:"
ssh "${SSHOPTS[@]}" "root@${IP}" "find /root/sno-additional-manifests -name manifest_*.yml -o -name manifest_*.yaml"

if [ ! -z "${OPENSHIFT_INSTALL_PROMTAIL_ON_BOOTSTRAP:-}" ]; then
  GRAFANACLOUND_USERNAME=$(cat /var/run/loki-grafanacloud-secret/client-id)
  export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME}/${BUILD_ID}"
  export PROMTAIL_IMAGE="quay.io/openshift-cr/promtail"
  export PROMTAIL_VERSION="v2.4.1"

  config_dir=/tmp/promtail
  mkdir -p "${config_dir}"
  cp /var/run/loki-grafanacloud-secret/client-secret "${config_dir}/grafanacom-secrets-password"
  cat >> "${config_dir}/promtail_config.yml" << EOF
clients:
  - backoff_config:
      max_period: 5m
      max_retries: 20
      min_period: 1s
    batchsize: 102400
    batchwait: 10s
    basic_auth:
      username: ${GRAFANACLOUND_USERNAME}
      password_file: /etc/promtail/grafanacom-secrets-password
    timeout: 10s
    url: https://logs-prod3.grafana.net/api/prom/push
positions:
  filename: "/run/promtail/positions.yaml"
scrape_configs:
- job_name: kubernetes-pods-static
  pipeline_stages:
  - cri: {}
  - labeldrop:
    - filename
  - pack:
      labels:
      - namespace
      - pod_name
      - container_name
      - app
  - labelallow:
      - host
      - invoker
  kubernetes_sd_configs:
  - role: pod
  relabel_configs:
  - action: drop
    regex: ''
    source_labels:
    - __meta_kubernetes_pod_uid
  - source_labels:
    - __meta_kubernetes_pod_label_name
    target_label: __service__
  - source_labels:
    - __meta_kubernetes_pod_node_name
    target_label: __host__
  - action: replace
    replacement:
    separator: "/"
    source_labels:
    - __meta_kubernetes_namespace
    - __service__
    target_label: job
  - action: replace
    source_labels:
    - __meta_kubernetes_namespace
    target_label: namespace
  - action: replace
    source_labels:
    - __meta_kubernetes_pod_name
    target_label: pod_name
  - action: replace
    source_labels:
    - __meta_kubernetes_pod_container_name
    target_label: container_name
  - replacement: /var/log/pods/*\$1/*.log
    separator: /
    source_labels:
    - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
    - __meta_kubernetes_pod_container_name
    target_label: __path__
  - action: labelmap
    regex: __meta_kubernetes_pod_label_(.+)
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
  - labelallow:
      - host
      - invoker
  relabel_configs:
  - action: labelmap
    regex: __journal__(.+)
server:
  http_listen_port: 3101
target_config:
  sync_period: 10s
EOF

  cat >> "${config_dir}/bootstrap.yml" << EOF
variant: fcos
version: 1.1.0
ignition:
  config:
    merge:
      - local: bootstrap_initial.ign
storage:
  files:
    - path: /etc/promtail/grafanacom-secrets-password
      contents:
        local: grafanacom-secrets-password
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
        Wants=network-online.target
        After=network-online.target

        [Service]
        ExecStartPre=/usr/bin/podman create --rm --name=promtail -v /var/log/journal/:/var/log/journal/:z -v /etc/machine-id:/etc/machine-id -v /etc/promtail:/etc/promtail ${PROMTAIL_IMAGE}:${PROMTAIL_VERSION} -config.file=/etc/promtail/config.yaml -client.external-labels=host=%H,invoker='${OPENSHIFT_INSTALL_INVOKER}'
        ExecStart=/usr/bin/podman start -a promtail
        ExecStop=-/usr/bin/podman stop -t 10 promtail
        Restart=always
        RestartSec=60

        [Install]
        WantedBy=multi-user.target
EOF
  echo "Copying ${config_dir} to sno-bootstrap-manifests"
  ssh "${SSHOPTS[@]}" "root@${IP}" "rm -rf /root/sno-bootstrap-manifests && mkdir /root/sno-bootstrap-manifests"
  while IFS= read -r -d '' item
  do
    echo "Copying ${item}"
    scp "${SSHOPTS[@]}" "${item}" "root@${IP}:sno-bootstrap-manifests/"
  done < <( find "${config_dir}" \( -name "*.yml" \) -print0)
fi

# TODO: Figure out way to get these parameters (used by deploy_ibip) without hardcoding them here
# preferrably by making deploy_ibip / makefile perform these configurations itself in the assisted_test_infra
# repo.
export SINGLE_NODE_IP_ADDRESS="192.168.127.10"
export CLUSTER_NAME="test-infra-cluster"
export CLUSTER_API_DOMAIN="api.${CLUSTER_NAME}.redhat.com"
export CLUSTER_INGRESS_SUB_DOMAIN="apps.${CLUSTER_NAME}.redhat.com"
export INGRESS_APPS=(oauth-openshift console-openshift-console canary-openshift-ingress-canary thanos-querier-openshift-monitoring)

timeout -s 9 175m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeuo pipefail

# Some Packet images have a file /usr/config left from the provisioning phase.
# The problem is that sos expects it to be a directory. Since we don't care
# about the Packet provisioner, remove the file if it's present.
test -f /usr/config && rm -f /usr/config || true

dnf install -y git sysstat sos make
systemctl start sysstat

mkdir -p /tmp/artifacts

REPO_DIR="/home/sno"
mkdir -p "\${REPO_DIR}"

# NVMe makes it faster
NVME_DEVICE="/dev/nvme0n1"
if [ -e "\$NVME_DEVICE" ];
then
  mkfs.xfs -f "\${NVME_DEVICE}"
  mount "\${NVME_DEVICE}" "\${REPO_DIR}"
fi

tar -xzvf sno.tar.gz -C "\${REPO_DIR}"
chown -R root:root "\${REPO_DIR}"

cd "\${REPO_DIR}"

set +x
echo "export PULL_SECRET='\$(cat /root/pull-secret)'" >> /root/config
echo "export NO_MINIKUBE=true" >> /root/config

echo "export OPENSHIFT_INSTALL_RELEASE_IMAGE=${OPENSHIFT_INSTALL_RELEASE_IMAGE:-${RELEASE_IMAGE_LATEST}}" >> /root/config

set -x

if [[ -e /root/sno-additional-config ]]
then
  cat /root/sno-additional-config >> /root/config
fi

echo "export KUBECONFIG=\${REPO_DIR}/build/ibip/auth/kubeconfig" >> /root/.bashrc

source /root/config

# Configure dnsmasq
echo "${SINGLE_NODE_IP_ADDRESS} ${CLUSTER_API_DOMAIN}" | tee --append /etc/hosts
for ingress_app in ${INGRESS_APPS[@]}; do
  echo "${SINGLE_NODE_IP_ADDRESS} \${ingress_app}.${CLUSTER_INGRESS_SUB_DOMAIN}" | tee --append /etc/hosts
done

echo Reloading NetworkManager systemd configuration
systemctl reload NetworkManager

export TEST_ARGS="TEST_FUNC=${TEST_FUNC}"
if [[ -e /root/sno-additional-manifests ]]
then
  TEST_ARGS="\${TEST_ARGS} ADDITIONAL_MANIFEST_DIR=/root/sno-additional-manifests"
fi
if [[ -e /root/sno-bootstrap-manifests ]]
then
  TEST_ARGS="\${TEST_ARGS} BOOTSTRAP_INJECT_MANIFEST=/root/sno-bootstrap-manifests/bootstrap.yml"
fi
timeout -s 9 105m make setup deploy_ibip \${TEST_ARGS}

EOF
