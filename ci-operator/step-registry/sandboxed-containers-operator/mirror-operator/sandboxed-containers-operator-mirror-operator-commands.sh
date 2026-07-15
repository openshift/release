#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

if test -s "${SHARED_DIR}/proxy-conf.sh"; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1,2)
echo "OCP_VERSION: ${OCP_VERSION}"

if [[ -n "${CATALOG_SOURCE_IMAGE:-}" ]]; then
    OPERATOR_INDEX="${CATALOG_SOURCE_IMAGE}"
    echo "Using Pre-GA catalog: ${OPERATOR_INDEX}"
else
    OPERATOR_INDEX="registry.redhat.io/redhat/redhat-operator-index:v${OCP_VERSION}"
fi
echo "OPERATOR_INDEX: ${OPERATOR_INDEX}"

if [[ -f "${SHARED_DIR}/acr_registry_creds" ]]; then
    mirror_registry_user=$(cut -d: -f1 < "${SHARED_DIR}/acr_registry_creds")
    mirror_registry_password=$(cut -d: -f2 < "${SHARED_DIR}/acr_registry_creds")
    USE_ACR=true
else
    mirror_registry_cred_file="/var/run/vault/mirror-registry/registry_creds"
    mirror_registry_user=$(cut -d: -f1 < "$mirror_registry_cred_file")
    mirror_registry_password=$(cut -d: -f2 < "$mirror_registry_cred_file")
    USE_ACR=false
fi

redhat_auth_user=$(jq -r '.user' /var/run/vault/mirror-registry/registry_redhat.json)
redhat_auth_password=$(jq -r '.password' /var/run/vault/mirror-registry/registry_redhat.json)

work_dir="/tmp/mirror-operator"
mkdir -p "${work_dir}"
export XDG_RUNTIME_DIR="${work_dir}"
export REGISTRY_AUTH_FILE="${XDG_RUNTIME_DIR}/containers/auth.json"
mkdir -p "$(dirname "${REGISTRY_AUTH_FILE}")"

echo "Logging into registries..."
if [[ "${USE_ACR}" == "true" ]]; then
    skopeo login "${MIRROR_REGISTRY_HOST}" -u "${mirror_registry_user}" -p "${mirror_registry_password}"
else
    skopeo login "${MIRROR_REGISTRY_HOST}" -u "${mirror_registry_user}" -p "${mirror_registry_password}" --tls-verify=false
fi
skopeo login registry.redhat.io -u "${redhat_auth_user}" -p "${redhat_auth_password}"

OPERATORS_TO_MIRROR="${OPERATORS_TO_MIRROR:-sandboxed-containers-operator}"

cat > "${work_dir}/imageset-config.yaml" <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: ${OPERATOR_INDEX}
    packages:
EOF

for op in $(echo "${OPERATORS_TO_MIRROR}" | tr ',' ' '); do
    cat >> "${work_dir}/imageset-config.yaml" <<EOF
    - name: ${op}
      channels:
      - name: stable
EOF
done

echo "ImageSetConfiguration:"
cat "${work_dir}/imageset-config.yaml"

DEST_TLS_ARGS=()
if [[ "${USE_ACR}" != "true" ]]; then
    DEST_TLS_ARGS=(--dest-tls-verify=false --src-tls-verify=false)
fi

EXTRA_IMAGES="${EXTRA_IMAGES_TO_MIRROR:-quay.io/openshift/origin-hello-openshift:latest}"
if [[ -n "${EXTRA_IMAGES}" ]]; then
    echo "Mirroring extra images..."
    for img in $(echo "${EXTRA_IMAGES}" | tr ',' ' '); do
        dest_path=$(echo "${img}" | sed 's|.*/||' | sed 's|:.*||')
        dest="docker://${MIRROR_REGISTRY_HOST}/extra/${dest_path}"
        if skopeo inspect "${dest}" "${DEST_TLS_ARGS[@]}" &>/dev/null; then
            echo "  ${dest_path} already mirrored, skipping"
            continue
        fi
        echo "  Copying ${img} -> ${MIRROR_REGISTRY_HOST}/extra/${dest_path}"
        skopeo copy --all \
            "docker://${img}" \
            "${dest}" \
            "${DEST_TLS_ARGS[@]}" || echo "WARNING: failed to copy ${img}"
    done
fi

