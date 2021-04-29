#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export LOKI_VERSION="2.2.1"

cat >> "${SHARED_DIR}/manifest_loki-ns.yml" << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: loki
EOF
cat >> "${SHARED_DIR}/manifest_loki-clusterrole.yml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lokiclusterrole
rules:
- apiGroups:
  - security.openshift.io
  resourceNames:
  - privileged
  resources:
  - securitycontextconstraints
  verbs:
  - use
EOF
cat >> "${SHARED_DIR}/manifest_loki-clusterrolebinding.yml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: lokiclusterrolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: lokiclusterrole
subjects:
- kind: ServiceAccount
  name: loki-promtail
  namespace: loki
EOF
cat >> "${SHARED_DIR}/manifest_loki-psp.yml" << EOF
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: loki
spec:
  allowPrivilegeEscalation: false
  fsGroup:
    ranges:
    - max: 65535
      min: 1
    rule: MustRunAs
  hostIPC: false
  hostNetwork: false
  hostPID: false
  privileged: false
  readOnlyRootFilesystem: true
  requiredDropCapabilities:
  - ALL
  runAsUser:
    rule: MustRunAsNonRoot
  seLinux:
    rule: RunAsAny
  supplementalGroups:
    ranges:
    - max: 65535
      min: 1
    rule: MustRunAs
  volumes:
  - configMap
  - emptyDir
  - persistentVolumeClaim
  - secret
EOF
cat >> "${SHARED_DIR}/manifest_loki-role.yml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: loki
  namespace: loki
rules:
- apiGroups:
  - extensions
  resourceNames:
  - loki
  resources:
  - podsecuritypolicies
  verbs:
  - use
EOF
cat >> "${SHARED_DIR}/manifest_loki-rolebinding.yml" << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: loki
  namespace: loki
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: loki
subjects:
- kind: ServiceAccount
  name: loki
EOF
cat >> "${SHARED_DIR}/manifest_loki-secret.yml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: loki
  namespace: loki
stringData:
  loki.yaml: |-
    auth_enabled: false
    chunk_store_config:
      max_look_back_period: 0
    ingester:
      chunk_block_size: 1572864
      chunk_encoding: lz4
      chunk_idle_period: 3m
      chunk_retain_period: 1m
      lifecycler:
        ring:
          kvstore:
            store: inmemory
          replication_factor: 1
      max_transfer_retries: 0
    limits_config:
      enforce_metric_name: false
      reject_old_samples: true
      reject_old_samples_max_age: 168h
      max_entries_limit_per_query: 0
    schema_config:
      configs:
      - from: '2018-04-15'
        index:
          period: 168h
          prefix: index_
        object_store: filesystem
        schema: v9
        store: boltdb
    server:
      http_listen_port: 3100
    storage_config:
      boltdb:
        directory: "/data/loki/index"
      filesystem:
        directory: "/data/loki/chunks"
    table_manager:
      retention_deletes_enabled: false
      retention_period: 0
EOF
cat >> "${SHARED_DIR}/manifest_loki-service.yml" << EOF
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/component: storage
    app.kubernetes.io/instance: loki
    app.kubernetes.io/name: loki
    app.kubernetes.io/part-of: loki
    app.kubernetes.io/version: ${LOKI_VERSION}
  name: loki
  namespace: loki
spec:
  ports:
  - name: http-metrics
    port: 3100
    protocol: TCP
    targetPort: http-metrics
  selector:
    app.kubernetes.io/component: storage
    app.kubernetes.io/instance: loki
    app.kubernetes.io/name: loki
    app.kubernetes.io/part-of: loki
  sessionAffinity: ClientIP
  type: ClusterIP
EOF
cat >> "${SHARED_DIR}/manifest_loki-sa.yml" << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: loki
  namespace: loki
EOF
cat >> "${SHARED_DIR}/manifest_loki-ss.yml" << EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: loki
  namespace: loki
