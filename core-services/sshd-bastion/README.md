# sshd-bastion

The `sshd-bastion` is an SSH server to be used as bastion host for access into
networks that otherwise are not accessible from the internet. The normal work-
flow is for a host from inside of a firewalled network to connect to the bastion
via SSH and set up a tunnel so that others connecting to the bastion can be
transparently proxied.

If adding a new bastion, create another subdirectory and duplicate the deployment,
ensuring that the appropriate secrets are present. Generate new host keys for the
bastion by following [the documentation](https://www.ssh.com/ssh/keygen/#sec-Creating-Host-Keys).

## Clients

Clients are expected to connect to this bastion by forwarding a port on the server
to their local machine using `oc port-forward`. RBAC to allow this as a service
account is included in the deployment YAMLs.

Determine the service account token with:

```terminal
$ oc serviceaccounts get-token port-forwarder --namespace "bastion-${environment}"
```

Connect to the remote bastion and create a reverse tunnel with:


```sh
#!/bin/bash

set -o nounset
set -o pipefail
set -o errexit

if [[ -z "${token:-}" ]]; then
	echo "[FATAL] \${token} must be set to the credentials of the port-forwarder service account."
elif [[ -z "${environment:-}" ]]; then
	echo "[FATAL] \${environment} must be set to specify which bastion to interact with."
fi

function OC() {
	oc --server https://api.ci.openshift.org --token "${token}" --namespace "bastion-${environment}" "${@}"
}

function port-forward() {
	while true; do
		echo "[INFO] Setting up port-forwarding to connect to the bastion..."
		pod="$( OC get pods --selector component=sshd -o jsonpath={.items[0].metadata.name} )"
		if ! OC port-forward "${pod}" 2222; then
			echo "[WARNING] Port-forwarding failed, retrying..."
		fi
	done
}

function ssh-tunnel() {
	while true; do
		echo "[INFO] Setting up a reverse SSH tunnel to expose port 8080..."
		if ! ssh -N -T root@127.0.0.1 -p 2222 -R "8080:127.0.0.1:8080"; then
			echo "[WARNING] SSH tunnelling failed, retrying..."
		fi
	done
}

trap "kill 0" SIGINT

# set up port forwarding from the SSH bastion to the local port 2222
port-forward &

# without a better synchonization library, we just need to wait for the port-forward to run
sleep 5

# run an SSH tunnel from the port 8080 on the SSH bastion (through local port 2222) to local port 80
ssh-tunnel &

for job in $( jobs -p ); do
	wait "${job}"
done
```

Reach your service on the in-cluster network with a Pod. Create a `pod.yaml` and view the logs :

```terminal
$ cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: bastion-${environment}
spec:
  restartPolicy: Never
  containers:
  - name: connect
    command:
    - /usr/bin/curl
    args:
    - sshd.bastion-${environment}
    image: registry.ci.openshift.org/origin/centos:8
EOF | oc apply -f -
$ oc logs --pod-running-timeout=10m "bastion-${environment}"
$ oc delete pod "bastion-${environment}"
```