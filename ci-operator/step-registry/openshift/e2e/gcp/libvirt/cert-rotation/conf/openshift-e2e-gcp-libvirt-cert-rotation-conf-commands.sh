#!/bin/bash

set -euxo pipefail

echo "************ libvirt cert rotation conf command ************"

# This script sets up a mirrored local registry with the installer.
# This enables testing certificate rotation in a cluster older than 1 year
# Instead of waiting 1 year, fake the time and install with a local image-registry
# and long-lived certs. 
cat > "${SHARED_DIR}"/create-cluster-mirrored-local-registry << 'END'
#!/bin/bash

set -euxo pipefail

CLUSTER_DIR="${HOME}/clusters/installer"
mkdir -p "${CLUSTER_DIR}"
# Generate a default SSH key if one doesn't exist
SSH_KEY="${HOME}/.ssh/id_rsa"
if [ ! -f $SSH_KEY ]; then
  ssh-keygen -t rsa -N "" -f $SSH_KEY
fi
export BASE_DOMAIN=openshift.testing
export PUB_SSH_KEY="${SSH_KEY}.pub"

# https://github.com/ironcladlou/openshift4-libvirt-gcp/issues/29
# gcp image is provisioned with this version, but is auto-updated.
# rather than turn off auto-upates, downgrade qemu-kvm each go.
if ! sudo dnf info qemu-kvm | grep -A 5 'Installed Packages' | grep 88.module+el8.1.0+5708+85d8e057.3; then
    echo "downgrading qemu-kvm to version 2.12.0-88.module+el8.1.0+5708+85d8e057.3"
    sudo dnf remove -y qemu-kvm && sudo dnf install -y qemu-kvm-2.12.0-88.module+el8.1.0+5708+85d8e057.3
fi

# Set up local registry with long-lived certs with SAN
HOSTNAME=$(curl "http://metadata.google.internal/computeMetadata/v1/instance/hostname" -H "Metadata-Flavor: Google")
sudo dnf -y install podman httpd httpd-tools make
go get -u github.com/cloudflare/cfssl/cmd/...
make -C go/src/github.com/cloudflare/cfssl
sudo cp go/src/github.com/cloudflare/cfssl/bin/cfssl /usr/local/bin
sudo cp go/src/github.com/cloudflare/cfssl/bin/cfssljson /usr/local/bin
mkdir create-registry-certs
pushd create-registry-certs
cat > ca-config.json << EOF
{
    "signing": {
        "default": {
            "expiry": "87600h"
        },
        "profiles": {
            "server": {
                "expiry": "87600h",
                "usages": [
                    "signing",
                    "key encipherment",
                    "server auth"
                ]
            },
            "client": {
                "expiry": "87600h",
                "usages": [
                    "signing",
                    "key encipherment",
                    "client auth"
                ]
            }
        }
    }
}
EOF

cat > ca-csr.json << EOF
{
    "CN": "Test Registry Self Signed CA",
    "hosts": [
        "${HOSTNAME}"
    ],
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "US",
            "ST": "CA",
            "L": "San Francisco"
        }
    ]
}
EOF

cat > server.json << EOF
{
    "CN": "Test Registry Self Signed CA",
    "hosts": [
        "${HOSTNAME}"
    ],
    "key": {
        "algo": "ecdsa",
        "size": 256
    },
    "names": [
        {
            "C": "US",
            "ST": "CA",
            "L": "San Francisco"
        }
    ]
}
EOF

# generate ca-key.pem, ca.csr, ca.pem
cfssl gencert -initca ca-csr.json | cfssljson -bare ca -

# generate server-key.pem, server.csr, server.pem
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=server server.json | cfssljson -bare server

# enable schema version 1 images
cat > registry-config.yml << EOF
version: 0.1
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
compatibility:
  schema1:
    enabled: true
EOF

