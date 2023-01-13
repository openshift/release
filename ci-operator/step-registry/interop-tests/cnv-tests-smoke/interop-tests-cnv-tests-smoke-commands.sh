#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CNV_TESTS_NAMESPACE=cnv-qe-infra
CNV_TESTS_IMAGE_TAG="${CNV_TESTS_IMAGE_TAG:-4.11}"

CLUSTER_NAME=$(cat ${SHARED_DIR}/CLUSTER_NAME)
BASE_DOMAIN="${BASE_DOMAIN:-release-ci.cnv-qe.rhood.us}"

# set credentials:
cp -L $KUBECONFIG /tmp/kubeconfig

# Create testing namespace
oc create -f- << EOF
---
kind: Namespace
apiVersion: v1
metadata:
  name: $CNV_TESTS_NAMESPACE
EOF

# Prepare config maps
# SSH Key
oc create configmap -n "${CNV_TESTS_NAMESPACE}" \
    cnv-tests-ssh-key \
    --from-file="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
# Cluster auth
oc create configmap -n "${CNV_TESTS_NAMESPACE}" \
    cnv-tests-cluster-auth \
    --from-file="/tmp/kubeconfig" \

# Create info about cluster
oc create -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-info
  namespace: ${CNV_TESTS_NAMESPACE}
data:
  CLUSTER_NAME: ${CLUSTER_NAME}
  CLUSTER_DOMAIN: ${BASE_DOMAIN}
EOF

# Create POD with tests
oc create -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cnv-tests
  labels:
    app: cnv-tests
  namespace: $CNV_TESTS_NAMESPACE
spec:
  nodeSelector:
    node-role.kubernetes.io/master: ''
  tolerations:
    - key: "node-role.kubernetes.io/master"
      operator: "Exists"
      effect: "NoSchedule"
  containers:
    - name: test-runner
      image: quay.io/openshift-cnv/cnv-tests:${CNV_TESTS_IMAGE_TAG}
      env:
        - name: HOST_SSH_KEY
          value: /data/ssh/ssh-privatekey
        - name: KUBECONFIG
          value: /data/auth/kubeconfig
        - name: PIPENV_HIDE_EMOJIS
          value: "true"
        - name: PIPENV_NOSPIN
          value: "true"
        - name: OPENSHIFT_PYTHON_WRAPPER_LOG_FILE
          value: "/data/results/ocp-wrapper.log"
      command:
        - "pipenv"
        - "run"
        - "pytest"
        - "--junitxml=/data/results/xunit_results.xml"
        - "--pytest-log-file=/data/results/pytest-tests.log"
        - "--tc-file=tests/global_config.py"
        - "--storage-class-matrix=ocs-storagecluster-ceph-rbd"
        - "--tc"
        - "default_storage_class:ocs-storagecluster-ceph-rbd"
        - "--latest-rhel"
        - "--tb=native"
        - "-o"
        - "log_cli=true"
        - "-m"
        - "smoke"
      volumeMounts:
        - name: cnv-tests-ssh-key
          mountPath: /data/ssh/
        - name: cnv-tests-binaries
          mountPath: /mnt/host   # The cnv-tests container exports this into the PATH
        - name: cnv-tests-cluster-auth
          mountPath: /data/auth/
        - name: cnv-tests-results
          mountPath: /data/results
      imagePullPolicy: Always
    - name: rsync-container
      image: busybox
      command:
        - "sh"
        - "-c"
        - "while true ; do echo ready ; sleep 30 ; done"
      volumeMounts:
        - name: cnv-tests-results
          mountPath: /data/results
  restartPolicy: Never
  initContainers:
    - name: download-binaries
      envFrom:
        - configMapRef:
            name: cluster-info
      image: quay.io/openshift-cnv/cnv-tests:${CNV_TESTS_IMAGE_TAG}
      command:
        - /bin/sh
        - -c
        - |
            set -ex
            cd /binaries

            curl -ksSL https://downloads-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/amd64/linux/oc.tar \
              | tar -xvf -
            ln -sf oc kubectl

            curl -ksSL $(oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged \
                --output=jsonpath='{range $.spec.links[*]}{$.href}{"\n"}{end}' \
                | grep -Fw linux
            ) | tar -xzvf -

      volumeMounts:
        - name: cnv-tests-binaries
          mountPath: "/binaries"
  securityContext:
    privileged: true
  volumes:
    - name: cnv-tests-ssh-key
      configMap:
        name: cnv-tests-ssh-key
    - name: cnv-tests-binaries
      emptyDir: {}  # Populated in initContainers
    - name: cnv-tests-cluster-auth
      configMap:
        name: cnv-tests-cluster-auth
    - name: cnv-tests-results
      emptyDir: {}
EOF

oc wait \
    --for=condition='Ready' \
    --timeout='10m' \
    -n ${CNV_TESTS_NAMESPACE} pod cnv-tests

# Stream test logs into the console
oc logs -n ${CNV_TESTS_NAMESPACE} -f cnv-tests -c test-runner --tail 50
while true
do
    if oc exec -n ${CNV_TESTS_NAMESPACE} cnv-tests -- pgrep -x "pytest" &> /dev/null;
    then
        oc logs -n ${CNV_TESTS_NAMESPACE} -f cnv-tests -c test-runner --tail 50
    else
        break
    fi
done