if [[ -n "${CATALOG_SOURCE_IMAGE:-}" ]]; then
    echo "Mirroring Pre-GA catalog image to local registry..."
    catalog_repo=$(echo "${CATALOG_SOURCE_IMAGE}" | sed 's|:[^/]*$||' | sed 's|@.*||')
    catalog_tag=$(echo "${CATALOG_SOURCE_IMAGE}" | grep -o ':[^/]*$' | sed 's|:||' || echo "latest")
    catalog_dest="${MIRROR_REGISTRY_HOST}/$(echo "${catalog_repo}" | sed 's|[^/]*/||')"
    if skopeo inspect "docker://${catalog_dest}:${catalog_tag}" "${DEST_TLS_ARGS[@]}" &>/dev/null; then
        echo "  Catalog image already mirrored, skipping"
    else
        echo "  Copying ${CATALOG_SOURCE_IMAGE} -> ${catalog_dest}:${catalog_tag}"
        skopeo copy --all \
            "docker://${CATALOG_SOURCE_IMAGE}" \
            "docker://${catalog_dest}:${catalog_tag}" \
            "${DEST_TLS_ARGS[@]}" || echo "WARNING: failed to copy catalog image"
    fi

    echo "Creating ITMS for catalog image..."
    cat <<EOFITMS | oc apply -f - || true
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: pre-ga-catalog-mirror
spec:
  imageTagMirrors:
  - mirrors:
    - ${catalog_dest}
    source: ${catalog_repo}
EOFITMS
fi

if [[ -n "${CATALOG_SOURCE_IMAGE:-}" ]]; then
    # Pre-GA: images exist only in Konflux workspace (quay.io/redhat-user-workloads),
    # not in registry.redhat.io. Use skopeo to copy from Konflux and create IDMS.
    echo "Pre-GA mode: mirroring operator images from Konflux workspace..."

    # Download Konflux ImageMirrorSet to get source->mirror mappings
    konflux_mirror_url="https://raw.githubusercontent.com/openshift/sandboxed-containers-operator/refs/heads/devel/.tekton/images-mirror-set.yaml"
    curl -sL "${konflux_mirror_url}" -o "${work_dir}/konflux-mirror-set.yaml"

    # Get amd64 digest of the FBC image
    echo "Extracting image references from FBC catalog..."
    catalog_arch_digest=$(skopeo inspect --raw "docker://${CATALOG_SOURCE_IMAGE}" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['digest']) for m in d.get('manifests',[]) if m['platform']['architecture']=='amd64']")
    catalog_amd64="${CATALOG_SOURCE_IMAGE%%@*}"
    catalog_amd64="${catalog_amd64%%:*}@${catalog_arch_digest}"

    # Pull FBC image to OCI dir and extract catalog.json
    skopeo copy "docker://${catalog_amd64}" "oci:${work_dir}/fbc-oci" "${DEST_TLS_ARGS[@]}"
    mkdir -p "${work_dir}/fbc-extracted"
    for blob in "${work_dir}"/fbc-oci/blobs/sha256/*; do
        if file "$blob" | grep -q "gzip"; then
            tar -xzf "$blob" -C "${work_dir}/fbc-extracted" 2>/dev/null || true
        fi
    done

    fbc_images=$(grep -rh '"image"' "${work_dir}/fbc-extracted/" 2>/dev/null | \
        grep -o '"image": *"[^"]*"' | sed 's/"image": *"//;s/"//' | grep -v "image/png" | sort -u || true)

    if [[ -z "${fbc_images}" ]]; then
        echo "ERROR: Could not extract images from FBC"
        exit 1
    fi

    echo "Images to mirror from Konflux:"
    echo "${fbc_images}"

    # For each image, find the Konflux source and copy to mirror
    for img in ${fbc_images}; do
        img_repo=$(echo "${img}" | sed 's|@.*||')
        img_digest=$(echo "${img}" | grep -o '@sha256:.*' || echo "")

        if [[ -z "${img_digest}" ]]; then
            continue
        fi

        # Find Konflux mirror from the mirror-set yaml
        konflux_src=$(grep -B3 "source: ${img_repo}" "${work_dir}/konflux-mirror-set.yaml" 2>/dev/null | \
            grep -oE "quay\.io[^ \"]*" | head -1 || echo "")

        if [[ -z "${konflux_src}" ]]; then
            echo "  WARNING: No Konflux mirror for ${img_repo}, skipping"
            continue
        fi

        dest_path=$(echo "${img_repo}" | sed 's|[^/]*/||')
        dest="docker://${MIRROR_REGISTRY_HOST}/${dest_path}"
        if skopeo inspect "${dest}" "${DEST_TLS_ARGS[@]}" &>/dev/null; then
            echo "  ${dest_path} already mirrored, skipping"
            continue
        fi
        echo "  ${konflux_src}${img_digest} -> ${MIRROR_REGISTRY_HOST}/${dest_path}"
        skopeo copy --all \
            "docker://${konflux_src}${img_digest}" \
            "${dest}" \
            "${DEST_TLS_ARGS[@]}" || echo "  WARNING: failed to copy"
    done

    echo "Creating IDMS for operator images..."
    cat <<EOFIDMS | oc apply -f - || true
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: konflux-pre-ga
spec:
  imageDigestMirrors:
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/openshift-sandboxed-containers
    source: registry.redhat.io/openshift-sandboxed-containers
