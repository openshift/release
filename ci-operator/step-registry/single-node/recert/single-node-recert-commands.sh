#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Echo a script to be run as our systemd unit to a file so we can base64 encode it.
recert_script=$(cat << EOF
#!/usr/bin/env bash

set -euoE pipefail

export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig
function wait_for_api {
  echo "Waiting for API..."
  until oc get clusterversion &> /dev/null
  do
    echo "Waiting for API..."
    sleep 5
  done
  echo "API is available"
}

function start_containers {
  systemctl start crio
  systemctl start kubelet
}

function stop_containers {
  systemctl stop kubelet
  crictl ps -q | xargs crictl stop || true
  systemctl stop crio
}

function recert {
  local release_image="${RELEASE_IMAGE:-quay.io/openshift-release-dev/ocp-release:4.13.6-x86_64}"
  local etcd_image="\$(oc adm release extract --from="\${release_image}" --file=image-references | jq '.spec.tags[] | select(.name == "etcd").from.name' -r)"
  local recert_image="${RECERT_IMAGE:-quay.io/edge-infrastructure/recert:latest}"

  podman run --authfile=/var/lib/kubelet/config.json \
      --name recert_etcd \
      --detach \
      --rm \
      --network=host \
      --privileged \
      --entrypoint etcd \
      -v /var/lib/etcd:/store \
      "\${etcd_image}" \
      --name editor \
      --data-dir /store \

  sleep 10 # TODO: wait for etcd

  podman run -it --network=host --privileged \
      -v /tmp/certs:/certs  \
      -v /tmp/keys:/keys \
      -v /etc/kubernetes:/kubernetes \
      -v /var/lib/kubelet:/kubelet \
      -v /etc/machine-config-daemon:/machine-config-daemon \
      \${recert_image} \
      --etcd-endpoint localhost:2379 \
      --static-dir /kubernetes \
      --static-dir /kubelet \
      --static-dir /machine-config-daemon \
      --use-cert /certs/admin-kubeconfig-client-ca.crt \
      --use-key "kube-apiserver-localhost-signer /keys/localhost-serving-signer.key" \
      --use-key "kube-apiserver-lb-signer /keys/loadbalancer-serving-signer.key" \
      --use-key "kube-apiserver-service-network-signer /keys/service-network-serving-signer.key" \
      --use-key "\${ROUTER_CA_CN} /keys/router-ca.key" \

  podman kill recert_etcd

  # workaround until https://github.com/omertuc/recert/blob/4d41d451ba57fbc9fd75781684906360696f384a/README.md?plain=1#L24 is resolved
  rm -rf "/etc/machine-config-daemon/currentconfig"
  touch "/run/machine-config-daemon-force"
}

function fetch_crts_keys {
  mkdir -p /tmp/certs /tmp/keys

  oc get cm -n openshift-config admin-kubeconfig-client-ca -ojsonpath='{.data.ca-bundle\.crt}' > /tmp/certs/admin-kubeconfig-client-ca.crt

  declare -a secrets=(
    "loadbalancer-serving-signer"
    "localhost-serving-signer"
    "service-network-serving-signer"
  )
  for secret in "\${secrets[@]}"; do
    oc get secrets -n openshift-kube-apiserver-operator "\${secret}" -ojsonpath='{.data.tls\.key}' | base64 -d > "/tmp/keys/\${secret}.key"
  done

  # CommonName includes a timestamp so we cannot hardcode it, e.g. ingress-operator@1693569847
  ROUTER_CA_CN=\$(oc get secret -n openshift-ingress-operator router-ca -ojsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -subject -noout -nameopt multiline | grep commonName | awk '{ print \$3 }')
  oc get secret -n openshift-ingress-operator router-ca -ojsonpath='{.data.tls\.key}' | base64 -d > "/tmp/keys/router-ca.key"
}

function delete_crts_keys {
  rm -rf /tmp/certs /tmp/keys
}

wait_for_api
fetch_crts_keys
stop_containers

recert

start_containers
delete_crts_keys

touch /var/recert.done
echo "Recert successfully run."
EOF
)

# Base64 encode the script for use in the MachineConfig.
b64_script=$(echo "${recert_script}" | base64 -w 0)

machineconfig=$(oc create -f - -o jsonpath='{.metadata.name}' << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-recert
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${b64_script}
        mode: 493
        overwrite: true
        path: /usr/local/bin/recert.sh
    systemd:
      units:
      - contents: |
          [Unit]
          Description=Regenerate certificates script
          After=kubelet.service
          ConditionPathExists=!/var/recert.done
          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/usr/local/bin/recert.sh
          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: recert.service
EOF
)
echo "Created \"${machineconfig}\" MachineConfig"

echo "Waiting for master MachineConfigPool to have condition=updating..."
oc wait --for=condition=updating machineconfigpools master --timeout 2m

echo "Waiting for master MachineConfigPool to have condition=updated..."
until oc wait --for=condition=updated machineconfigpools master --timeout=5m &> /dev/null
do
  echo "Waiting for master MachineConfigPool to have condition=updated..."
  sleep 5s
done

oc adm wait-for-stable-cluster --minimum-stable-period=5m --timeout=30m