sudo mkdir -p /opt/registry/{auth,certs,data}
sudo firewall-cmd --add-port=5000/tcp --zone=internal --permanent
sudo firewall-cmd --add-port=5000/tcp --zone=public   --permanent
sudo firewall-cmd --add-service=http  --permanent
sudo firewall-cmd --reload

CA=$(sudo tail -n +2 ca.pem | head -n-1 | tr -d '\r\n')
sudo htpasswd -bBc /opt/registry/auth/htpasswd test test
sudo cp registry-config.yml /opt/registry/.
sudo cp server-key.pem /opt/registry/certs/.
sudo cp server.pem /opt/registry/certs/.
sudo cp /opt/registry/certs/server.pem /etc/pki/ca-trust/source/anchors/
sudo cp ca.pem /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust extract

# Now that certs are in place, run the local image registry
sudo podman run --name test-registry -p 5000:5000 \
-v /opt/registry/data:/var/lib/registry:z \
-v /opt/registry/auth:/auth:z \
-e "REGISTRY_AUTH=htpasswd" \
-e "REGISTRY_AUTH_HTPASSWD_REALM=Registry" \
-e "REGISTRY_HTTP_SECRET=ALongRandomSecretForRegistry" \
-e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
-v /opt/registry/certs:/certs:z \
-v /opt/registry/registry-config.yml:/etc/docker/registry/config.yml:z \
-e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/server.pem \
-e REGISTRY_HTTP_TLS_KEY=/certs/server-key.pem \
-d docker.io/library/registry:2

popd
retries=0
export LOCAL_REG="${HOSTNAME}:5000"
set +e
while ! curl -u test:test https://"${LOCAL_REG}"/v2/_catalog && [ $retries -lt 10 ]; do
  if [ $retries -eq 9 ]; then
    exit 1
  fi
  (( retries++ ))
done
set -e

cp ~/pull-secret ~/pull-secret-new
podman login -u test -p test --authfile ~/pull-secret-new "${HOSTNAME}":5000
jq -c < ~/pull-secret-new '.' > ~/pull-secret-one-line
mv ~/pull-secret-one-line ~/pull-secret

export OCP_RELEASE=$( oc adm release -a ~/pull-secret info "${RELEASE_IMAGE_LATEST}" -o template --template='{{.metadata.version}}' )
export LOCAL_REPO='ocp4/openshift4'
export PULL_SECRET=$(cat "${HOME}/pull-secret")

oc adm release mirror -a ~/pull-secret \
--from="${RELEASE_IMAGE_LATEST}" \
--to-release-image="${LOCAL_REG}/${LOCAL_REPO}:${OCP_RELEASE}" \
--to="${LOCAL_REG}/${LOCAL_REPO}"

# in case it's set in CI job yaml
unset OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE

# extract libvirt installer from release image
oc adm release extract -a ~/pull-secret --command openshift-baremetal-install "${LOCAL_REG}/${LOCAL_REPO}:${OCP_RELEASE}"
sudo mv openshift-baremetal-install /usr/local/bin/openshift-install

# extract oc from release image
oc adm release extract -a ~/pull-secret --command oc "${LOCAL_REG}/${LOCAL_REPO}:${OCP_RELEASE}"
sudo mv oc /usr/local/bin/oc

cat > "${CLUSTER_DIR}/install-config.yaml" << EOF
apiVersion: v1
baseDomain: "${BASE_DOMAIN}"
compute:
- hyperthreading: Enabled
  architecture: amd64
  name: worker
  platform: {}
  replicas: 2
controlPlane:
  hyperthreading: Enabled
  architecture: amd64
  name: master
  platform: {}
  replicas: 3
metadata:
  creationTimestamp: null
  name: installer
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 192.168.126.0/24
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
platform:
  libvirt:
    network:
      if: tt0