EOFIDMS

    # Mirror Trustee operator images if TRUSTEE_CATALOG_SOURCE_IMAGE is set
    if [[ -n "${TRUSTEE_CATALOG_SOURCE_IMAGE:-}" ]]; then
        echo "Mirroring Trustee operator images..."

        trustee_mirror_url="https://raw.githubusercontent.com/openshift/trustee-fbc/refs/heads/main/.tekton/images-mirror-set.yaml"
        curl -sL "${trustee_mirror_url}" -o "${work_dir}/trustee-mirror-set.yaml"

        # Mirror Trustee FBC catalog image
        trustee_catalog_repo=$(echo "${TRUSTEE_CATALOG_SOURCE_IMAGE}" | sed 's|:[^/]*$||' | sed 's|@.*||')
        trustee_catalog_tag=$(echo "${TRUSTEE_CATALOG_SOURCE_IMAGE}" | grep -o ':[^/]*$' | sed 's|:||' || echo "latest")
        trustee_catalog_dest="${MIRROR_REGISTRY_HOST}/$(echo "${trustee_catalog_repo}" | sed 's|[^/]*/||')"
        if skopeo inspect "docker://${trustee_catalog_dest}:${trustee_catalog_tag}" "${DEST_TLS_ARGS[@]}" &>/dev/null; then
            echo "  Trustee catalog already mirrored, skipping"
        else
            echo "  Copying ${TRUSTEE_CATALOG_SOURCE_IMAGE} -> ${trustee_catalog_dest}:${trustee_catalog_tag}"
            skopeo copy --all \
                "docker://${TRUSTEE_CATALOG_SOURCE_IMAGE}" \
                "docker://${trustee_catalog_dest}:${trustee_catalog_tag}" \
                "${DEST_TLS_ARGS[@]}" || echo "WARNING: failed to copy trustee catalog"
        fi

        # Extract and mirror Trustee operator images from its FBC
        trustee_arch_digest=$(skopeo inspect --raw "docker://${TRUSTEE_CATALOG_SOURCE_IMAGE}" | \
            python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['digest']) for m in d.get('manifests',[]) if m['platform']['architecture']=='amd64']")
        trustee_amd64="${TRUSTEE_CATALOG_SOURCE_IMAGE%%@*}"
        trustee_amd64="${trustee_amd64%%:*}@${trustee_arch_digest}"

        skopeo copy "docker://${trustee_amd64}" "oci:${work_dir}/trustee-fbc-oci" "${DEST_TLS_ARGS[@]}"
        mkdir -p "${work_dir}/trustee-fbc-extracted"
        for blob in "${work_dir}"/trustee-fbc-oci/blobs/sha256/*; do
            if file "$blob" | grep -q "gzip"; then
                tar -xzf "$blob" -C "${work_dir}/trustee-fbc-extracted" 2>/dev/null || true
            fi
        done

        trustee_fbc_images=$(grep -rh '"image"' "${work_dir}/trustee-fbc-extracted/" 2>/dev/null | \
            grep -o '"image": *"[^"]*"' | sed 's/"image": *"//;s/"//' | grep -v "image/png" | sort -u || true)

        if [[ -n "${trustee_fbc_images}" ]]; then
            echo "Trustee images to mirror:"
            echo "${trustee_fbc_images}"
            for img in ${trustee_fbc_images}; do
                img_repo=$(echo "${img}" | sed 's|@.*||')
                img_digest=$(echo "${img}" | grep -o '@sha256:.*' || echo "")
                [[ -z "${img_digest}" ]] && continue
                konflux_src=$(grep -B3 "source: ${img_repo}" "${work_dir}/trustee-mirror-set.yaml" 2>/dev/null | \
                    grep -oE "quay\.io[^ \"]*" | head -1 || echo "")
                [[ -z "${konflux_src}" ]] && { echo "  WARNING: No Konflux mirror for ${img_repo}"; continue; }
                dest_path=$(echo "${img_repo}" | sed 's|[^/]*/||')
                dest="docker://${MIRROR_REGISTRY_HOST}/${dest_path}"
                if skopeo inspect "${dest}" "${DEST_TLS_ARGS[@]}" &>/dev/null; then
                    echo "  ${dest_path} already mirrored, skipping"
                    continue
                fi
                echo "  ${konflux_src}${img_digest} -> ${MIRROR_REGISTRY_HOST}/${dest_path}"
                skopeo copy --all "docker://${konflux_src}${img_digest}" "${dest}" "${DEST_TLS_ARGS[@]}" || echo "  WARNING: failed to copy"
            done
        fi

        echo "Creating IDMS/ITMS for Trustee images..."
        cat <<EOFTIDMS | oc apply -f - || true
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: trustee-pre-ga
spec:
  imageDigestMirrors:
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/build-of-trustee
    source: registry.redhat.io/build-of-trustee
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/confidential-compute-attestation-tech-preview
    source: registry.redhat.io/confidential-compute-attestation-tech-preview
