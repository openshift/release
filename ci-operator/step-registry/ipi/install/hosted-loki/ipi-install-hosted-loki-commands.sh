#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PROMTAIL_IMAGE="quay.io/openshift-cr/promtail"
export PROMTAIL_VERSION="v2.4.1"
export LOKI_ENDPOINT=https://observatorium.api.stage.openshift.com/api/logs/v1/dptp/loki/api/v1
export KUBERNETES_EVENT_EXPORTER_IMAGE="ghcr.io/opsgenie/kubernetes-event-exporter"
export KUBERNETES_EVENT_EXPORTER_VERSION="v0.11"

GRAFANACLOUND_USERNAME=$(cat /var/run/loki-grafanacloud-secret/client-id)
export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME}/${BUILD_ID}"

cat >> "${SHARED_DIR}/manifest_01_ns.yml" << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-e2e-loki
EOF
cat >> "${SHARED_DIR}/manifest_clusterrole.yml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: loki-promtail
rules:
- apiGroups:
  - ''
  resources:
  - nodes
  - nodes/proxy
  - services
  - endpoints
  - pods
  - configmaps
  verbs:
  - get
  - watch
  - list
- apiGroups:
  - 'config.openshift.io'
  resources:
  - 'clusterversions'
  verbs:
  - 'get'
- apiGroups:
  - security.openshift.io
  resourceNames:
  - privileged
  resources:
  - securitycontextconstraints
  verbs:
  - use
EOF
cat >> "${SHARED_DIR}/manifest_clusterrolebinding.yml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: loki-promtail
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: loki-promtail
subjects:
- kind: ServiceAccount
  name: loki-promtail
  namespace: openshift-e2e-loki
EOF
cat >> "${SHARED_DIR}/manifest_cm.yml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-promtail
  namespace: openshift-e2e-loki
data:
  promtail.yaml: |-
    clients:
      - backoff_config:
          max_period: 5m
          max_retries: 20
          min_period: 1s
        batchsize: 102400
        batchwait: 10s
        basic_auth:
          username: ${GRAFANACLOUND_USERNAME}
          password_file: /etc/promtail-grafanacom-secrets/password
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
      - match:
          selector: '{app="event-exporter", namespace="openshift-e2e-loki"}'
          action: drop
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
          - audit
      relabel_configs:
      - action: drop
        regex: ''
        source_labels:
        - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
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
    - job_name: events
      kubernetes_sd_configs:
      - role: pod
      pipeline_stages:
      - cri: {}
      - match:
          selector: '{app="event-exporter", namespace="openshift-e2e-loki"}'
          stages:
          - static_labels:
              audit: events
      - labelallow:
          - host
          - invoker
          - audit
      relabel_configs:
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - replacement: "/var/log/pods/*\$1/*.log"
        separator: "/"
        source_labels:
        - __meta_kubernetes_pod_uid
        - __meta_kubernetes_pod_container_name
        target_label: __path__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
    server:
      http_listen_port: 3101
    target_config:
      sync_period: 10s
EOF
cat >> "${SHARED_DIR}/manifest_creds.yml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: promtail-creds
  namespace: openshift-e2e-loki
data:
  client-id: "$(cat /var/run/loki-secret/client-id | base64 -w 0)"
  client-secret: "$(cat /var/run/loki-secret/client-secret | base64 -w 0)"
EOF
cat >> "${SHARED_DIR}/manifest_grafanacom_creds.yml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: promtail-grafanacom-creds
  namespace: openshift-e2e-loki
data:
  password: "$(cat /var/run/loki-grafanacloud-secret/client-secret | base64 -w 0)"
EOF
cat >> "${SHARED_DIR}/manifest_ds.yml" << EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: loki-promtail
  namespace: openshift-e2e-loki