spec:
  podManagementPolicy: OrderedReady
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/component: storage
      app.kubernetes.io/instance: loki
      app.kubernetes.io/name: loki
      app.kubernetes.io/part-of: loki
  serviceName: loki
  template:
    metadata:
      annotations:
        checksum/config: 55afb5b69f885f3b5401e2dc407a800cb71f9521ff62a07630e2f8473c101116
      labels:
        app.kubernetes.io/component: storage
        app.kubernetes.io/instance: loki
        app.kubernetes.io/name: loki
        app.kubernetes.io/part-of: loki
        app.kubernetes.io/version: ${LOKI_VERSION}
    spec:
      containers:
      - args:
        - "-config.file=/etc/loki/loki.yaml"
        image: grafana/loki:${LOKI_VERSION}
        imagePullPolicy: IfNotPresent
        livenessProbe:
          httpGet:
            path: "/ready"
            port: http-metrics
          initialDelaySeconds: 45
        name: loki
        ports:
        - containerPort: 3100
          name: http-metrics
          protocol: TCP
        readinessProbe:
          httpGet:
            path: "/ready"
            port: http-metrics
          initialDelaySeconds: 45
        securityContext:
          readOnlyRootFilesystem: true
        volumeMounts:
        - mountPath: "/etc/loki"
          name: config
        - mountPath: "/data"
          name: storage
      serviceAccountName: loki
      terminationGracePeriodSeconds: 4800
      volumes:
      - name: config
        secret:
          secretName: loki
      - emptyDir: {}
        name: storage
  updateStrategy:
    type: RollingUpdate
EOF
cat >> "${SHARED_DIR}/manifest_promtail-clusterrole.yml" << EOF
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
EOF
cat >> "${SHARED_DIR}/manifest_promtail-clusterrolebinding.yml" << EOF
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
cat >> "${SHARED_DIR}/manifest_promtail-cm.yml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-promtail
  namespace: loki
data:
  promtail.yaml: |-
    client:
      backoff_config:
        max_period: 5s
        max_retries: 20
        min_period: 100ms
      batchsize: 102400
      batchwait: 1s
      external_labels: {}
      timeout: 10s
      url: http://loki.loki.svc.cluster.local:3100/loki/api/v1/push
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
    server:
      http_listen_port: 3101
    target_config:
      sync_period: 10s
EOF
cat >> "${SHARED_DIR}/manifest_promtail-ds.yml" << EOF
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
      annotations:
        checksum/config: 72932794b92cf3e3b0f6c057ac848227
      labels:
        app.kubernetes.io/component: log-collector
        app.kubernetes.io/instance: loki-promtail
        app.kubernetes.io/name: promtail
        app.kubernetes.io/part-of: loki
        app.kubernetes.io/version: ${LOKI_VERSION}
    spec:
      containers:
      - command:
        - sh
        - -c
        - |
          promtail \
            -client.external-labels=_id=\$(cat /tmp/shared/cluster-id),host=\$(HOSTNAME) \
            -config.file=/etc/promtail/promtail.yaml
        env:
        - name: HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        image: quay.io/vrutkovs/promtail:${LOKI_VERSION}
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
      initContainers:
      - command:
        - sh
        - "-c"
        - while [[ "\$(curl -s -o /dev/null -w '%{http_code}' http://loki.loki.svc.cluster.local:3100/ready)"
          != "200" ]]; do sleep 5s; done
        image: curlimages/curl:7.69.1
        name: waitforloki
      - command:
        - sh
        - "-c"
        - oc get clusterversion/version -o=jsonpath='{.spec.clusterID}' > /tmp/shared/cluster-id
        volumeMounts:
          - mountPath: "/tmp/shared"
            name: shared-data
        image: quay.io/openshift/origin-cli:4.6.0
        name: fetch-cluster-id
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
      - emptyDir: {}
        name: shared-data
  updateStrategy:
    type: RollingUpdate
EOF
cat >> "${SHARED_DIR}/manifest_promtail-psp.yml" << EOF
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
cat >> "${SHARED_DIR}/manifest_promtail-role.yml" << EOF
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
cat >> "${SHARED_DIR}/manifest_promtail-rolebinding.yml" << EOF
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
cat >> "${SHARED_DIR}/manifest_promtail-sa.yml" << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: loki-promtail
  namespace: loki
EOF
