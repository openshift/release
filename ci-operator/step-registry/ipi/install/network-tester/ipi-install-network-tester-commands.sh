#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


cat > "${SHARED_DIR}/manifest_01_ns.yml" << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-e2e-network-tester
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
EOF

cat > "${SHARED_DIR}/manifest_ds.yml" << EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: network-tester
  namespace: openshift-e2e-network-tester
spec:
  selector:
    matchLabels:
      app.kubernetes.io/component: network-tester
      app.kubernetes.io/instance: network-tester
      app.kubernetes.io/name: network-tester
  template:
    metadata:
      labels:
        app.kubernetes.io/component: network-tester
        app.kubernetes.io/instance: network-tester
        app.kubernetes.io/name: network-tester
      annotations:
        openshift.io/scc: privileged
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      volumes:
      - hostPath:
          path: /
          type: Directory
        name: host
      serviceAccount: default
      serviceAccountName: default
      hostNetwork: true
      hostPID: true
      hostIPC: true
      priority: 1000000000
      priorityClassName: openshift-user-critical
      containers:
      - name: network-tester
        command:
        - /bin/bash
        - -c
        - |
          #!/bin/bash
          while true
          do
              set -euo pipefail
              echo "Hello world!"
              time
              echo "Running conntrack -L"
              chroot /host /usr/sbin/conntrack -L
              echo "Running: ss -tpn"
              chroot /host /usr/sbin/ss -tpn
              echo "Running: iptables-save -c"
              chroot /host /usr/sbin/iptables-save -c
              echo "Running: ovs-ofctl show br-ex"
              chroot /host /usr/sbin/ovs-ofctl show br-ex
              echo "Running: ovs-ofctl show br-int"
              chroot /host /usr/sbin/ovs-ofctl show br-int
              echo "Running: ovs-ofctl dump-flows br-ex"
              chroot /host /usr/sbin/ovs-ofctl dump-flows br-ex
              echo "Running: ovs-ofctl dump-flows br-int"
              chroot /host /usr/sbin/ovs-ofctl dump-flows br-int
              #ovn-sbctl list Logical_Flow # disabled for now, will need SBDB address and SSL certs to access
              echo "Running: ovs-ofctl dump-groups br-int"
              chroot /host /usr/sbin/ovs-ofctl dump-groups br-int
              echo "Running: ovs-ofctl dump-flows br-int"
              chroot /host /usr/sbin/ovs-ofctl dump-flows br-int
              echo "Running: ovs-vsctl list interface"
              chroot /host /usr/sbin/ovs-vsctl list interface
              sleep 60
          done
        image: registry.access.redhat.com/ubi8/ubi-minimal
        imagePullPolicy: IfNotPresent
        resources:
          requests:
            cpu: 10m
            memory: 20Mi
        securityContext:
          privileged: true
          readOnlyRootFilesystem: true
          runAsGroup: 0
          runAsUser: 0
        volumeMounts:
        - mountPath: /host
          name: host
      tolerations:
      - effect: NoExecute
        key: node.kubernetes.io/not-ready
        operator: Exists
        tolerationSeconds: 300
      - effect: NoExecute
        key: node.kubernetes.io/unreachable
        operator: Exists
        tolerationSeconds: 300
EOF


echo "Network tester manifests created"

