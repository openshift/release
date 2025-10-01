#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

function mirror_ccs() {
    echo "### Mirroring the selected operators to the internal registry"
    source "${SHARED_DIR}/packet-conf.sh"

    CCS_CATALOG_IMAGE="registry.redhat.io/redhat/redhat-operator-index:${REDHAT_OPERATORS_INDEX_TAG}"
    CCS_VERSION="${REDHAT_OPERATORS_INDEX_TAG}"

    scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:/home/pull-secret"

    # shellcheck disable=SC2087
    ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${CCS_CATALOG_IMAGE}" "${CCS_VERSION}" "${CCS_OPERATOR_PACKAGES}" "${CCS_OPERATOR_CHANNELS}" << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
    CCS_CATALOG_IMAGE="${1}"
    CCS_VERSION="${2}"
    CCS_OPERATOR_PACKAGES="${3}"
    CCS_OPERATOR_CHANNELS="${4}"

    set -xeo pipefail

    echo "1. Get mirror registry"
    mirror_registry=$(oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]')
    mirror_registry=${mirror_registry%%/*}
    if [[ $mirror_registry == "" ]] ; then
        echo "Warning: Can not find the mirror registry, abort !!!"
        exit 1
    fi
    echo "mirror registry is ${mirror_registry}"

    echo "2: get oc-mirror from stable clients"
    if [[ ! -f /home/oc-mirror ]]; then
        MIRROR2URL="https://mirror2.openshift.com/pub/openshift-v4"
        CLIENTURL="${MIRROR2URL}"/x86_64/clients/ocp/stable
        curl -s -k -L "${CLIENTURL}/oc-mirror.tar.gz" -o om.tar.gz && tar -C /home -xzvf om.tar.gz && rm -f om.tar.gz
        if ls /home/oc-mirror > /dev/null ; then
            chmod +x /home/oc-mirror
        else
            echo "Warning, can not find oc-mirror abort !!!"
            exit 1
        fi
    fi
    /home/oc-mirror version

    echo "3: Check skopeo and registry credentials"
    if [[ ! -f /usr/bin/skopeo ]]; then
        yum install -y skopeo
    fi
    oc -n openshift-config extract secret/pull-secret --to="/tmp" --confirm
    mirror_token=$(cat "/tmp/.dockerconfigjson" | jq -r --arg var1 "${mirror_registry}" '.auths[$var1]["auth"]'|base64 -d)
    skopeo login "${mirror_registry}" -u "${mirror_token%:*}" -p "${mirror_token#*:}"
  
    echo "4: skopeo copy docker://${CCS_CATALOG_IMAGE} oci:///home/ccs-local-catalog --remove-signatures"
    skopeo copy "docker://${CCS_CATALOG_IMAGE}" "oci:///home/ccs-local-catalog" --remove-signatures --authfile=/home/pull-secret

    echo "5: oc-mirror"
    catalog_image="ccs-local-catalog/ccs-local-catalog"

    cat <<END |tee "/home/registry.conf"
    [[registry]]
     location = "registry.stage.redhat.io"
     insecure = true
     blocked = false
     mirror-by-digest-only = false
     [[registry.mirror]]
        location = "brew.registry.redhat.io"
        insecure = true
    [[registry]]
     location = "registry-proxy.engineering.redhat.com/rh-osbs"
     insecure = true
     blocked = false
     mirror-by-digest-only = false
     [[registry.mirror]]
        location = "brew.registry.redhat.io/rh-osbs"
        insecure = true
END

    rm -rf /home/imageset-config.yaml

    IFS=',' read -r -a p_array <<< "$CCS_OPERATOR_PACKAGES"
    IFS=',' read -r -a c_array <<< "$CCS_OPERATOR_CHANNELS"

    if [[ "${#p_array[@]}" != "${#c_array[@]}" ]];
    then
        echo "CCS_OPERATOR_PACKAGES and CCS_OPERATOR_CHANNELS don't contain the same number of items"
        exit 1
    fi

    cat <<END >> "/home/imageset-config.yaml"
    kind: ImageSetConfiguration
    apiVersion: mirror.openshift.io/v1alpha2
    storageConfig:
      local:
        path: mirror
    mirror:
      operators:
      - catalog: "oci:///home/ccs-local-catalog"
        targetCatalog: ${catalog_image}
        targetTag: "${CCS_VERSION}"
        packages:
END

    for index in "${!p_array[@]}"
    do
    cat <<END >> "/home/imageset-config.yaml"
        - name: ${p_array[index]}
          channels:
          - name: ${c_array[index]}
END
    done

    cat /home/imageset-config.yaml


    pushd /home
    # cleanup leftovers from previous executions
    rm -rf oc-mirror-workspace
    # try at least 3 times to be sure to get all the images...
    /home/oc-mirror --config "/home/imageset-config.yaml" docker://${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
    /home/oc-mirror --config "/home/imageset-config.yaml" docker://${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
    /home/oc-mirror --config "/home/imageset-config.yaml" docker://${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
    popd

    echo "6: Create imageconentsourcepolicy and catalogsource"
    for d in /home/oc-mirror-workspace/results* ; do sed -i "s|name: operator-0$|name: operator-${d#/home/oc-mirror-workspace/results-}|g" ${d}/imageContentSourcePolicy.yaml; done
    find /home/oc-mirror-workspace -type d -name '*results*' -exec oc apply -f {}/*.yaml \;

    echo "7: Waiting for the new ImageContentSourcePolicy to be updated on machines"
    oc wait clusteroperators/machine-config --for=condition=Upgradeable=true --timeout=15m

    # TODO: why do we need this? do we have a bug?
    echo "8: explicitly fix IDMS for CSI sidecar images"

    oc apply -f - <<END
    apiVersion: config.openshift.io/v1
    kind: ImageDigestMirrorSet
    metadata:
      name: cs-ccs-local-fixes
    spec:
      imageDigestMirrors:
      - mirrors:
        - virthost.ostest.test.metalkube.org:5000/openshift4/ose-csi-external-provisioner
        source: registry.redhat.io/openshift4/ose-csi-external-provisioner
      - mirrors:
        - virthost.ostest.test.metalkube.org:5000/openshift4/ose-csi-external-resizer
        source: registry.redhat.io/openshift4/ose-csi-external-resizer
      - mirrors:
        - virthost.ostest.test.metalkube.org:5000/openshift4/ose-csi-external-snapshotter-rhel9
        source: registry.redhat.io/openshift4/ose-csi-external-snapshotter-rhel9
      - mirrors:
        - virthost.ostest.test.metalkube.org:5000/openshift4/ose-csi-external-snapshotter-rhel8
        source: registry.redhat.io/openshift4/ose-csi-external-snapshotter-rhel8
      - mirrors:
        - virthost.ostest.test.metalkube.org:5000/openshift4/ose-csi-node-driver-registrar
        source: registry.redhat.io/openshift4/ose-csi-node-driver-registrar
      - mirrors:
        - virthost.ostest.test.metalkube.org:5000/openshift4/ose-kube-rbac-proxy
        source: registry.redhat.io/openshift4/ose-kube-rbac-proxy
END

EOF
}




if [[ "${DISCONNECTED}" == "true" ]];
then
    mirror_ccs
else
    name="redhat-operators-$(echo $REDHAT_OPERATORS_INDEX_TAG| sed "s/[.]/-/g")"

    oc apply -f - <<EOF
    apiVersion: operators.coreos.com/v1alpha1
    kind: CatalogSource
    metadata:
      annotations:
        operatorframework.io/managed-by: marketplace-operator
        target.workload.openshift.io/management: '{"effect": "PreferredDuringScheduling"}'
      generation: 5
      name: $name
      namespace: openshift-marketplace
    spec:
      displayName: Red Hat Operators
      grpcPodConfig:
        nodeSelector:
          kubernetes.io/os: linux
          node-role.kubernetes.io/master: ""
        priorityClassName: system-cluster-critical
        securityContextConfig: restricted
        tolerations:
        - effect: NoSchedule
          key: node-role.kubernetes.io/master
          operator: Exists
        - effect: NoExecute
          key: node.kubernetes.io/unreachable
          operator: Exists
          tolerationSeconds: 120
        - effect: NoExecute
          key: node.kubernetes.io/not-ready
          operator: Exists
          tolerationSeconds: 120
      icon:
        base64data: ""
        mediatype: ""
      image: registry.redhat.io/redhat/redhat-operator-index:${REDHAT_OPERATORS_INDEX_TAG}
      priority: -100
      publisher: Red Hat
      sourceType: grpc
      updateStrategy:
        registryPoll:
          interval: 10m
EOF

    for i in $(seq 1 120); do
        state=$(oc get catalogsources/$name -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}')
        echo $state
        if [ "$state" == "READY" ] ; then
            echo "Catalogsource created successfully after waiting $((5*i)) seconds"
            echo "current state of catalogsource is \"$state\""
            created=true
            break
        fi
        sleep 5
    done
    [ "$created" = "true" ]
fi