spec:
  selector:
    matchLabels:
      app.kubernetes.io/component: log-collector
      app.kubernetes.io/instance: loki-promtail
      app.kubernetes.io/name: promtail
      app.kubernetes.io/part-of: loki
  template:
    metadata:
      labels:
        app.kubernetes.io/component: log-collector
        app.kubernetes.io/instance: loki-promtail
        app.kubernetes.io/name: promtail
        app.kubernetes.io/part-of: loki
        app.kubernetes.io/version: ${PROMTAIL_VERSION}
    spec:
      containers:
      - command:
        - promtail
        - -client.external-labels=host=\$(HOSTNAME),invoker=\$(INVOKER)
        - -config.file=/etc/promtail/promtail.yaml
        env:
        - name: HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: INVOKER
          value: "${OPENSHIFT_INSTALL_INVOKER}"
        image: ${PROMTAIL_IMAGE}:${PROMTAIL_VERSION}
        imagePullPolicy: IfNotPresent
        resources:
          requests:
            cpu: 10m
            memory: 20Mi
        lifecycle:
          preStop:
            # We want the pod to keep running when a node is being drained
            # long enough to exfiltrate the last set of logs from static pods
            # from things like etcd and the kube-apiserver. To do that, we need
            # to stay alive longer than the longest shutdown duration will be
            # run, which should be 135s from kube-apiserver.
            exec:
              command: ["sleep", "150"]
        name: promtail
        ports:
        - containerPort: 3101
          name: http-metrics
        readinessProbe:
          failureThreshold: 5
          httpGet:
            path: "/ready"
            port: http-metrics
          initialDelaySeconds: 10
          periodSeconds: 10
          successThreshold: 1
          timeoutSeconds: 1
        securityContext:
          privileged: true
          readOnlyRootFilesystem: true
          runAsGroup: 0
          runAsUser: 0
        volumeMounts:
        - mountPath: "/etc/promtail"
          name: config
        - mountPath: "/etc/promtail-grafanacom-secrets"
          name: grafanacom-secrets
        - mountPath: "/run/promtail"
          name: run
        - mountPath: "/var/lib/docker/containers"
          name: docker
          readOnly: true
        - mountPath: "/var/log/pods"
          name: pods
          readOnly: true
        - mountPath: "/var/log/kube-apiserver"
          name: auditlogs-kube-apiserver
          readOnly: true
        - mountPath: "/var/log/openshift-apiserver"
          name: auditlogs-openshift-apiserver
          readOnly: true
        - mountPath: "/var/log/oauth-apiserver"
          name: auditlogs-oauth-apiserver
          readOnly: true
        - mountPath: "/var/log/journal"
          name: journal
          readOnly: true
      - args:
        - --https-address=:9001
        - --provider=openshift
        - --openshift-service-account=loki-promtail
        - --upstream=http://127.0.0.1:3101
        - --tls-cert=/etc/tls/private/tls.crt
        - --tls-key=/etc/tls/private/tls.key
        - --cookie-secret-file=/etc/tls/cookie-secret/cookie-secret
        - '--openshift-sar={"resource": "namespaces", "verb": "get"}'
        - '--openshift-delegate-urls={"/": {"resource": "namespaces", "verb": "get"}}'
        image: registry.redhat.io/openshift4/ose-oauth-proxy:latest
        imagePullPolicy: IfNotPresent
        name: oauth-proxy
        ports:
        - containerPort: 9001
          name: metrics
          protocol: TCP
        resources:
          requests:
            cpu: 20m
            memory: 50Mi
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /etc/tls/private
          name: proxy-tls
        - mountPath: /etc/tls/cookie-secret
          name: cookie-secret
      serviceAccountName: loki-promtail
      terminationGracePeriodSeconds: 180
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/master
        operator: Exists
      priorityClassName: system-cluster-critical
      volumes:
      - configMap:
          name: loki-promtail
        name: config
      - secret:
          secretName: promtail-grafanacom-creds
        name: grafanacom-secrets
      - hostPath:
          path: "/run/promtail"
        name: run
      - hostPath:
          path: "/var/lib/docker/containers"
        name: docker
      - hostPath:
          path: "/var/log/pods"
        name: pods
      - hostPath:
          path: "/var/log/journal"
        name: journal
      - hostPath:
          path: "/var/log/kube-apiserver"
        name: auditlogs-kube-apiserver
      - hostPath:
          path: "/var/log/openshift-apiserver"
        name: auditlogs-openshift-apiserver
      - hostPath:
          path: "/var/log/oauth-apiserver"
        name: auditlogs-oauth-apiserver
      - name: proxy-tls
        secret:
          defaultMode: 420
          secretName: proxy-tls
      - name: cookie-secret
        secret:
          defaultMode: 420
          secretName: cookie-secret
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 10%
      maxSurge: 0
