#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PROMTAIL_IMAGE="quay.io/openshift-logging/promtail"
export PROMTAIL_VERSION="v2.3.0"
export LOKI_ENDPOINT=https://observatorium.api.stage.openshift.com/api/logs/v1/dptp/loki/api/v1

export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME}/${BUILD_ID}"

PROMTAIL_CONFIG_BASE64="$(base64 -w0 << EOF
clients:
  - backoff_config:
      max_period: 5m
      max_retries: 20
      min_period: 1s
    batchsize: 102400
    batchwait: 10s
    basic_auth:
      username: $(cat /var/run/loki-grafanacloud-secret/client-id)
      password_file: $(cat /var/run/loki-grafanacloud-secret/client-secret | base64 -w 0)
    timeout: 10s
    url: https://logs-prod3.grafana.net/api/prom/push
positions:
  filename: "/run/promtail/positions.yaml"
scrape_configs:
- job_name: kubernetes
  kubernetes_sd_configs:
  - role: pod
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
  relabel_configs:
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
  - replacement: "/var/log/pods/*\$1/*.log"
    separator: "/"
    source_labels:
    - __meta_kubernetes_pod_uid
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
- job_name: kubeapi-audit
  static_configs:
  - targets:
    - localhost
    labels:
      audit: kube-apiserver
      __path__: /var/log/kube-apiserver/audit.log
- job_name: openshift-apiserver
  static_configs:
  - targets:
    - localhost
    labels:
      audit: openshift-apiserver
      __path__: /var/log/openshift-apiserver/audit.log
- job_name: oauth-apiserver-audit
  static_configs:
  - targets:
    - localhost
    labels:
      audit: oauth-apiserver
      __path__: /var/log/oauth-apiserver/audit.log
server:
  http_listen_port: 3101
target_config:
  sync_period: 10s
EOF
)"

cat >> "${SHARED_DIR}/manifest_promtail-master.yml" << EOF
kind: MachineConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: promtail
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  config:
    ignition:
      version: 3.1.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${PROMTAIL_CONFIG_BASE64}
        mode: 0544
        overwrite: true
        path: /etc/promtail/promtail.yaml
    systemd:
      units:
        - contents: |
            [Unit]
            Description=Promtail
            After=multi-user.target
            [Service]
            Type=simple
            User=promtail
            ExecStart=/usr/bin/podman run --rm -v etc/promtail/promtail.yaml:etc/promtail/promtail.yaml -v /var/log/:/var/log/ -ti ${PROMTAIL_IMAGE}:${PROMTAIL_VERSION} -client.external-labels=host=%H,invoker=${OPENSHIFT_INSTALL_INVOKER}- -config.file=/etc/promtail/promtail.yaml

            [Install]
            WantedBy=multi-user.target
          name: promtail.service
          enabled: true
EOF

sed 's;role: master;role: worker;g' ${SHARED_DIR}/manifest_promtail-master.yml > ${SHARED_DIR}/manifest_promtail-worker.yml

echo "Promtail manifests created, the cluster can be found at https://grafana-loki.ci.openshift.org/explore using '{invoker=\"${OPENSHIFT_INSTALL_INVOKER}\"} | unpack' query. See https://gist.github.com/vrutkovs/ef7cc9bca50f5f49d7eab831e3f082d8 for Loki cheat sheet."


if [[ -f "/usr/bin/python3" ]]; then
  ENCODED_INVOKER="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${OPENSHIFT_INSTALL_INVOKER}'))")"
  cat >> ${SHARED_DIR}/custom-links.txt << EOF
  <a target="_blank" href="https://grafana-loki.ci.openshift.org/explore?orgId=1&left=%5B%22now-24h%22,%22now%22,%22Grafana%20Cloud%22,%7B%22expr%22:%22%7Binvoker%3D%5C%22${ENCODED_INVOKER}%5C%22%7D%20%7C%20unpack%22%7D%5D">Loki</a>&nbsp;<a target="_blank" href="https://gist.github.com/vrutkovs/ef7cc9bca50f5f49d7eab831e3f082d8">Loki cheat sheet</a>
EOF
fi
