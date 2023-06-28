#!/bin/bash

set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${UNIQUE_HASH}"
GOOGLE_PROJECT_ID="$(<${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(<${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

IP_ADDRESS="$(gcloud compute instances describe ${INSTANCE_PREFIX} --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"

mkdir -p "${HOME}"/.ssh
cat << EOF > "${HOME}"/.ssh/config
Host ${INSTANCE_PREFIX}
  User rhel8user
  HostName ${IP_ADDRESS}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}"/.ssh/config

cat >"${HOME}"/reboot-test.sh <<'EOF'
#!/bin/bash
set -xeuo pipefail
export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig
# TODO: Remove the labels again once https://issues.redhat.com/browse/OCPBUGS-1969 has been fixed upstream
oc label namespaces default "pod-security.kubernetes.io/"{enforce,audit,warn}"-version=v1.24"
oc label namespaces default "pod-security.kubernetes.io/"{enforce,audit,warn}"=privileged"
cat <<EOF_INNER | oc create -f -
# TODO: Fix 4.12 lvmd's "spare-gb"
# ---
# kind: PersistentVolumeClaim
# apiVersion: v1
# metadata:
#   namespace: default
#   name: test-claim
# spec:
#   accessModes:
#   - ReadWriteOnce
#   storageClassName: topolvm-provisioner
#   resources:
#     requests:
#       storage: 1Gi
# ---
kind: Pod
apiVersion: v1
metadata:
  name: test-pod
  namespace: default
spec:
  securityContext:
    runAsNonRoot: true
    privileged: false
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: test-container
      securityContext:
        runAsUser: 1001
        runAsGroup: 1001
        runAsNonRoot: true
        privileged: false
        capabilities:
          drop:
          - 'ALL'
        allowPrivilegeEscalation: false
        seccompProfile:
          type: RuntimeDefault
      image: nginx
      command:
        - sh
        - -c
        - sleep 1d
  #     volumeMounts:
  #       - mountPath: /vol
  #         name: test-vol
  # volumes:
  # - name: test-vol
  #   persistentVolumeClaim:
  #     claimName: test-claim
EOF_INNER

oc wait --for=condition=Ready --timeout=120s pod/test-pod
EOF
chmod +x "${HOME}"/reboot-test.sh

scp "${HOME}"/reboot-test.sh "${INSTANCE_PREFIX}":~/reboot-test.sh

if ! ssh "${INSTANCE_PREFIX}" 'sudo ~/reboot-test.sh'; then
  scp /microshift/validate-microshift/cluster-debug-info.sh "${INSTANCE_PREFIX}":~
  ssh "${INSTANCE_PREFIX}" 'export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig; sudo -E ~/cluster-debug-info.sh'
  exit 1
fi

set +e
ssh "${INSTANCE_PREFIX}" 'sudo reboot now'
res=$?
set -e

# Don't fail on exit code 255 which is ssh's for things like
# "connection closed by remote host"
# which are expected when rebooting via ssh
if [ "${res}" -ne 0 ] && [ "${res}" -ne 255 ]; then
    exit 1
fi
