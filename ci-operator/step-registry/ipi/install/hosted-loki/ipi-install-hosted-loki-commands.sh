#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "$LOKI_ENABLED" != "true" ]];
then
  exit 0
fi


PROXYCFGLINE=
PROXYLINE=
if test -f "${SHARED_DIR}/proxy-conf.sh" && [[ "$JOB_NAME" =~ .*ipv6.* ]]
then
    # https://issues.redhat.com/browse/OCPBUGS-29478
    echo "Clusters using a ipv6 are disabled temporarily"
    exit 0
    # proxy-conf.sh holds the IPv4 address, we can't use it here
    PROXYCFGLINE="        proxy_url: http://[fd00:1101::1]:8213"
    PROXYLINE="          - name: https_proxy
            value: http://[fd00:1101::1]:8213"
# Some kinds of jobs need to skip installing loki by default; but to make
# sure we rightfully skip them, we have two different conditions.
elif [[ "$JOB_NAME" =~ .*proxy.* ]] || test -f "${SHARED_DIR}/proxy-conf.sh"
then
  echo "Clusters using a proxy are not yet supported for loki"
  exit 0
# Some kinds of jobs need to skip installing loki by default
elif [[ "$JOB_NAME" =~ .*ipv6.* ]]
then
  echo "IPv6 clusters are disconnected and won't be able to reach Loki."
  exit 0
fi

export PROMTAIL_IMAGE="quay.io/openshift-logging/promtail"
export PROMTAIL_VERSION="v2.9.8"
# openshift-trt taken from the tenants list in the LokiStack CR on DPCR:
export LOKI_ENDPOINT=https://logging-loki-openshift-operators-redhat.apps.cr.j7t7.p1.openshiftapps.com/api/logs/v1/openshift-trt/loki/api/v1

# TODO: may be deprecated, moved to: https://github.com/resmoio/kubernetes-event-exporter
export KUBERNETES_EVENT_EXPORTER_IMAGE="ghcr.io/opsgenie/kubernetes-event-exporter"
export KUBERNETES_EVENT_EXPORTER_VERSION="v0.11"

export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME}/${BUILD_ID}"

cat >> "${SHARED_DIR}/manifest_01_ns.yml" << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-e2e-loki
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
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
        bearer_token_file: /tmp/shared/prod_bearer_token