publish: External
pullSecret: $(echo \'"${PULL_SECRET}"\')
sshKey: |
  $(cat "${PUB_SSH_KEY}")
additionalTrustBundle: |
  -----BEGIN CERTIFICATE-----
  $(echo "${CA}")
  -----END CERTIFICATE-----
imageContentSources:
- mirrors:
  - ${HOSTNAME}:5000/ocp4/openshift4
  source: quay.io/openshift-release-dev/ocp-release-nightly
- mirrors:
  - ${HOSTNAME}:5000/ocp4/openshift4
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
EOF

# Create manifests and modify route domain
openshift-install --dir="${CLUSTER_DIR}" create manifests
# Workaround for https://github.com/openshift/installer/issues/1007
# Add custom domain to cluster-ingress
yq write --inplace $CLUSTER_DIR/manifests/cluster-ingress-02-config.yml spec[domain] apps.$BASE_DOMAIN

# Add master memory to 14 GB
# This is only valid for openshift 4.3 onwards
yq write --inplace ${CLUSTER_DIR}/openshift/99_openshift-cluster-api_master-machines-0.yaml spec.providerSpec.value[domainMemory] 14336
set -x
openshift-install create cluster --log-level=debug --dir="$CLUSTER_DIR" || true
openshift-install wait-for install-complete --log-level=debug --dir="$CLUSTER_DIR"
END
chmod +x "${SHARED_DIR}"/create-cluster-mirrored-local-registry

cat  > "${SHARED_DIR}"/time-skew-test.sh << 'EOF'
#!/bin/bash

set -euxo pipefail

final-check () {
  if
    ! oc wait co --all --for='condition=Available=True' --timeout=0 1>/dev/null || \
    ! oc wait co --all --for='condition=Progressing=False' --timeout=0 1>/dev/null || \
    ! oc wait co --all --for='condition=Degraded=False' --timeout=0 1>/dev/null; then
      echo "Some ClusterOperators Degraded=True,Progressing=True,or Available=False"
      oc get co
      exit 1
  else
    echo "All ClusterOperators reporting healthy"
    oc get co
    oc get clusterversion
  fi
  exit 0
}
trap final-check EXIT

approveCSRs () {
  pendingCSRs=$(oc get csr | grep Pending | wc -l)
  if [ $pendingCSRs -ne 0 ]; then
    echo "Approving pending csrs"
    oc get csr -o name | xargs oc adm certificate approve
    sleep 30
  fi
}

# TODO: Need to improve this nodesReady check
checkNodesReady () {
  nodesReady=0
  retries=0
  while [ $nodesReady -ne 5 ] && [ $retries -lt 50 ]; do
    approveCSRs
    nodesReady=$(oc wait --for=condition=Ready node --all --timeout=30s| wc -l)
    if [ $nodesReady -eq 5 ]; then
      echo "All nodes Ready"
    fi
    (( retries++ ))
  done
  if [ $nodesReady -ne 5 ]; then
    echo "Some nodes NotReady"
    oc get nodes
    exit 1
  fi
}

jumpstartNodes () {
  approveCSRs
  # jumpstart any stuck nodes, during recovery nodes will be rebooted
  nodesDisabled=$(oc get nodes | grep "NotReady" | awk '{ print $1 }')
  if [ ! -z "${nodesDisabled}" ]; then
    nodeDisabledList=( $nodesDisabled )
    for i in "${nodeDisabledList[@]}"
    do
      echo "Restarting stuck node ${i}..."
      sudo virsh destroy "${i}"
      sleep 30
      sudo virsh start "${i}"
      sleep 60
    done
    checkNodesReady
  fi
}

checkDegradedCOs () {
  retries=0
  # image-pruner job in openshift-image-registry namespace may be stuck due to time skew. This would not
  # happen if time was progressing naturally. Kill image-prune jobs here.
  oc delete jobs --all -n openshift-image-registry
  sleep 10
  while ! oc wait co --all --for='condition=Degraded=False' --timeout=10s && [ $retries -lt 50 ]; do
    (( retries++ ))
  done
}

checkProgressingCOs () {
  retries=0
  # image-pruner job in openshift-image-registry namespace may be stuck due to time skew. This would not
  # happen if time was progressing naturally. Kill image-prune jobs here.
  oc delete jobs --all -n openshift-image-registry
  sleep 10
  while ! oc wait co --all --for='condition=Progressing=False' --timeout=10s && [ $retries -lt 100 ]; do
    jumpstartNodes
    (( retries++ ))
  done
}

checkAvailableCOs () {
  retries=0
  while ! oc wait co --all --for='condition=Available=True' --timeout=20s && [ $retries -lt 100 ]; do
    jumpstartNodes
    (( retries++ ))
  done
}

sudo systemctl stop chronyd

SKEW=${1:-+400d}

OC=${OC:-oc}
SSH=${SSH:-ssh}

masters=$( ${OC} get nodes --selector='node-role.kubernetes.io/master' --template='{{ range $index, $_ := .items }}{{ range .status.addresses }}{{ if (eq .type "InternalIP") }}{{ if $index }} {{end }}{{ .address }}{{ end }}{{ end }}{{ end }}' )
workers=$( ${OC} get nodes --selector='!node-role.kubernetes.io/master' --template='{{ range $index, $_ := .items }}{{ range .status.addresses }}{{ if (eq .type "InternalIP") }}{{ if $index }} {{end }}{{ .address }}{{ end }}{{ end }}{{ end }}' )

function run-on {
        for n in ${1}; do ${SSH} core@"${n}" sudo 'bash -eEuxo pipefail' <<< ${2}; done
}

ssh-keyscan -H ${masters} ${workers} >> ~/.ssh/known_hosts

run-on "${masters} ${workers}" "systemctl stop kubelet"

# Destroy all containers on workers.
run-on "${workers}" "crictl rm --all -f"
# Destroy all containers on masters except KAS and etcd.
run-on "${masters}" '
kas_id=$( crictl ps --name="^kube-apiserver$" -q )
[[ -n "${kas_id}" ]]
etcd_id=$( crictl ps --name="^etcd$" -q )
[[ -n "${etcd_id}" ]]
other_ids=$( crictl ps --all -q | ( grep -v -e "${kas_id}" -e "${etcd_id}" || true ) )
if [ -n "${other_ids}" ]; then
        crictl rm -f ${other_ids}
fi;
'

# Delete all pods, especialy the operators. Makes sure it needs KCM and KS working when starting again.
${OC} delete pods -A --all --force --grace-period=0 --timeout=0

# Delete all clusteroperator status to avoid stale status when the operator pod isn't started.
export bearer=$( oc -n openshift-cluster-version serviceaccounts get-token default ) && export server=$( oc whoami --show-server ) && for co in $( oc get co --template='{{ range .items }}{{ printf "%s\n" .metadata.name }}{{ end }}' ); do curl -X PATCH -H "Authorization: Bearer ${bearer}" -H "Accept: application/json" -H "Content-Type: application/merge-patch+json" ${server}/apis/config.openshift.io/v1/clusteroperators/${co}/status -d '{"status": null}' && echo; done

# Destroy the remaining containers on masters
run-on "${masters}" "crictl rm --all -f"

run-on "${masters} ${workers}" "systemctl disable chronyd --now"

# Set time only as a difference to the synced time so we don't introduce a skew between the machines which would break etcd, leader election and others.
run-on "${masters} ${workers}" "
timedatectl status
timedatectl set-ntp false
timedatectl set-time '${SKEW}'
timedatectl status
"

# now set date for host
sudo timedatectl set-time ${SKEW}

run-on "${masters} ${workers}" "systemctl start kubelet"

# wait for connectivity
# allow 4 minutes for date to propagate and to regain connectivity
set +e
retries=0
while ! oc get csr && [ $retries -lt 25 ]; do
  if [ $retries -eq 24 ]; then
    exit 1
  fi
  sleep 10
  (( retries++ ))
done

set +eu
checkNodesReady
checkAvailableCOs
checkProgressingCOs
checkDegradedCOs

EOF
chmod +x "${SHARED_DIR}"/time-skew-test.sh
