#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
set -x

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}-${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID=$(< "${CLUSTER_PROFILE_DIR}/openshift_gcp_project")
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE=$(< "${SHARED_DIR}/openshift_gcp_compute_zone")
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

cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/pull-secret

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

gcloud compute firewall-rules update "${INSTANCE_PREFIX}" --allow tcp:22,icmp,tcp:5678

cat <<'EOF' > "${HOME}"/deploy.sh
#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
set -x

mkdir -p ~/.kube
sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig > ~/.kube/config

echo "
kind: Pod
apiVersion: v1
metadata:
  name: hello-microshift
  labels:
    app: hello-microshift
spec:
  containers: 
  - name: hello-microshift
    image: openshift/hello-openshift
    ports:
    - containerPort: 8080
      protocol: TCP
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      runAsNonRoot: true
      seccompProfile:
        type: RuntimeDefault" | oc create -f -

oc create service loadbalancer hello-microshift --tcp=5678:8080

oc wait pods -l app=hello-microshift --for condition=Ready --timeout=300s
EOF

chmod +x "${HOME}/deploy.sh"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}/deploy.sh" "rhel8user@${INSTANCE_PREFIX}:~/deploy.sh"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute ssh \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  "rhel8user@${INSTANCE_PREFIX}" \
  --command "bash ~/deploy.sh"


IP=$(LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute instances describe "${INSTANCE_PREFIX}" --format='value(networkInterfaces.accessConfigs[0].natIP)')

set +ex
retries=3
backoff=3s

for try in $(seq 1 "${retries}"); do
  echo "Attempt: ${try}"
  echo "Running: curl -vk ${IP}:5678"
  RESPONSE=$(curl -I ${IP}:5678 2>&1)
  RESULT=$?
  echo "Exit code: ${RESULT}"
  echo -e "Response: \n${RESPONSE}\n\n"
  if [ $RESULT -eq 0 ] && echo "${RESPONSE}" | grep -q -E "HTTP.*200"; then
    echo "Request fulfilled conditions to be successful (exit code = 0, response contains 'HTTP.*200')"
    exit 0
  fi
  echo -e "Waiting ${backoff} before next retry\n\n"
  sleep "${backoff}"
done

set -x

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /tmp/validate-microshift "rhel8user@${INSTANCE_PREFIX}:~/validate-microshift"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute ssh \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  "rhel8user@${INSTANCE_PREFIX}" \
  --command "bash ~/validate-microshift/cluster-debug-info.sh"

exit 1
