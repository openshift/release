#!/bin/bash

set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

mkdir -p "${HOME}"/.ssh

mock-nss.sh

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

cat > "${HOME}"/reboot-test.sh <<'EOF'
#!/bin/bash
set -xeuo pipefail

export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig
# TODO: Remove the labels again once https://issues.redhat.com/browse/OCPBUGS-1969 has been fixed upstream
oc label namespaces default "pod-security.kubernetes.io/"{enforce,audit,warn}"-version=v1.24"
oc label namespaces default "pod-security.kubernetes.io/"{enforce,audit,warn}"=privileged"
oc create deployment -n default nginx --image=nginx

set +ex
echo "waiting for deployment response" >&2
oc wait --for=condition=available --timeout=120s deployment nginx
echo "deployment posted ready status" >&2

EOF
chmod +x "${HOME}"/reboot-test.sh

cat > "${HOME}"/debug-info.sh <<'EOF'
#!/bin/bash

declare -a commands_to_run=()
function to_run() {
    cmd="$@"
    commands_to_run+=("${cmd}")
}

export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig

to_run oc get cm -n kube-public microshift-version -o=jsonpath='{.data}'
to_run microshift version
to_run microshift version -o yaml
to_run oc version
to_run sudo crictl version
to_run uname -a
to_run cat /etc/*-release

RESOURCES=(nodes configmaps deployments daemonsets statefulsets services routes replicasets persistentvolumeclaims persistentvolumes storageclasses endpoints endpointslices csidrivers csinodes)
for resource in ${RESOURCES[*]}; do
    to_run oc get "${resource}" -A
    to_run oc get "${resource}" -A -o yaml
done

to_run oc get events -A --sort-by=.metadata.creationTimestamp

TO_DESCRIBE=(deployments daemonsets statefulsets replicasets)
for ns in $(kubectl get namespace -o jsonpath='{.items..metadata.name}'); do
    oc get namespace $ns -o yaml

    for resource_type in ${TO_DESCRIBE[*]}; do
        for resource in $(kubectl get $resource_type -n $ns -o name); do
            to_run oc describe -n $ns $resource
        done
    done

    for pod in $(kubectl get pods -n $ns -o name); do
            to_run oc describe -n $ns $pod
            to_run oc get -n $ns $pod -o yaml
            for container in $(kubectl get -n $ns $pod -o jsonpath='{.spec.containers[*].name}'); do
                to_run oc logs -n $ns $pod $container
                to_run oc logs --previous=true -n $ns $pod $container
            done
    done
done

to_run nmcli
to_run ip a
to_run ip route
to_run sudo crictl images --digests
to_run sudo crictl ps
to_run sudo crictl pods
to_run ls -lah /etc/cni/net.d/
to_run find /etc/cni/net.d/ -type f -exec echo {} \; -exec sudo cat {} \; -exec echo \;
to_run dnf list --installed
to_run dnf history
to_run sudo systemctl -a -l
to_run sudo journalctl -xu microshift
to_run sudo journalctl -xu microshift-etcd

echo -e "\n=== DEBUG INFORMATION ===\n"
echo "Following commands will be executed:"
for cmd in "${commands_to_run[@]}"; do
    echo "    - ${cmd}"
done

for cmd in "${commands_to_run[@]}"; do
    echo -e "\n\n$ ${cmd}"
    ${cmd} 2>&1 || true
done
EOF
chmod +x "${HOME}"/debug-info.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/reboot-test.sh rhel8user@"${INSTANCE_PREFIX}":~/reboot-test.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/debug-info.sh rhel8user@"${INSTANCE_PREFIX}":~/debug-info.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo ~/reboot-test.sh ; res=$?; sudo ~/debug-info.sh; exit $res'

# now reboot the machine
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute instances stop "${INSTANCE_PREFIX}" --zone "${GOOGLE_COMPUTE_ZONE}"
