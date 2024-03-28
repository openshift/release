#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

function mirror_odf() {
    echo "### Mirroring ODF images"
    source "${SHARED_DIR}/packet-conf.sh"

    echo "registry.redhat.io/redhat/redhat-operator-index:${REDHAT_OPERATORS_INDEX_TAG}" > /tmp/odf-catalog-image
    scp "${SSHOPTS[@]}" "/tmp/odf-catalog-image" "root@${IP}:/home/odf-catalog-image"
    echo "${REDHAT_OPERATORS_INDEX_TAG}" > /tmp/odf-version
    scp "${SSHOPTS[@]}" "/tmp/odf-version" "root@${IP}:/home/odf-version"
    echo "${ODF_OPERATOR_SUB_PACKAGE}" > /tmp/odf-package
    scp "${SSHOPTS[@]}" "/tmp/odf-package" "root@${IP}:/home/odf-package"
    echo "${ODF_OPERATOR_SUB_CHANNEL}" > /tmp/odf-channel
    scp "${SSHOPTS[@]}" "/tmp/odf-channel" "root@${IP}:/home/odf-channel"

    # shellcheck disable=SC2087
    ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
    set -xeo pipefail

    ODF_CATALOG_IMAGE=\$(cat /home/odf-catalog-image)
    ODF_VERSION=\$(cat /home/odf-version)
    ODF_OPERATOR_SUB_PACKAGE=\$(cat /home/odf-package)
    ODF_OPERATOR_SUB_CHANNEL=\$(cat /home/odf-channel)

    echo "1. Get mirror registry"
    mirror_registry=\$(oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]')
    mirror_registry=\${mirror_registry%%/*}
    if [[ \$mirror_registry == "" ]] ; then
        echo "Warning: Can not find the mirror registry, abort !!!"
        exit 1
    fi
    echo "mirror registry is \${mirror_registry}"

    echo "2: get oc-mirror from stable clients"
    if [[ ! -f /home/oc-mirror ]]; then
        MIRROR2URL="https://mirror2.openshift.com/pub/openshift-v4"
        CLIENTURL="\${MIRROR2URL}"/x86_64/clients/ocp/stable
        curl -s -k -L "\${CLIENTURL}/oc-mirror.tar.gz" -o om.tar.gz && tar -C /home -xzvf om.tar.gz && rm -f om.tar.gz
        if ls /home/oc-mirror > /dev/null ; then
            chmod +x /home/oc-mirror
        else
            echo "Warning, can not find oc-mirror abort !!!"
            exit 1
        fi
    fi
    /home/oc-mirror version

    echo "3: skopeo copy docker://\${ODF_CATALOG_IMAGE} oci:///home/odf-local-catalog --remove-signatures"
    skopeo copy "docker://\${ODF_CATALOG_IMAGE}" "oci:///home/odf-local-catalog" --remove-signatures

    echo "4: oc-mirror"
    catalog_image="odf-local-catalog/odf-local-catalog"

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

    cat <<END |tee "/home/imageset-config.yaml"
    kind: ImageSetConfiguration
    apiVersion: mirror.openshift.io/v1alpha2
    storageConfig:
      local:
        path: mirror
    mirror:
      operators:
      - catalog: "oci:///home/odf-local-catalog"
        targetCatalog: \${catalog_image}
        targetTag: "\${ODF_VERSION}"
        packages:
        - name: \${ODF_OPERATOR_SUB_PACKAGE}
          channels:
          - name: \${ODF_OPERATOR_SUB_CHANNEL}
        - name: odf-operator
          channels:
          - name: \${ODF_OPERATOR_SUB_CHANNEL}
        - name: ocs-operator
          channels:
          - name: \${ODF_OPERATOR_SUB_CHANNEL}
        - name: mcg-operator
          channels:
          - name: \${ODF_OPERATOR_SUB_CHANNEL}
        - name: odf-csi-addons-operator
          channels:
          - name: \${ODF_OPERATOR_SUB_CHANNEL}
END

    pushd /home
    # try at least 3 times to be sure to get all the images...
    /home/oc-mirror --config "/home/imageset-config.yaml" docker://\${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
    /home/oc-mirror --config "/home/imageset-config.yaml" docker://\${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
    /home/oc-mirror --config "/home/imageset-config.yaml" docker://\${mirror_registry} --oci-registries-config="/home/registry.conf" --continue-on-error --skip-missing
    popd

    echo "5: Create imageconentsourcepolicy and catalogsource"
    for d in /home/oc-mirror-workspace/results* ; do sed -i "s|name: operator-0\$|name: operator-\${d#/home/oc-mirror-workspace/results-}|g" \${d}/imageContentSourcePolicy.yaml; done
    find /home/oc-mirror-workspace -type d -name '*results*' -exec oc apply -f {}/*.yaml \;

    echo "6: Waiting for the new ImageContentSourcePolicy to be updated on machines"
    oc wait clusteroperators/machine-config --for=condition=Upgradeable=true --timeout=15m
EOF
}




if [[ "${DISCONNECTED}" == "true" ]];
then
    mirror_odf
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

