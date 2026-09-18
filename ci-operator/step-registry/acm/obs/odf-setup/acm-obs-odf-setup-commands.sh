#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset obsNamespace="${ACM_OBS__NAMESPACE}"
typeset odfNamespace="${ACM_OBS__ODF_NAMESPACE}"
typeset obcStorageClass="${ACM_OBS__OBC_STORAGE_CLASS}"

typeset obcName='obs-noobaa-obc'
typeset thanosSecretName='thanos-object-storage'
typeset mcoCrName='observability'
typeset mcoSaName='mco-e2e-testing-sa'
typeset mcoCrbName='mco-e2e-testing-crb'
typeset mcoTokenSecretName='mco-e2e-testing-sa-token'

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

# shellcheck disable=SC2317
CollectDiagnostics () {
    typeset diagDir="${ARTIFACT_DIR}/acm-obs-odf-setup"
    mkdir -p "${diagDir}"
    oc get multiclusterobservabilities.observability.open-cluster-management.io \
        --all-namespaces --ignore-not-found -o yaml > "${diagDir}/mco.yaml" 2>&1 || true
    oc get pods -n "${obsNamespace}" --ignore-not-found -o wide \
        > "${diagDir}/obs-pods.txt" 2>&1 || true
    oc get obc -n "${odfNamespace}" --ignore-not-found -o yaml \
        > "${diagDir}/obc.yaml" 2>&1 || true
    oc get noobaa -n "${odfNamespace}" --ignore-not-found -o yaml \
        > "${diagDir}/noobaa.yaml" 2>&1 || true
    oc get events -n "${obsNamespace}" --sort-by='.lastTimestamp' \
        > "${diagDir}/obs-events.txt" 2>&1 || true
    true
}
trap CollectDiagnostics EXIT

# ---------------------------------------------------------------------------
# 1. Observability namespace
# ---------------------------------------------------------------------------
oc create namespace "${obsNamespace}" \
    --dry-run=client -o yaml --save-config | oc apply -f -

# ---------------------------------------------------------------------------
# 2. Pull-secret (required by MCO to pull component images)
# ---------------------------------------------------------------------------
typeset tmpDir=''
tmpDir="$(mktemp -d)"

oc extract secret/pull-secret -n openshift-config --to="${tmpDir}" 1>/dev/null
oc create secret generic multiclusterhub-operator-pull-secret \
    -n "${obsNamespace}" \
    --from-file=".dockerconfigjson=${tmpDir}/.dockerconfigjson" \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml --save-config | oc apply -f -

rm -rf "${tmpDir}"

# ---------------------------------------------------------------------------
# 3. ObjectBucketClaim — request a bucket from NooBaa
# ---------------------------------------------------------------------------
jq -cn \
    --arg name "${obcName}" \
    --arg ns "${odfNamespace}" \
    --arg sc "${obcStorageClass}" \
    '{
        apiVersion: "objectbucket.io/v1alpha1",
        kind: "ObjectBucketClaim",
        metadata: {name: $name, namespace: $ns},
        spec: {generateBucketName: "obs-thanos", storageClassName: $sc}
    }' | oc apply -f -

# ---------------------------------------------------------------------------
# 4. Wait for OBC Bound
# ---------------------------------------------------------------------------
oc wait "obc/${obcName}" -n "${odfNamespace}" \
    --for=jsonpath='{.status.phase}'=Bound \
    --timeout=5m 1>/dev/null

# ---------------------------------------------------------------------------
# 5. Extract S3 credentials from the OBC-generated Secret + ConfigMap
# ---------------------------------------------------------------------------
typeset bucketName=''
bucketName="$(oc get "obc/${obcName}" -n "${odfNamespace}" \
    -o jsonpath='{.spec.bucketName}')"

typeset obcSecretName=''
obcSecretName="$(oc get "obc/${obcName}" -n "${odfNamespace}" \
    -o jsonpath='{.spec.secretName}')"
[[ -z "${obcSecretName}" ]] && obcSecretName="${obcName}"

# NooBaa internal S3 endpoint — strip scheme for thanos config.
# NooBaa service exposes HTTP on port 80, HTTPS on port 443.
# Use HTTP (insecure: true) to match the MinIO pattern and avoid TLS cert issues.
typeset s3EndpointRaw=''
s3EndpointRaw="$(oc get noobaa -n "${odfNamespace}" -o json | \
    jq -r '.items[0].status.services.serviceS3.internalDNS[0] // empty')" || true
[[ -z "${s3EndpointRaw}" ]] && s3EndpointRaw="https://s3.${odfNamespace}.svc:443"

typeset s3Host=''
s3Host="$(printf '%s' "${s3EndpointRaw}" | sed -E 's|^https?://||; s|:[0-9]+$||')"

