#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
set -x

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
GOOGLE_PROJECT_ID=$(<"${CLUSTER_PROFILE_DIR}/openshift_gcp_project")
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE=$(<"${SHARED_DIR}/openshift_gcp_compute_zone")
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
EOF
chmod 0600 "${HOME}"/.ssh/config

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

scp "${HOME}/deploy.sh" "${INSTANCE_PREFIX}:~/deploy.sh"

set +e
ssh "${INSTANCE_PREFIX}" "bash ~/deploy.sh"

set +x
retries=3
backoff=3s
for try in $(seq 1 "${retries}"); do
  echo "Attempt: ${try}"
  echo "Running: curl -vk http://hello-microshift.cluster.local --connect-to \"hello-microshift.cluster.local:80:${IP_ADDRESS}:80\""
  RESPONSE=$(curl -vk http://hello-microshift.cluster.local --connect-to "hello-microshift.cluster.local:80:${IP_ADDRESS}:80" 2>&1)
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

scp /microshift/validate-microshift/cluster-debug-info.sh "${INSTANCE_PREFIX}":~
ssh "${INSTANCE_PREFIX}" 'export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig; sudo -E ~/cluster-debug-info.sh'
exit 1
