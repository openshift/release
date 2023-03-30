#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
set -x

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}-${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID=$(<"${CLUSTER_PROFILE_DIR}/openshift_gcp_project")
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE=$(<"${SHARED_DIR}/openshift_gcp_compute_zone")
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

cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/pull-secret

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

cat <<'EOF' >"${HOME}"/deploy.sh
#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
set -x

mkdir -p ~/.kube
sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig > ~/.kube/config

echo '
kind: Pod
apiVersion: v1
metadata:
  name: hello-microshift
  labels:
    app: hello-microshift
spec:
  containers:
  - name: hello-microshift
    image: busybox:1.35
    command: ["/bin/sh"]
    args: ["-c", "while true; do echo -ne \"HTTP/1.0 200 OK\r\nContent-Length: 16\r\n\r\nHello MicroShift\" | nc -l -p 8080 ; done"]
    ports:
    - containerPort: 8080
      protocol: TCP
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      runAsNonRoot: true
      runAsUser: 1001
      runAsGroup: 1001
      seccompProfile:
        type: RuntimeDefault' | oc create -f -

oc expose pod hello-microshift
oc expose svc hello-microshift --hostname hello-microshift.cluster.local

oc wait pods -l app=hello-microshift --for condition=Ready --timeout=300s
EOF

chmod +x "${HOME}/deploy.sh"

gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}/deploy.sh" "rhel8user@${INSTANCE_PREFIX}:~/deploy.sh"

set +e
gcloud compute ssh \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  "rhel8user@${INSTANCE_PREFIX}" \
  --command "bash ~/deploy.sh"

IP=$(gcloud compute instances describe "${INSTANCE_PREFIX}" --format='value(networkInterfaces.accessConfigs[0].natIP)')

set +x
retries=3
backoff=3s
for try in $(seq 1 "${retries}"); do
  echo "Attempt: ${try}"
  echo "Running: curl -vk http://hello-microshift.cluster.local --resolve \"hello-microshift.cluster.local:80:${IP}\""
  RESPONSE=$(curl -vk http://hello-microshift.cluster.local --resolve "hello-microshift.cluster.local:80:${IP}" 2>&1)
  RESULT=$?
  echo "Exit code: ${RESULT}"
  echo -e "Response: \n${RESPONSE}\n\n"
  if [ $RESULT -eq 0 ] && echo "${RESPONSE}" | grep -q -E "HTTP.*200 OK"; then
    echo "Request fulfilled conditions to be successful (exit code = 0, response contains 'HTTP.*200 OK')"
    exit 0
  fi
  echo -e "Waiting ${backoff} before next retry\n\n"
  sleep "${backoff}"
done
set -x

gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /tmp/validate-microshift "rhel8user@${INSTANCE_PREFIX}:~/validate-microshift"

gcloud compute ssh \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  "rhel8user@${INSTANCE_PREFIX}" \
  --command "bash ~/validate-microshift/cluster-debug-info.sh"

exit 1