# ---------------------------------------------------------------------------
# 6. Build thanos-object-storage secret — jq marshals credentials safely
# ---------------------------------------------------------------------------
( set +x
    typeset awsAccessKey=''
    awsAccessKey="$(oc get secret "${obcSecretName}" -n "${odfNamespace}" \
        -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)"
    typeset awsSecretKey=''
    awsSecretKey="$(oc get secret "${obcSecretName}" -n "${odfNamespace}" \
        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)"

    typeset thanosFile=''
    thanosFile="$(mktemp)"
    jq -cnr \
        --arg bucket "${bucketName}" \
        --arg endpoint "${s3Host}" \
        --arg accessKey "${awsAccessKey}" \
        --arg secretKey "${awsSecretKey}" \
        '{
            type: "s3",
            config: {
                bucket: $bucket,
                endpoint: $endpoint,
                insecure: true,
                access_key: $accessKey,
                secret_key: $secretKey
            }
        }' | yq -p json -o yaml eval . > "${thanosFile}"

    oc create secret generic "${thanosSecretName}" \
        -n "${obsNamespace}" \
        --from-file="thanos.yaml=${thanosFile}" \
        --dry-run=client -o yaml --save-config | oc apply -f -

    rm -f "${thanosFile}"
true )

# ---------------------------------------------------------------------------
# 7. Apply MultiClusterObservability CR — lean profile
# ---------------------------------------------------------------------------
jq -cn \
    --arg name "${mcoCrName}" \
    --arg secretName "${thanosSecretName}" \
    '{
        apiVersion: "observability.open-cluster-management.io/v1beta2",
        kind: "MultiClusterObservability",
        metadata: {name: $name},
        spec: {
            observabilityAddonSpec: {},
            advanced: {
                receive:     {replicas: 1},
                store:       {replicas: 1},
                query:       {replicas: 1},
                compact:     {},
                alertmanager:{replicas: 1},
                grafana:     {replicas: 1},
                rbacQueryProxy: {replicas: 1}
            },
            storageConfig: {
                alertmanagerStorageSize: "1Gi",
                compactStorageSize:      "1Gi",
                receiveStorageSize:      "1Gi",
                ruleStorageSize:         "1Gi",
                storeStorageSize:        "1Gi",
                metricObjectStorage: {
                    name: $secretName,
                    key:  "thanos.yaml"
                }
            }
        }
    }' | oc apply -f -

# ---------------------------------------------------------------------------
# 8. Wait for MCO Ready
# ---------------------------------------------------------------------------
oc wait multiclusterobservabilities.observability.open-cluster-management.io \
    "${mcoCrName}" \
    --for=condition=Ready \
    --timeout=30m

# ---------------------------------------------------------------------------
# 9. Create test RBAC — mco-e2e-testing-sa + cluster-admin CRB + token Secret
#    The maintained Ginkgo suite needs this SA and bearer token.
# ---------------------------------------------------------------------------

# ServiceAccount
oc create serviceaccount "${mcoSaName}" -n "${obsNamespace}" \
    --dry-run=client -o yaml --save-config | oc apply -f -

# ClusterRoleBinding
jq -cn \
    --arg crbName "${mcoCrbName}" \
    --arg saName "${mcoSaName}" \
    --arg ns "${obsNamespace}" \
    '{
        apiVersion: "rbac.authorization.k8s.io/v1",
        kind: "ClusterRoleBinding",
        metadata: {name: $crbName, labels: {app: "mco-e2e-testing"}},
        roleRef: {kind: "ClusterRole", name: "cluster-admin", apiGroup: "rbac.authorization.k8s.io"},
        subjects: [{kind: "ServiceAccount", name: $saName, namespace: $ns}]
    }' | oc apply -f -

# Token Secret (k8s 1.24+ does not auto-create SA token Secrets)
jq -cn \
    --arg name "${mcoTokenSecretName}" \
    --arg ns "${obsNamespace}" \
    --arg saName "${mcoSaName}" \
    '{
        apiVersion: "v1",
        kind: "Secret",
        metadata: {
            name: $name,
            namespace: $ns,
            annotations: {"kubernetes.io/service-account.name": $saName}
        },
        type: "kubernetes.io/service-account-token"
    }' | oc apply -f -

# Wait for the token controller to populate the Secret
oc wait "secret/${mcoTokenSecretName}" -n "${obsNamespace}" \
    --for=jsonpath='{.data.token}' \
    --timeout=2m 1>/dev/null

# ---------------------------------------------------------------------------
# 10. Write bearer token to SHARED_DIR for downstream steps
# ---------------------------------------------------------------------------
( set +x
    oc get "secret/${mcoTokenSecretName}" -n "${obsNamespace}" \
        -o jsonpath='{.data.token}' | base64 -d \
        > "${SHARED_DIR}/obs-bearer-token"
true )

: 'ACM Observability deployed with ODF NooBaa storage — MCO Ready'

true