EOF
cat >> "${SHARED_DIR}/manifest_promtail_cookie_secret.yml" << EOF
kind: Secret
apiVersion: v1
metadata:
  name: cookie-secret
  namespace: openshift-e2e-loki
data:
  cookie-secret: Y2I3YzljNmJxaGQ5dndwdjV3ZHQ2YzVwY3B6MnI0Zmo=
type: Opaque
EOF
cat >> "${SHARED_DIR}/manifest_promtail_service.yml" << EOF
kind: Service
apiVersion: v1
metadata:
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: proxy-tls
  name: promtail
  namespace: openshift-e2e-loki
spec:
  ports:
    - name: metrics
      protocol: TCP
      port: 9001
      targetPort: metrics
  selector:
    app.kubernetes.io/name: promtail
  type: ClusterIP
EOF
cat >> "${SHARED_DIR}/manifest_psp.yml" << EOF
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: loki-promtail
spec:
  allowPrivilegeEscalation: false
  fsGroup:
    rule: RunAsAny
  hostIPC: false
  hostNetwork: false
  hostPID: false
  privileged: false
  readOnlyRootFilesystem: true
  requiredDropCapabilities:
  - ALL
  runAsUser:
    rule: RunAsAny
  seLinux:
    rule: RunAsAny
  supplementalGroups:
    rule: RunAsAny
  volumes:
  - secret
  - configMap
  - hostPath
EOF
cat >> "${SHARED_DIR}/manifest_role.yml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: loki-promtail
  namespace: openshift-e2e-loki
rules:
- apiGroups:
  - extensions
  resourceNames:
  - loki-promtail
  resources:
  - podsecuritypolicies
  verbs:
  - use
EOF
cat >> "${SHARED_DIR}/manifest_rolebinding.yml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: loki-promtail
  namespace: openshift-e2e-loki
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: loki-promtail
subjects:
- kind: ServiceAccount
  name: loki-promtail
EOF
cat >> "${SHARED_DIR}/manifest_oauth_role.yml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: loki-promtail-oauth
  namespace: openshift-e2e-loki
rules:
- apiGroups:
  - authentication.k8s.io
  resources:
  - tokenreviews
  verbs:
  - create
  - get
  - list
- apiGroups:
  - authorization.k8s.io
  resources:
  - subjectaccessreviews
  verbs:
  - create
EOF
cat >> "${SHARED_DIR}/manifest_oauth_clusterrolebinding.yml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: loki-promtail-oauth
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: loki-promtail-oauth
subjects:
- kind: ServiceAccount
  name: loki-promtail
  namespace: openshift-e2e-loki
EOF
cat >> "${SHARED_DIR}/manifest_sa.yml" << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: loki-promtail
  namespace: openshift-e2e-loki
EOF
if [ -n "${LOKI_USE_SERVICEMONITOR:-}" ]; then
  echo "Including Loki servicemonitor manifests (LOKI_USE_SERVICEMONITOR='${LOKI_USE_SERVICEMONITOR}')"
  cat >> "${SHARED_DIR}/manifest_metrics.yml" << EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: promtail-monitor
  namespace: openshift-monitoring