EOFTIDMS

        cat <<EOFTITMS | oc apply -f - || true
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: trustee-catalog-mirror
spec:
  imageTagMirrors:
  - mirrors:
    - ${trustee_catalog_dest}
    source: ${trustee_catalog_repo}
EOFTITMS

        # Mirror kbs-client image (used by install-trustee for KBS validation)
        kbs_client_image="quay.io/confidential-containers/kbs-client:v0.17.0"
        kbs_client_dest="${MIRROR_REGISTRY_HOST}/confidential-containers/kbs-client"
        if skopeo inspect "docker://${kbs_client_dest}:v0.17.0" "${DEST_TLS_ARGS[@]}" &>/dev/null; then
            echo "  kbs-client already mirrored, skipping"
        else
            echo "  Mirroring ${kbs_client_image} -> ${kbs_client_dest}:v0.17.0"
            skopeo copy --all "docker://${kbs_client_image}" "docker://${kbs_client_dest}:v0.17.0" "${DEST_TLS_ARGS[@]}" || echo "WARNING: failed to copy kbs-client"
        fi

        cat <<EOFKBS | oc apply -f - || true
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: kbs-client-mirror
spec:
  imageTagMirrors:
  - mirrors:
    - ${kbs_client_dest}
    source: quay.io/confidential-containers/kbs-client
EOFKBS
    fi

    cs_name="osc-pre-ga"
    echo "${cs_name}" > "${SHARED_DIR}/disconnected_catalog_source_name"

    echo "Creating CatalogSource ${cs_name}..."
    cat <<EOFCS | oc apply -f - || true
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${cs_name}
  namespace: openshift-marketplace
spec:
  displayName: OSC Pre-GA
  image: ${catalog_dest}:${CATALOG_SOURCE_IMAGE##*:}
  publisher: QE
  sourceType: grpc
EOFCS

else
    # GA: use oc-mirror to mirror from official catalog
    # Check if operator index is already mirrored
    mirrored_index="${MIRROR_REGISTRY_HOST}/redhat/redhat-operator-index:v${OCP_VERSION}"
    if skopeo inspect "docker://${mirrored_index}" "${DEST_TLS_ARGS[@]}" &>/dev/null; then
        echo "Operator index v${OCP_VERSION} already mirrored, skipping oc-mirror"

        cs_name="cs-redhat-operator-index-v${OCP_VERSION//./-}"
        echo "${cs_name}" > "${SHARED_DIR}/disconnected_catalog_source_name"

        echo "Applying IDMS and CatalogSource for existing mirror..."
        cat <<EOFIDMS | oc apply -f - || true
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: operator-0
spec:
  imageDigestMirrors:
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/openshift-sandboxed-containers
    source: registry.redhat.io/openshift-sandboxed-containers
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/redhat
    source: registry.redhat.io/redhat
EOFIDMS

        cat <<EOFCS | oc apply -f - || true
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${cs_name}
  namespace: openshift-marketplace
spec:
  displayName: Red Hat Operators (mirrored)
  image: ${mirrored_index}
  publisher: Red Hat
  sourceType: grpc
EOFCS

    else
        echo "oc-mirror version:"
        oc-mirror version --v2 || oc-mirror --v2 version || echo "cannot get version"

        auth_file="${work_dir}/containers/auth.json"
        echo "Running oc-mirror v2 (mirror to mirror)..."
        unset REGISTRY_AUTH_FILE
        oc_mirror_args=(
            -c "${work_dir}/imageset-config.yaml"
            --workspace "file://${work_dir}/workspace"
            --authfile "${auth_file}"
            "docker://${MIRROR_REGISTRY_HOST}"
            --v2
        )
        if [[ "${USE_ACR}" != "true" ]]; then
            oc_mirror_args+=(--dest-tls-verify=false --src-tls-verify=false)
        fi
        oc-mirror "${oc_mirror_args[@]}"

        echo "oc-mirror completed successfully"

        results_dir="${work_dir}/workspace/working-dir/cluster-resources"
        if [[ ! -d "${results_dir}" ]]; then
            results_dir=$(find "${work_dir}" -type d -name "cluster-resources" 2>/dev/null | head -1 || true)
        fi

        echo "Applying generated cluster resources..."
        if [[ -n "${results_dir}" && -d "${results_dir}" ]]; then
            echo "Found cluster-resources at: ${results_dir}"
            ls -la "${results_dir}/"
            for f in "${results_dir}"/*.yaml; do
                if [[ -f "$f" ]]; then
                    echo "=== Applying: $f ==="
                    cat "$f"
                    oc apply -f "$f" || true
                fi
            done
            cs_name=$(grep -l "kind: CatalogSource" "${results_dir}"/*.yaml 2>/dev/null | head -1 | xargs grep "name:" 2>/dev/null | head -1 | awk '{print $2}' || true)
            if [[ -n "${cs_name}" ]]; then
                echo "CatalogSource name: ${cs_name}"
                echo "${cs_name}" > "${SHARED_DIR}/disconnected_catalog_source_name"
            fi
        else
            echo "ERROR: No cluster-resources directory found"
            find "${work_dir}" -type f -name "*.yaml" 2>/dev/null
            exit 1
        fi
    fi
fi

if [[ -n "${EXTRA_IMAGES}" ]]; then
    echo "Creating ITMS for extra images..."
    cat <<EOFITMS | oc apply -f - || true
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: extra-images-mirror
spec:
  imageTagMirrors:
$(for img in $(echo "${EXTRA_IMAGES}" | tr ',' ' '); do
    src_repo=$(echo "${img}" | sed 's|:[^/]*$||')
    dest_path=$(echo "${img}" | sed 's|.*/||' | sed 's|:.*||')
    echo "  - mirrors:"
    echo "    - ${MIRROR_REGISTRY_HOST}/extra/${dest_path}"
    echo "    source: ${src_repo}"
done)
EOFITMS
fi

