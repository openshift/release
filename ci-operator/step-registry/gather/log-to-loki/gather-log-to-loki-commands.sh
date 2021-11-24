#!/bin/bash

GRAFANACLOUND_USERNAME=$(cat /var/run/loki-grafanacloud-secret/client-id)
GRAFANACLOUND_PASSWORD_FILE=/var/run/loki-grafanacloud-secret/client-secret

PROMETHEUS_ADAPTER_LOG_FILE=${SHARED_DIR}/prometheus-adapter-audit.log

# todo: use a container to run promtail "quay.io/openshift-logging/promtail:v2.3.0"
wget https://github.com/grafana/loki/releases/download/v2.4.2/promtail-linux-amd64.zip
unzip promtail-linux-amd64.zip
chmod +x promtail-linux-amd64

cat >promtail-stdin-prometheus-adapter.yaml <<EOF
positions:
  filename: /tmp/positions.yaml

clients:
  - backoff_config:
      max_period: 5m
      max_retries: 20
      min_period: 1s
    batchsize: 102400
    batchwait: 10s
    basic_auth:
      username: ${GRAFANACLOUND_USERNAME}
      password_file: ${GRAFANACLOUND_PASSWORD_FILE}
    timeout: 10s
    url: https://logs-prod3.grafana.net/api/prom/push

scrape_configs:
- job_name: stdin
  static_configs:
  - targets:
      - localhost
    labels:
      job: stdin
      audit: prometheus-adapter
EOF

cat ${PROMETHEUS_ADAPTER_LOG_FILE} | ./promtail-linux-amd64 -config.file=promtail-stdin-local-config.yaml -stdin