spec:
  endpoints:
    - bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
      bearerTokenSecret:
        key: ''
      interval: 30s
      port: metrics
      targetPort: 9001
      scheme: https
      tlsConfig:
        ca: {}
        caFile: /etc/prometheus/configmaps/serving-certs-ca-bundle/service-ca.crt
        cert: {}
        serverName: promtail.openshift-e2e-loki.svc
  namespaceSelector:
    matchNames:
      - openshift-e2e-loki
  selector: {}
EOF
  cat >> "${SHARED_DIR}/manifest_metrics_role.yml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: promtail-prometheus
  namespace: openshift-e2e-loki
rules:
- apiGroups:
  - ""
  resources:
  - services
  - endpoints
  - pods
  verbs:
  - get
  - list
  - watch
EOF
  cat >> "${SHARED_DIR}/manifest_metrics_rb.yml" << EOF
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: prom-scrape-loki
  namespace: openshift-e2e-loki
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: promtail-prometheus
subjects:
  - kind: ServiceAccount
    name: prometheus-k8s
    namespace: openshift-monitoring
EOF
fi

cat >> "${SHARED_DIR}/manifest_eventexporter_sa.yml" << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  namespace: openshift-e2e-loki
  name: event-exporter
EOF
cat >> "${SHARED_DIR}/manifest_eventexporter_crb.yml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: event-exporter
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    namespace: openshift-e2e-loki
    name: event-exporter
EOF
cat >> "${SHARED_DIR}/manifest_eventexporter_config.yml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: event-exporter-cfg
  namespace: openshift-e2e-loki
data:
  config.yaml: |
    logLevel: error
    logFormat: json
    route:
      routes:
        - match:
            - receiver: "dump"
    receivers:
      - name: "dump"
        stdout: {}
EOF
cat >> "${SHARED_DIR}/manifest_eventexporter_deployment.yml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: event-exporter
  namespace: openshift-e2e-loki
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: event-exporter
    spec:
      priorityClassName: system-cluster-critical
      serviceAccountName: event-exporter
      containers:
        - name: event-exporter
          image: ${KUBERNETES_EVENT_EXPORTER_IMAGE}:${KUBERNETES_EVENT_EXPORTER_VERSION}
          imagePullPolicy: IfNotPresent
          resources:
            requests:
              cpu: 10m
              memory: 20Mi
          args:
            - -conf=/data/config.yaml
          volumeMounts:
            - mountPath: /data
              name: cfg
      volumes:
        - name: cfg
          configMap:
            name: event-exporter-cfg
  selector:
    matchLabels:
      app: event-exporter
EOF

echo "Promtail manifests created, the cluster can be found at https://grafana-loki.ci.openshift.org/explore using '{invoker=\"${OPENSHIFT_INSTALL_INVOKER}\"} | unpack' query. See https://gist.github.com/vrutkovs/ef7cc9bca50f5f49d7eab831e3f082d8 for Loki cheat sheet."


if [[ -f "/usr/bin/python3" ]]; then
  ENCODED_INVOKER="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${OPENSHIFT_INSTALL_INVOKER}'))")"
  cat >> ${SHARED_DIR}/custom-links.txt << EOF
  <a target="_blank" href="https://grafana-loki.ci.openshift.org/explore?orgId=1&left=%5B%22now-24h%22,%22now%22,%22Grafana%20Cloud%22,%7B%22expr%22:%22%7Binvoker%3D%5C%22${ENCODED_INVOKER}%5C%22%7D%20%7C%20unpack%22%7D%5D" title="Loki is a log aggregation system for examining CI logs. This is most useful with upgrades, which do not contain pre-upgrade logs in the must-gather.">Loki</a>&nbsp;<a target="_blank" href="https://gist.github.com/vrutkovs/ef7cc9bca50f5f49d7eab831e3f082d8" title="Cheat sheet for Loki search queries">Loki cheat sheet</a>
EOF
fi