if [[ "${USE_ACR}" == "true" ]]; then
    echo "Using ACR with valid TLS certs, skipping additionalTrustedCA configuration"
else
    echo "Configuring additional trusted CA for mirror registry..."
    ca_name=$(oc get image.config.openshift.io/cluster -o=jsonpath="{.spec.additionalTrustedCA.name}" 2>/dev/null || echo "")
    if [[ -z "${ca_name}" || "${ca_name}" != "registry-config" ]]; then
        REGISTRY_HOST=$(echo "${MIRROR_REGISTRY_HOST}" | cut -d: -f1)
        QE_ADDITIONAL_CA_FILE="/var/run/vault/mirror-registry/client_ca.crt"

        oc create configmap registry-config \
            --from-file="${REGISTRY_HOST}..5000=${QE_ADDITIONAL_CA_FILE}" \
            -n openshift-config 2>/dev/null || echo "registry-config already exists"

        oc patch image.config.openshift.io/cluster \
            --patch '{"spec":{"additionalTrustedCA":{"name":"registry-config"}}}' \
            --type=merge
        echo "CA trust configured"
    else
        echo "CA trust already configured"
    fi
fi

echo "Disabling default CatalogSources (not mirrored)..."
oc patch operatorhub cluster --type=merge -p '{"spec":{"disableAllDefaultSources":true}}' || true

echo "Waiting for MCP to stabilize..."
sleep 30
oc wait mcp --all --for=condition=Updated --timeout=600s || {
    echo "WARNING: MCP did not finish updating in time"
    oc get mcp || true
}

if [[ -n "${cs_name}" ]]; then
    echo "Waiting for CatalogSource ${cs_name} to be READY..."
    for i in $(seq 1 30); do
        state=$(oc get catalogsource -n openshift-marketplace "${cs_name}" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
        if [[ "${state}" == "READY" ]]; then
            echo "CatalogSource ${cs_name} is READY"
            break
        fi
        echo "  waiting... (${i}/30, state: ${state})"
        sleep 10
    done
    if [[ "${state}" != "READY" ]]; then
        echo "WARNING: CatalogSource ${cs_name} not READY after 5min"
        oc get catalogsource -n openshift-marketplace "${cs_name}" -o yaml || true
        oc get pods -n openshift-marketplace -l "olm.catalogSource=${cs_name}" -o yaml || true
    fi
fi

echo "CatalogSources status:"
oc get catalogsource -n openshift-marketplace || true

echo "Mirror operator step completed successfully"
