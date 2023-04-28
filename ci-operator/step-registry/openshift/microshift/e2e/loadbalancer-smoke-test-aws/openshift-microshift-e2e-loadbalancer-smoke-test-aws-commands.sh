#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
set -x

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
HOST_USER="$(cat ${SHARED_DIR}/ssh_user)"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  User ${HOST_USER}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

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

oc create service loadbalancer hello-microshift --tcp=5678:8080

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
  echo "Running: curl -vk ${IP_ADDRESS}:5678"
  RESPONSE=$(curl -I ${IP_ADDRESS}:5678 2>&1)
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

scp /microshift/validate-microshift/cluster-debug-info.sh "${INSTANCE_PREFIX}":~
ssh "${INSTANCE_PREFIX}" 'export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig; sudo -E ~/cluster-debug-info.sh'
exit 1
