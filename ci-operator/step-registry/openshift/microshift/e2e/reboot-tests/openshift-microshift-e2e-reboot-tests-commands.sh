#!/bin/bash

set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID="$(<${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(<${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

mkdir -p "${HOME}"/.ssh

# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub
echo 'ServerAliveInterval 30' | tee -a "${HOME}"/.ssh/config
echo 'ServerAliveCountMax 1200' | tee -a "${HOME}"/.ssh/config
chmod 0600 "${HOME}"/.ssh/config

# Copy pull secret to user home
cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/pull-secret

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

cat >"${HOME}"/reboot-test.sh <<'EOF'
#!/bin/bash
set -xeuo pipefail

export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig
# TODO: Remove the labels again once https://issues.redhat.com/browse/OCPBUGS-1969 has been fixed upstream
oc label namespaces default "pod-security.kubernetes.io/"{enforce,audit,warn}"-version=v1.24"
oc label namespaces default "pod-security.kubernetes.io/"{enforce,audit,warn}"=privileged"
cat <<EOF_INNER | oc create -f -
---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  namespace: default
  name: test-claim
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: topolvm-provisioner
  resources:
    requests:
      storage: 1Gi
---
kind: Pod
apiVersion: v1
metadata:
  name: test-pod
  namespace: default
spec:
  securityContext:
    runAsNonRoot: true
    privileged: false
    capabilities:
      drop:
      - 'ALL'
    allowPrivilegeEscalation: false
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: test-container
      image: nginx
      command:
        - sh
        - -c
        - sleep 1d
      volumeMounts:
        - mountPath: /vol
          name: test-vol
  volumes:
    - name: test-vol
      persistentVolumeClaim:
        claimName: test-claim
EOF_INNER

set +ex
echo "waiting for pod condition" >&2
oc wait --for=condition=Ready --timeout=120s pod/test-pod
echo "pod posted ready status" >&2

EOF
chmod +x "${HOME}"/reboot-test.sh

gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/reboot-test.sh rhel8user@"${INSTANCE_PREFIX}":~/reboot-test.sh

gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /tmp/validate-microshift rhel8user@"${INSTANCE_PREFIX}":~/validate-microshift

if ! gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo ~/reboot-test.sh'; then

  gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
    --zone "${GOOGLE_COMPUTE_ZONE}" \
    rhel8user@"${INSTANCE_PREFIX}" \
    --command 'chmod +x ~/validate-microshift/cluster-debug-info.sh && sudo ~/validate-microshift/cluster-debug-info.sh'
  exit 1
fi

# now reboot the machine
gcloud compute instances stop "${INSTANCE_PREFIX}" --zone "${GOOGLE_COMPUTE_ZONE}"