$PROXYCFGLINE
        timeout: 10s
        url: ${LOKI_ENDPOINT}/push
    positions:
      filename: "/run/promtail/positions.yaml"
    scrape_configs:
    - job_name: kubernetes-pods
      kubernetes_sd_configs:
      - role: pod
      pipeline_stages:
      - cri: {}
      - static_labels:
          type: pod
      # Special match for the logs from the event-exporter pod, which logs json lines for each kube event.
      # For these we want to extract the namespace from metadata.namespace, rather than using the one
      # from the pod which did the logging. (openshift-e2e-loki)
      # This will allow us to search events globally with a namespace label that matches the actual event.
      - match:
          selector: '{app="event-exporter", namespace="openshift-e2e-loki"}'
          stages:
            # Two json stages to access the nested metadata.namespace field:
            - json:
                expressions:
                  metadata:
            - json:
                expressions:
                  namespace:
                source: metadata
            - labels:
                namespace:
            - static_labels:
                type: kube-event
      # For anything that is outside an openshift- namespace, we will pack it into the entry to
      # dramatically improve cardinality. These would typically be temporary namespaces with random
      # names created by e2e tests. We still keep their logs, you just don't get a fast label filter
      # to find them globally by namespace.
      #
      # We had to resort to a fixed list here because there are a lot of openshift-RAND namespaces created.
      # (must-gather, debug, amq, test, etc) If you want your namespaces to get it's own indexed namespace
      # label, add it here, in alphabetical order, and to the near identical line below with =~ instead of !~.
      - match:
          selector: '{namespace!~"openshift-addon-operator|openshift-apiserver|openshift-apiserver-operator|openshift-authentication|openshift-authentication-operator|openshift-cloud-controller-manager|openshift-cloud-controller-manager-operator|openshift-cloud-credential-operator|openshift-cloud-ingress-operator|openshift-cloud-network-config-controller|openshift-cluster-csi-drivers|openshift-cluster-machine-approver|openshift-cluster-node-tuning-operator|openshift-cluster-samples-operator|openshift-cluster-storage-operator|openshift-cluster-version|openshift-config|openshift-config-managed|openshift-config-operator|openshift-console|openshift-console-operator|openshift-console-user-settings|openshift-controller-manager|openshift-controller-manager-operator|openshift-custom-domains-operator|openshift-dns|openshift-dns-operator|openshift-etcd|openshift-etcd-operator|openshift-host-network|openshift-image-registry|openshift-infra|openshift-ingress|openshift-ingress-canary|openshift-ingress-operator|openshift-insights|openshift-kni-infra|openshift-kube-apiserver|openshift-kube-apiserver-operator|openshift-kube-controller-manager|openshift-kube-controller-manager-operator|openshift-kube-scheduler|openshift-kube-scheduler-operator|openshift-kube-storage-version-migrator|openshift-kube-storage-version-migrator-operator|openshift-logging|openshift-machine-api|openshift-machine-config-operator|openshift-managed-node-metadata-operator|openshift-managed-upgrade-operator|openshift-marketplace|openshift-monitoring|openshift-multus|openshift-network-diagnostics|openshift-network-operator|openshift-node|openshift-nutanix-infra|openshift-oauth-apiserver|openshift-observability-operator|openshift-ocm-agent-operator|openshift-openstack-infra|openshift-operator-lifecycle-manager|openshift-operators|openshift-operators-redhat|openshift-osd-metrics|openshift-ovirt-infra|openshift-priv|openshift-rbac-permissions|openshift-route-controller-manager|openshift-route-monitor-operator|openshift-sdn|openshift-security|openshift-service-ca|openshift-service-ca-operator|openshift-service-catalog-removed|openshift-user-workload-monitoring|openshift-validation-webhook|openshift-vsphere-infra"}'
          stages:
          - pack:
              labels:
              - namespace
              - app
              - container
              - host
              - pod
              - vm
      # If this entry is in an openshift- namespace, we don't pack the namespace (it remains a real label):
      - match:
          selector: '{namespace=~"openshift-addon-operator|openshift-apiserver|openshift-apiserver-operator|openshift-authentication|openshift-authentication-operator|openshift-cloud-controller-manager|openshift-cloud-controller-manager-operator|openshift-cloud-credential-operator|openshift-cloud-ingress-operator|openshift-cloud-network-config-controller|openshift-cluster-csi-drivers|openshift-cluster-machine-approver|openshift-cluster-node-tuning-operator|openshift-cluster-samples-operator|openshift-cluster-storage-operator|openshift-cluster-version|openshift-config|openshift-config-managed|openshift-config-operator|openshift-console|openshift-console-operator|openshift-console-user-settings|openshift-controller-manager|openshift-controller-manager-operator|openshift-custom-domains-operator|openshift-dns|openshift-dns-operator|openshift-etcd|openshift-etcd-operator|openshift-host-network|openshift-image-registry|openshift-infra|openshift-ingress|openshift-ingress-canary|openshift-ingress-operator|openshift-insights|openshift-kni-infra|openshift-kube-apiserver|openshift-kube-apiserver-operator|openshift-kube-controller-manager|openshift-kube-controller-manager-operator|openshift-kube-scheduler|openshift-kube-scheduler-operator|openshift-kube-storage-version-migrator|openshift-kube-storage-version-migrator-operator|openshift-logging|openshift-machine-api|openshift-machine-config-operator|openshift-managed-node-metadata-operator|openshift-managed-upgrade-operator|openshift-marketplace|openshift-monitoring|openshift-multus|openshift-network-diagnostics|openshift-network-operator|openshift-node|openshift-nutanix-infra|openshift-oauth-apiserver|openshift-observability-operator|openshift-ocm-agent-operator|openshift-openstack-infra|openshift-operator-lifecycle-manager|openshift-operators|openshift-operators-redhat|openshift-osd-metrics|openshift-ovirt-infra|openshift-priv|openshift-rbac-permissions|openshift-route-controller-manager|openshift-route-monitor-operator|openshift-sdn|openshift-security|openshift-service-ca|openshift-service-ca-operator|openshift-service-catalog-removed|openshift-user-workload-monitoring|openshift-validation-webhook|openshift-vsphere-infra"}'
          stages:
          - pack:
              labels:
              - app
              - container
              - host
              - pod
              - vm
      - labelallow:
          - invoker
          - namespace
          - type
      relabel_configs:
      # drop all entries for pods with no UID, unclear what this would be as static pods seem to have a uid now, but we're keeping the config because it's working so far:
      - action: drop
        regex:  ^$
        source_labels:
        - __meta_kubernetes_pod_uid
      - source_labels:
        - __meta_kubernetes_pod_label_name
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_label_app
        target_label: app
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: host
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: pod
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_container_name
        target_label: container
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_label_vm_kubevirt_io_name
        target_label: vm
      - replacement: /var/log/pods/*\$1/*.log
        separator: /
        source_labels:
        - __meta_kubernetes_pod_uid
        - __meta_kubernetes_pod_container_name
        target_label: __path__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
    - job_name: kubernetes-pods-static
      kubernetes_sd_configs:
      - role: pod
      pipeline_stages:
      - cri: {}
      - static_labels:
          type: static-pod
      # For anything that is outside an openshift- namespace, we will pack it into the entry to
      # dramatically improve cardinality. These would typically be temporary namespaces with random
      # names created by e2e tests. We still keep their logs, you just don't get a fast label filter
      # to find them globally by namespace.
      #
      # We had to resort to a fixed list here because there are a lot of openshift-RAND namespaces created.
      # (must-gather, debug, amq, test, etc) If you want your namespaces to get it's own indexed namespace
      # label, add it here, in alphabetical order, and to the near identical line below with =~ instead of !~.
      - match:
          selector: '{namespace!~"openshift-addon-operator|openshift-apiserver|openshift-apiserver-operator|openshift-authentication|openshift-authentication-operator|openshift-cloud-controller-manager|openshift-cloud-controller-manager-operator|openshift-cloud-credential-operator|openshift-cloud-ingress-operator|openshift-cloud-network-config-controller|openshift-cluster-csi-drivers|openshift-cluster-machine-approver|openshift-cluster-node-tuning-operator|openshift-cluster-samples-operator|openshift-cluster-storage-operator|openshift-cluster-version|openshift-config|openshift-config-managed|openshift-config-operator|openshift-console|openshift-console-operator|openshift-console-user-settings|openshift-controller-manager|openshift-controller-manager-operator|openshift-custom-domains-operator|openshift-dns|openshift-dns-operator|openshift-etcd|openshift-etcd-operator|openshift-host-network|openshift-image-registry|openshift-infra|openshift-ingress|openshift-ingress-canary|openshift-ingress-operator|openshift-insights|openshift-kni-infra|openshift-kube-apiserver|openshift-kube-apiserver-operator|openshift-kube-controller-manager|openshift-kube-controller-manager-operator|openshift-kube-scheduler|openshift-kube-scheduler-operator|openshift-kube-storage-version-migrator|openshift-kube-storage-version-migrator-operator|openshift-logging|openshift-machine-api|openshift-machine-config-operator|openshift-managed-node-metadata-operator|openshift-managed-upgrade-operator|openshift-marketplace|openshift-monitoring|openshift-multus|openshift-network-diagnostics|openshift-network-operator|openshift-node|openshift-nutanix-infra|openshift-oauth-apiserver|openshift-observability-operator|openshift-ocm-agent-operator|openshift-openstack-infra|openshift-operator-lifecycle-manager|openshift-operators|openshift-operators-redhat|openshift-osd-metrics|openshift-ovirt-infra|openshift-priv|openshift-rbac-permissions|openshift-route-controller-manager|openshift-route-monitor-operator|openshift-sdn|openshift-security|openshift-service-ca|openshift-service-ca-operator|openshift-service-catalog-removed|openshift-user-workload-monitoring|openshift-validation-webhook|openshift-vsphere-infra"}'
          stages:
          - pack:
              labels:
              - namespace
              - app
              - container
              - host
              - pod
              - vm
      # If this entry is in an openshift- namespace, we don't pack the namespace (it remains a real label):
      - match:
          selector: '{namespace=~"openshift-addon-operator|openshift-apiserver|openshift-apiserver-operator|openshift-authentication|openshift-authentication-operator|openshift-cloud-controller-manager|openshift-cloud-controller-manager-operator|openshift-cloud-credential-operator|openshift-cloud-ingress-operator|openshift-cloud-network-config-controller|openshift-cluster-csi-drivers|openshift-cluster-machine-approver|openshift-cluster-node-tuning-operator|openshift-cluster-samples-operator|openshift-cluster-storage-operator|openshift-cluster-version|openshift-config|openshift-config-managed|openshift-config-operator|openshift-console|openshift-console-operator|openshift-console-user-settings|openshift-controller-manager|openshift-controller-manager-operator|openshift-custom-domains-operator|openshift-dns|openshift-dns-operator|openshift-etcd|openshift-etcd-operator|openshift-host-network|openshift-image-registry|openshift-infra|openshift-ingress|openshift-ingress-canary|openshift-ingress-operator|openshift-insights|openshift-kni-infra|openshift-kube-apiserver|openshift-kube-apiserver-operator|openshift-kube-controller-manager|openshift-kube-controller-manager-operator|openshift-kube-scheduler|openshift-kube-scheduler-operator|openshift-kube-storage-version-migrator|openshift-kube-storage-version-migrator-operator|openshift-logging|openshift-machine-api|openshift-machine-config-operator|openshift-managed-node-metadata-operator|openshift-managed-upgrade-operator|openshift-marketplace|openshift-monitoring|openshift-multus|openshift-network-diagnostics|openshift-network-operator|openshift-node|openshift-nutanix-infra|openshift-oauth-apiserver|openshift-observability-operator|openshift-ocm-agent-operator|openshift-openstack-infra|openshift-operator-lifecycle-manager|openshift-operators|openshift-operators-redhat|openshift-osd-metrics|openshift-ovirt-infra|openshift-priv|openshift-rbac-permissions|openshift-route-controller-manager|openshift-route-monitor-operator|openshift-sdn|openshift-security|openshift-service-ca|openshift-service-ca-operator|openshift-service-catalog-removed|openshift-user-workload-monitoring|openshift-validation-webhook|openshift-vsphere-infra"}'
          stages:
          - pack:
              labels:
              - app
              - container
              - host
              - pod
              - vm
      - labelallow:
          - invoker
          - namespace
          - type
      relabel_configs:
      # drop all entries from regular (non-static) pods, these will not have the config mirror annotation
      - action: drop
        regex: ^$
        source_labels:
        - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
      - source_labels:
        - __meta_kubernetes_pod_label_name
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_label_app
        target_label: app
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: host
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: pod
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_container_name
        target_label: container
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_label_vm_kubevirt_io_name
        target_label: vm
      # this is the critical config for static pods which use a slightly different path on disk for their logs:
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
      - match:
          # To get labels for a new systemd_unit exclude it by adding it in the selector here and include
          # it by adding it in the selector below.  For any systemd_units, besides these, we will pack
          # (i.e., no label) to avoid high cardinality.
          selector: '{systemd_unit!~"auditd.service|crio.service|kubelet.service|NetworkManager.service|ovs-vswitchd.service|ovs-configuration.service|ovsdb-server.service"}'
          stages:
          - pack:
              labels:
              - boot_id
              - systemd_unit
              - host
      - match:
          # These systemd_units will get a systemd_unit label; if you add one, be sure to monitor number of
          # Active Streams in Loki Dashboard to avoid over burdening our instance of Promtail/Loki.
          selector: '{systemd_unit=~"auditd.service|crio.service|kubelet.service|NetworkManager.service|ovs-vswitchd.service|ovs-configuration.service|ovsdb-server.service"}'
          stages:
          - pack:
              labels:
              - boot_id
              - host
      - labelallow:
          - invoker
          - systemd_unit
      - static_labels:
          type: journal
      relabel_configs:
      - action: labelmap
        regex: __journal__(.+)
      - source_labels:
        - __journal__hostname
        target_label: host
    server:
      http_listen_port: 3101
      log_level: warn
    target_config:
      sync_period: 10s
EOF

cat >> "${SHARED_DIR}/manifest_creds.yml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: promtail-prod-creds
  namespace: openshift-e2e-loki
data:
  client-id: "$(cat /var/run/loki-secret/client-id | base64 -w 0)"
  client-secret: "$(cat /var/run/loki-secret/client-secret | base64 -w 0)"
  audience: "$(cat /var/run/loki-secret/audience | base64 -w 0)"
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
      annotations:
        openshift.io/required-scc: privileged
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers:
      - command:
        - promtail
        - -client.external-labels=invoker=\$(INVOKER)
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
        terminationMessagePolicy: FallbackToLogsOnError
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
        - mountPath: "/var/log/journal"
          name: journal
          readOnly: true
        - mountPath: "/tmp/shared"
          name: shared-data
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
        terminationMessagePolicy: FallbackToLogsOnError
        volumeMounts:
        - mountPath: /etc/tls/private
          name: proxy-tls
        - mountPath: /etc/tls/cookie-secret
          name: cookie-secret
      - name: prod-bearer-token
        resources:
          requests:
            cpu: 10m
            memory: 20Mi
        args:
        - --oidc.audience=\$(AUDIENCE)
        - --oidc.client-id=\$(CLIENT_ID)
        - --oidc.client-secret=\$(CLIENT_SECRET)
        - --oidc.issuer-url=https://sso.redhat.com/auth/realms/redhat-external
        - --margin=10m
        - --file=/tmp/shared/prod_bearer_token
        terminationMessagePolicy: FallbackToLogsOnError
        env:
          - name: CLIENT_ID
            valueFrom:
              secretKeyRef:
                name: promtail-prod-creds
                key: client-id
          - name: CLIENT_SECRET
            valueFrom:
              secretKeyRef:
                name: promtail-prod-creds
                key: client-secret
          - name: AUDIENCE
            valueFrom:
              secretKeyRef:
                name: promtail-prod-creds
                key: audience
$PROXYLINE
        volumeMounts:
        - mountPath: "/tmp/shared"
          name: shared-data
        image: quay.io/observatorium/token-refresher
      serviceAccountName: loki-promtail
      terminationGracePeriodSeconds: 180
      tolerations:
      - operator: Exists
      priorityClassName: system-cluster-critical
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
      - name: proxy-tls
        secret:
          defaultMode: 420
          secretName: proxy-tls
      - name: cookie-secret
        secret:
          defaultMode: 420
          secretName: cookie-secret
      - name: shared-data
        emptyDir: {}
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
      annotations:
        openshift.io/required-scc: restricted-v2
    spec:
      priorityClassName: system-cluster-critical
      serviceAccountName: event-exporter
      tolerations:
      - operator: Exists
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
          terminationMessagePolicy: FallbackToLogsOnError
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
  # Try to prepopulate the loki time window to match the job (with some leeway), so the user is never staring at no logs when they're actually there.
  # Note that this step runs prior to install, so we use a window 2 hours before now (to be ridiculously safe) and 8 hours after, which should cover
  # the runtime of just about any job. There's no risk over overloading the UI or seeing logs you don't want because we filter by invoker (this job).
  LOKI_EPOCH_MILLIS_FROM="$(date -d '-2 hours' +%s%N | cut -b1-13)"
  LOKI_EPOCH_MILLIS_TO="$(date -d '+8 hours' +%s%N | cut -b1-13)"

  ENCODED_INVOKER="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${OPENSHIFT_INSTALL_INVOKER}'))")"
  cat >> ${SHARED_DIR}/custom-links.txt << EOF
  <a target="_blank" href="https://grafana-loki.ci.openshift.org/explore?orgId=1&left=%7B%22datasource%22:%22PCEB727DF2F34084E%22,%22queries%22:%5B%7B%22expr%22:%22%7Binvoker%3D%5C%22${ENCODED_INVOKER}%5C%22%7D%20%22,%22refId%22:%22A%22,%22editorMode%22:%22code%22,%22queryType%22:%22range%22%7D%5D,%22range%22:%7B%22from%22:%22${LOKI_EPOCH_MILLIS_FROM}%22,%22to%22:%22${LOKI_EPOCH_MILLIS_TO}%22%7D%7D" title="Loki is a log aggregation system for examining CI logs. This is most useful with upgrades, which do not contain pre-upgrade logs in the must-gather.">Loki</a>&nbsp;<a target="_blank" href="https://gist.github.com/vrutkovs/ef7cc9bca50f5f49d7eab831e3f082d8" title="Cheat sheet for Loki search queries">Loki cheat sheet</a>
EOF
fi
