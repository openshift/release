#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export LOKI_VERSION="2.0.0"
export LOKI_ENDPOINT=https://observatorium.api.stage.openshift.com/api/logs/v1/dptp/loki/api/v1

cat >> "${SHARED_DIR}/manifest_01_ns.yml" << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: loki
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
  namespace: loki
EOF
cat >> "${SHARED_DIR}/manifest_cm.yml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-promtail
  namespace: loki
data:
  promtail.yaml: |-
    client:
      backoff_config:
        max_period: 5m
        max_retries: 20
        min_period: 1s
      batchsize: 102400
      batchwait: 10s
      bearer_token_file: /tmp/shared/bearer_token
      timeout: 10s
      url: ${LOKI_ENDPOINT}/push
    positions:
      filename: "/run/promtail/positions.yaml"
    scrape_configs:
    - job_name: kubernetes-pods-name
      kubernetes_sd_configs:
      - role: pod
      pipeline_stages:
      - cri: {}
      relabel_configs:
      - source_labels:
        - __meta_kubernetes_pod_label_name
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ''
        source_labels:
        - __service__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
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
        target_label: instance
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
    - job_name: kubernetes-pods-app
      kubernetes_sd_configs:
      - role: pod
      pipeline_stages:
      - cri: {}
      relabel_configs:
      - action: drop
        regex: ".+"
        source_labels:
        - __meta_kubernetes_pod_label_name
      - source_labels:
        - __meta_kubernetes_pod_label_app
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ''
        source_labels:
        - __service__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
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
        target_label: instance
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
    - job_name: kubernetes-pods-direct-controllers
      kubernetes_sd_configs:
      - role: pod
      pipeline_stages:
      - cri: {}
      relabel_configs:
      - action: drop
        regex: ".+"
        separator: ''
        source_labels:
        - __meta_kubernetes_pod_label_name
        - __meta_kubernetes_pod_label_app
      - action: drop
        regex: "[0-9a-z-.]+-[0-9a-f]{8,10}"
        source_labels:
        - __meta_kubernetes_pod_controller_name
      - source_labels:
        - __meta_kubernetes_pod_controller_name
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ''
        source_labels:
        - __service__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
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
        target_label: instance
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
    - job_name: kubernetes-pods-indirect-controller
      kubernetes_sd_configs:
      - role: pod
      pipeline_stages:
      - cri: {}
      relabel_configs:
      - action: drop
        regex: ".+"
        separator: ''
        source_labels:
        - __meta_kubernetes_pod_label_name
        - __meta_kubernetes_pod_label_app
      - action: keep
        regex: "[0-9a-z-.]+-[0-9a-f]{8,10}"
        source_labels:
        - __meta_kubernetes_pod_controller_name
      - action: replace
        regex: "([0-9a-z-.]+)-[0-9a-f]{8,10}"
        source_labels:
        - __meta_kubernetes_pod_controller_name
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ''
        source_labels:
        - __service__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
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
        target_label: instance
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
    - job_name: kubernetes-pods-static
      kubernetes_sd_configs:
      - role: pod
      pipeline_stages:
      - cri: {}
      relabel_configs:
      - action: drop
        regex: ''
        source_labels:
        - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_label_component
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ''
        source_labels:
        - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
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
        target_label: instance
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_container_name
        target_label: container_name
      - replacement: "/var/log/pods/*\$1/*.log"
        separator: "/"
        source_labels:
        - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
        - __meta_kubernetes_pod_container_name
        target_label: __path__
    - job_name: journal
      journal:
        path: /var/log/journal
        labels:
          job: systemd-journal
      relabel_configs:
      - action: labelmap
        regex: __journal__(boot_id|systemd_unit)
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
  namespace: loki
data:
  client-id: "$(cat /var/run/loki-secret/client-id | base64 -w 0)"
  client-secret: "$(cat /var/run/loki-secret/client-secret | base64 -w 0)"
EOF
cat >> "${SHARED_DIR}/manifest_ds.yml" << EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: loki-promtail
  namespace: loki
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
        app.kubernetes.io/version: ${LOKI_VERSION}
    spec:
      containers:
      - args:
        - --oidc.client-id=\$(CLIENT_ID)
        - --oidc.client-secret=\$(CLIENT_SECRET)
        - --oidc.issuer-url=https://sso.redhat.com/auth/realms/redhat-external
        - --margin=10m
        - --file=/tmp/shared/bearer_token
        name: bearer-token
        env:
          - name: CLIENT_ID
            valueFrom:
              secretKeyRef:
                name: promtail-creds
                key: client-id
          - name: CLIENT_SECRET
            valueFrom:
              secretKeyRef:
                name: promtail-creds
                key: client-secret
        volumeMounts:
        - mountPath: "/tmp/shared"
          name: shared-data
        image: quay.io/observatorium/token-refresher
      - command:
        - sh
        - -c
        - |
          promtail \
            -client.external-labels=_id=\$(cat /tmp/shared/cluster-id),host=\$(HOSTNAME),invoker=\$(cat /tmp/shared/cluster-invoker) \
            -config.file=/etc/promtail/promtail.yaml
        env:
        - name: HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        image: grafana/promtail:${LOKI_VERSION}
        imagePullPolicy: IfNotPresent
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
        - mountPath: "/run/promtail"
          name: run
        - mountPath: "/var/lib/docker/containers"
          name: docker
          readOnly: true
        - mountPath: "/var/log/pods"
          name: pods
          readOnly: true
        - mountPath: "/tmp/shared"
          name: shared-data
        - mountPath: "/var/log/journal"
          name: journal
          readOnly: true
      initContainers:
      - command:
        - sh
        - "-c"
        - oc get clusterversion/version -o=jsonpath='{.spec.clusterID}' > /tmp/shared/cluster-id && oc get cm openshift-install -n openshift-config -o=jsonpath='{.data.invoker}' > /tmp/shared/cluster-invoker
        volumeMounts:
          - mountPath: "/tmp/shared"
            name: shared-data
        image: quay.io/openshift/origin-cli:4.6.0
        name: fetch-cluster-data
      serviceAccountName: loki-promtail
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/master
        operator: Exists
      volumes:
      - configMap:
          name: loki-promtail
        name: config
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
      - emptyDir: {}
        name: shared-data
  updateStrategy:
    type: RollingUpdate
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
  namespace: loki
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
  namespace: loki
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: loki-promtail
subjects:
- kind: ServiceAccount
  name: loki-promtail
EOF
cat >> "${SHARED_DIR}/manifest_sa.yml" << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: loki-promtail
  namespace: loki
EOF
