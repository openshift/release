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

cat > "${HOME}"/microshift-service <<EOF
[Unit]
Description=Microshift
[Service]
WorkingDirectory=/usr/local/bin/
ExecStart=microshift run
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

# smoke-tests script to scp to gcp instance
# TODO: edit this file to launch microshift and run tests
cat  > "${HOME}"/run-smoke-tests.sh << 'EOF'
#!/bin/bash
set -euo pipefail

systemctl disable --now firewalld

export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig

# Tests execution
echo '### Running microshift smoke-tests'

echo '### Start /usr/bin/microshift run and run commands to perform smoke-tests'
systemctl enable --now microshift.service
start=$(date '+%s')
to=120
until oc get nodes; do
  echo "waiting for node response"
  sleep 10
  if [ $(( $(date '+%s') - start )) -ge $to ]; then
    exit 1
  fi
done

LABELS=(
'dns.operator.openshift.io/daemonset-dns=default'
'app=flannel'
'ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default'
'app=service-ca'
'k8s-app=kubevirt-hostpath-provisioner'
)

to=300
for l in "${LABELS[@]}"; do
  echo "waiting on pods with label $l"
  start=$(date '+%s')
  while :; do
    containersReady="$(oc get pods -A -l $l -o jsonpath='{.items[*].status.conditions}' | \
        jq -r '.[] | select(.type == "ContainersReady") | .status')"
    if [ "$containersReady" = "True" ]; then
    echo "Pod (label: $l), all containers running"
      break
    elif [ $(( $(date '+%s') - start )) -ge $to ]; then
      echo "timed out waiting for pod, label: $l"
      podNamespaceName="$(oc get pod -A -l $l --no-headers -o custom-columns="NS:.metadata.namespace,NAME:.metadata.name")"
      if [ "$l" = "dns" ]; then
        container="-c dns"
      fi
      oc logs -f -n $podNamespaceName  "$l" || true
      journalctl -u microshift
      exit 1
    fi
    echo "retrying pod, label $l"
    sleep 3
  done
done
echo "All pod containers are Ready"
EOF
chmod +x "${HOME}"/run-smoke-tests.sh

set -x

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo dnf install subscription-manager -y'
  
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command "sudo subscription-manager register \
  --password=$(cat /var/run/rhsm/subscription-manager-passwd ) \
  --username=$(cat /var/run/rhsm/subscription-manager-user)"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo dnf install jq -y'

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo setenforce 0'

# scp and install microshift.service
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/microshift-service rhel8user@"${INSTANCE_PREFIX}":~/microshift-service

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo mv microshift-service /usr/lib/systemd/system/microshift.service'

# scp and install microshift binary
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /usr/bin/microshift rhel8user@"${INSTANCE_PREFIX}":~/microshift

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo mv microshift /usr/local/bin/microshift'

# scp and install oc binary
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /usr/bin/oc rhel8user@"${INSTANCE_PREFIX}":~/oc

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo mv oc /usr/bin/oc'

# scp and run install.sh
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /usr/bin/install.sh rhel8user@"${INSTANCE_PREFIX}":~/install.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo HOSTNAME=$(hostname -A) CONFIG_ENV_ONLY=true ./install.sh'

# scp smoke test script and pull secret
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/run-smoke-tests.sh rhel8user@"${INSTANCE_PREFIX}":~/run-smoke-tests.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/pull-secret rhel8user@"${INSTANCE_PREFIX}":~/pull-secret

# start the test
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo ./run-smoke-tests.sh'
