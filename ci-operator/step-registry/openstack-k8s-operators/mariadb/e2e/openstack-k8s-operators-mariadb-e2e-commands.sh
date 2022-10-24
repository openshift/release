#!/usr/bin/env bash

set -ex

# Setup temp quay registry credentials
mkdir -p "$HOME/.docker"
REGISTRY_TOKEN_FILE="/secrets/docker/config.json"
cp "${REGISTRY_TOKEN_FILE}" "$HOME/.docker/config.json"
export OS_REGISTRY=quay.io
export OS_REPO=dviroel

mkdir -p "$HOME/.local"
export XDG_RUNTIME_DIR="$HOME/.local"

cp -r /go/src/github.com/openstack-k8s-operators/mariadb-operator/ $HOME

export IMAGE_TAG_BASE=${OS_REGISTRY}/${OS_REPO}/mariadb-operator
export VERSION=0.0.2
export IMG=$IMAGE_TAG_BASE:v$VERSION

mkdir -p "$HOME/bin"
curl -L --retry 5 https://github.com/opencontainers/umoci/releases/download/v0.4.7/umoci.amd64 -o "$HOME/bin/umoci" && chmod +x "$HOME/bin/umoci"
export PATH=$PATH:$HOME/bin

skopeo copy docker://${MARIADB_OPERATOR} docker://${OS_REGISTRY}/${OS_REPO}/mariadb-operator:${OPENSHIFT_BUILD_COMMIT}
skopeo copy docker://${MARIADB_OPERATOR_BUNDLE} docker://${OS_REGISTRY}/${OS_REPO}/mariadb-operator-bundle:${OPENSHIFT_BUILD_COMMIT}

cd $HOME/mariadb-operator
opm index add \
    --bundles "${OS_REGISTRY}/${OS_REPO}/mariadb-operator-bundle:${OPENSHIFT_BUILD_COMMIT}" \
    --out-dockerfile index.Dockerfile \
    --generate

skopeo copy "docker://quay.io/operator-framework/opm:latest" oci:opm:latest
umoci unpack --rootless --image opm:latest index
mv database index/rootfs/
umoci repack --image opm:index index

umoci config --config.label 'operators.operatorframework.io.index.database.v1=/database/index.db' --image opm:index
umoci config --config.exposedports "50051" --image opm:index
umoci config --config.entrypoint "/bin/opm" --image opm:index
umoci config --config.cmd "registry" \
                    --config.cmd "serve" \
                    --config.cmd "--database" \
                    --config.cmd "/database/index.db" \
                    --image opm:index

skopeo copy oci:opm:index docker://${OS_REGISTRY}/${OS_REPO}/mariadb-operator-index:${OPENSHIFT_BUILD_COMMIT}

cd $HOME
rm -rf install_yamls
git clone https://github.com/openstack-k8s-operators/install_yamls.git
cd $HOME/install_yamls
# Sets namespace to 'openstack'
export NAMESPACE=openstack
# Creates namespace
make namespace
sleep 5
# Creates storage needed for mariadb
make crc_storage
sleep 20
# Deploy mariadb operator
make mariadb MARIADB_IMG=${OS_REGISTRY}/${OS_REPO}/mariadb-operator-index:${OPENSHIFT_BUILD_COMMIT}
sleep 120
# Deploy mariadb service
make mariadb_deploy
sleep 120
# Get all resources
oc get all
# Show mariadb databases
oc exec -it  pod/mariadb-openstack -- mysql -uroot -p12345678 -e "show databases;"
