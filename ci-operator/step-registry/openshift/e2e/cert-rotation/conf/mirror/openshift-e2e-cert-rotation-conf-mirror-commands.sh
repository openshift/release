#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ openshift cert rotation shutdown test command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# This file is scp'd to the machine where the nested libvirt cluster is running
# It stops kubelet service, kills all containers on each node, kills all pods,
# disables chronyd service on each node and on the machine itself, sets date ahead 400days
# then starts kubelet on each node and waits for cluster recovery. This simulates
# cert-rotation after 1 year.
# TODO: Run suite of conformance tests after recovery
cat >"${SHARED_DIR}"/local-mirror.sh <<'EOF'
#!/bin/bash

set -euxo pipefail

curl -L https://github.com/mikefarah/yq/releases/download/v4.13.5/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

# Enable TLS and auth on minikube registry
dnf install -y wget httpd-tools

# install cfssl
CFSSL_VERSION=$(curl --silent "https://api.github.com/repos/cloudflare/cfssl/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
CFSSL_VNUMBER=${CFSSL_VERSION#"v"}
wget https://github.com/cloudflare/cfssl/releases/download/${CFSSL_VERSION}/cfssl_${CFSSL_VNUMBER}_linux_amd64 -O cfssl
chmod +x cfssl
sudo mv cfssl /usr/local/bin

# install cfssljson
wget https://github.com/cloudflare/cfssl/releases/download/${CFSSL_VERSION}/cfssljson_${CFSSL_VNUMBER}_linux_amd64 -O cfssljson
chmod +x cfssljson
sudo mv cfssljson /usr/local/bin

HOSTNAME="${1}"

mkdir /tmp/create-registry-certs
pushd /tmp/create-registry-certs
cat > ca-config.json << EOZ
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
EOZ

cat > ca-csr.json << EOZ
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
EOZ

cat > server.json << EOZ
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
EOZ

# generate ca-key.pem, ca.csr, ca.pem
cfssl gencert -initca ca-csr.json | cfssljson -bare ca -

# generate server-key.pem, server.csr, server.pem
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=server server.json | cfssljson -bare server

htpasswd -bBc htpasswd test test
cp server.pem /etc/pki/ca-trust/source/anchors/
cp ca.pem /etc/pki/ca-trust/source/anchors/
update-ca-trust extract

kubectl -n kube-system create configmap registry-auth --from-file=htpasswd=htpasswd
kubectl -n kube-system create configmap registry-certs --from-file=server.pem=server.pem --from-file=server-key.pem=server-key.pem

cat > /tmp/patch.yml <<'EOZ'
apiVersion: v1
kind: ReplicationController
metadata:
  name: registry
  namespace: kube-system
spec:
  selector:
    kubernetes.io/minikube-addons: registry
    actual-registry: "true"
  template:
    metadata:
      labels:
        kubernetes.io/minikube-addons: registry
        actual-registry: "true"
    spec:
      containers:
      - name: registry
        image: quay.io/libpod/registry:2.8
        ports:
        - containerPort: 5000
        env:
        - name: REGISTRY_AUTH
          value: htpasswd
        - name: REGISTRY_AUTH_HTPASSWD_REALM
          value: Registry
        - name: REGISTRY_HTTP_SECRET
          value: ALongRandomSecretForRegistry
        - name: REGISTRY_AUTH_HTPASSWD_PATH
          value: /auth/htpasswd
        - name: REGISTRY_HTTP_TLS_CERTIFICATE
          value: /certs/server.pem
        - name: REGISTRY_HTTP_TLS_KEY
          value: /certs/server-key.pem
        volumeMounts:
        - name: auth
          mountPath: /auth
        - name: certs
          mountPath: /certs
      volumes:
      - name: auth
        configMap:
          name: registry-auth
      - name: certs
        configMap:
          name: registry-certs
EOZ
kubectl apply -f /tmp/patch.yml
kubectl -n kube-system delete pod -l kubernetes.io/minikube-addons=registry

# Enable registry access from VMs
firewall-cmd --add-port=5000/tcp --zone=internal --permanent
firewall-cmd --add-port=5000/tcp --zone=public   --permanent
firewall-cmd --add-port=5000/tcp --zone=libvirt   --permanent
# FIXME: open access to assisted-service too
firewall-cmd --add-port=6000/tcp --zone=internal --permanent
firewall-cmd --add-port=6000/tcp --zone=public   --permanent
firewall-cmd --add-port=6000/tcp --zone=libvirt   --permanent
firewall-cmd --reload


# Wait for registry to come up again
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

# Mirror release to minikube registry
cp ~/pull-secret ~/pull-secret-new
podman login -u test -p test --authfile ~/pull-secret-new "${LOCAL_REG}"
jq -c < ~/pull-secret-new '.' > ~/pull-secret-one-line
mv ~/pull-secret-one-line ~/pull-secret

source ~/config.sh
export OCP_RELEASE=$( oc adm release -a ~/pull-secret info "${RELEASE_IMAGE_LATEST}" -o template --template='{{.metadata.version}}' )
export LOCAL_REPO='ocp/openshift4'

oc adm release mirror -a ~/pull-secret \
    --from="${RELEASE_IMAGE_LATEST}" \
    --to-release-image="${LOCAL_REG}/${LOCAL_REPO}:${OCP_RELEASE}" \
    --to="${LOCAL_REG}/${LOCAL_REPO}" | tee /tmp/oc-mirror.output

# Build registries.conf
tail -n 12 /tmp/oc-mirror.output | tee /tmp/icsp.yaml
SOURCE1=$(/tmp/yq eval '.spec.repositoryDigestMirrors[0].source' "/tmp/icsp.yaml")
SOURCE2=$(/tmp/yq eval '.spec.repositoryDigestMirrors[1].source' "/tmp/icsp.yaml")

cat > /tmp/registries.conf << EOZ
unqualified-search-registries = ["registry.access.redhat.com", "docker.io"]
[[registry]]
    prefix = ""
    location = "${SOURCE1}"
    mirror-by-digest-only = true
    [[registry.mirror]]
    location = "${LOCAL_REG}/${LOCAL_REPO}"
[[registry]]
    prefix = ""
    location = "${SOURCE2}"
    mirror-by-digest-only = true
    [[registry.mirror]]
    location = "${LOCAL_REG}/${LOCAL_REPO}"
EOZ
cat /tmp/registries.conf

# Create a new CA bundle with registry CA included, restart assisted-service
kubectl create configmap mirror-registry-ca -n assisted-installer --from-file=ca-bundle.crt=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem --from-file=registries.conf=/tmp/registries.conf
mkdir -p $HOME/custom_manifests
cat /etc/pki/ca-trust/source/anchors/ca.pem > $HOME/custom_manifests/ca.pem
cat /etc/pki/ca-trust/source/anchors/server.pem >> $HOME/custom_manifests/ca.pem
echo "export REGISTRY_CA_PATH=$HOME/custom_manifests/ca.pem" >> ~/config.sh

kubectl -n assisted-installer delete pods -l app=assisted-service
kubectl -n assisted-installer rollout status deploy/assisted-service
POD_NAME=$(kubectl -n assisted-installer get pod -l app=assisted-service -o name)
kubectl -n assisted-installer exec ${POD_NAME} -- cp -r /etc/pki/ca-trust/extracted/pem/mirror_ca.pem /etc/pki/tls/certs/ca-bundle.crt

# Point assisted service to mirror first
MIRRORED_RELEASE_IMAGE=$(grep -oP "Update image:\s*\K.+" /tmp/oc-mirror.output)
MIRRORED_DIGEST=$( oc adm release -a ~/pull-secret info "${MIRRORED_RELEASE_IMAGE}" -o template --template='{{.digest}}' )
echo "export RELEASE_IMAGE_LATEST=${LOCAL_REG}/${LOCAL_REPO}@${MIRRORED_DIGEST}" >> ~/config.sh
echo "export OPENSHIFT_INSTALL_RELEASE_IMAGE=${LOCAL_REG}/${LOCAL_REPO}@${MIRRORED_DIGEST}" >> ~/config.sh
#TODO: Fix assisted-test-infra to pass CA bundle in skipper
echo "export OPENSHIFT_VERSION=4.14" >> ~/config.sh

exit 0
EOF
chmod +x "${SHARED_DIR}"/local-mirror.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/local-mirror.sh "root@${IP}:/usr/local/bin"

timeout \
	--kill-after 10m \
	120m \
	ssh \
	"${SSHOPTS[@]}" \
	"root@${IP}" \
	/usr/local/bin/local-mirror.sh \
  "${IP}"
