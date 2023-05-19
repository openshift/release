#!/bin/bash

set -o nounset

# ------------------------------------------------------------------------------------------------
# Initialize temporary credential on C2S and SC2S regions
# 1. Get credential from temporary credentional provider endpoint provided by SHIFT, 
#    and save it in "${SHARED_DIR}/aws_temp_creds" for openshift-installer use.
#      Endpoints:
#        * C2S: CAP: https://cap.digitalageexperts.com/api/v1/credentials
#        * SC2S: GEOAxIS: https://gxisapi.nga.smil.mil/gxCAP/getTemporaryCredentials
# 2. Generate manifests, cluster will refresh credential from CAP/GEOAxIS every 30 mins
# ------------------------------------------------------------------------------------------------


if [ ! -f "${SHARED_DIR}/proxy-conf.sh" ] || [ ! -f "${SHARED_DIR}/unset-proxy.sh" ]; then
    echo "ERROR, proxy-conf.sh or unset-proxy.sh does not exist, exit now."
    exit 1
fi

REGION="${LEASED_RESOURCE}"

# ------------------------------------------------------------------------------------------------
# 1. Get credential from temporary credentional provider endpoint provided by SHIFT, 
#    and save it in "${SHARED_DIR}/aws_temp_creds" for openshift-installer use.
#      Endpoints:
#        * C2S: CAP: https://cap.digitalageexperts.com/api/v1/credentials
#        * SC2S: GEOAxIS: https://gxisapi.nga.smil.mil/gxCAP/getTemporaryCredentials
# ------------------------------------------------------------------------------------------------
agency="SHIFT"
shift_project_setting="${CLUSTER_PROFILE_DIR}/shift_project_setting.json"
shift_project_name=$(jq -r ".\"${REGION}\".project_name" ${shift_project_setting})
shift_ca_file="${SHARED_DIR}/shift-ca-chain.cert.pem"
cat "${CLUSTER_PROFILE_DIR}/shift-ca-chain.cert.pem" > "${shift_ca_file}"

temp_cred_provider_endpoint=$(jq -r ".\"${REGION}\".temporary_credential_endpoint" ${shift_project_setting})
temp_cred_provider_role=$(jq -r ".\"${REGION}\".cross_account_role" ${shift_project_setting})
temp_cred_provider_cert_b64=$(jq -r ".\"${REGION}\".cert" ${shift_project_setting})
temp_cred_provider_private_key_b64=$(jq -r ".\"${REGION}\".private_key" ${shift_project_setting})

if [ X"${CLUSTER_TYPE}" == X"aws-c2s" ]; then
    # C2S
    temp_cred_request_url="${temp_cred_provider_endpoint}?agency=${agency}&mission=${shift_project_name}&role=${temp_cred_provider_role}"
else
    # SC2S
    temp_cred_request_url="${temp_cred_provider_endpoint}?agency=${agency}&accountName=${shift_project_name}&roleName=${temp_cred_provider_role}"
fi
echo "temp_cred_request_url: $temp_cred_request_url"

echo -n "${temp_cred_provider_cert_b64}" | base64 -d > "${SHARED_DIR}/temp_cred_provider_cert.pem"
echo -n "${temp_cred_provider_private_key_b64}" | base64 -d > "${SHARED_DIR}/temp_cred_provider_private_key.pem"
echo "Start to refresh AWS credential, `date +%H:%M:%S`"

key_id=
key_sec=

try=0
retries=5

temp_cred_file=$(mktemp)

# request credential must be in enmulator env.
source "${SHARED_DIR}/proxy-conf.sh"
while ([ X"${key_id}" == X"" ] || [ X"${key_id}" == X"null" ]) && [ $try -lt $retries ]; do
    echo "tring to get credential from CAP endpoint $(expr $try + 1)/${retries}"
    
    curl -sS "${temp_cred_request_url}" \
            --cert "${SHARED_DIR}/temp_cred_provider_cert.pem" \
            --cacert "${shift_ca_file}" \
            --key "${SHARED_DIR}/temp_cred_provider_private_key.pem" > "${temp_cred_file}"

    key_id=$(cat ${temp_cred_file}  | jq -j .Credentials.AccessKeyId)
    key_sec=$(cat ${temp_cred_file}  | jq -j .Credentials.SecretAccessKey)
    if [ X"${key_id}" == X"" ] || [ X"${key_sec}" == X"" ] || [ X"${key_id}" == X"null" ] || [ X"${key_sec}" == X"null" ]; then
        echo "failed, retry, sleeping 60 seconds"
        try=$(expr $try + 1)
	      sleep 60
    fi
done

source "${SHARED_DIR}/unset-proxy.sh"

if [ X"${key_id}" == X"" ] || [ X"${key_sec}" == X"" ] || [ X"${key_id}" == X"null" ] || [ X"${key_sec}" == X"null" ]; then
    echo "ERROR: can not get AWS credential from CAP"
    exit 2
fi

echo "AWS Credential is ready, writing to \"${SHARED_DIR}/aws_temp_creds\""

cat > "${SHARED_DIR}/aws_temp_creds" <<EOF
[default]
aws_access_key_id     = ${key_id}
aws_secret_access_key = ${key_sec}
EOF


# ------------------------------------------------------------------------------------------------
# 2. Setup token refresh service, cluster will refresh credential from CAP/GEOAxIS every 30 mins
# ------------------------------------------------------------------------------------------------

function create_secret_file()
{
    local ns=$1
    local name=$2
    local car_name=$3
    local key_id=$4
    local key_sec=$5
    cat <<EOF >${SHARED_DIR}/manifest_${ns}_${name}-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: ${name}
  namespace: ${ns}
type: Opaque
stringData:
  role: ${car_name}
  aws_access_key_id: ${key_id}
  aws_secret_access_key: ${key_sec}
  credentials: |
    [default]
    aws_access_key_id = ${key_id}
    aws_secret_access_key = ${key_sec}
EOF
}

function remove_tech_preview_feature_from_manifests()
{
    local path=$1
    local matched=$2
    if [ ! -e ${path} ]; then
        echo "[ERROR] CredentialsRequest manifests ${path} does not exist"
        return 2
    fi
    pushd ${path} || return 1
    for i in *.yaml; do
        match_count=$(grep -c "${matched}" "${i}")
        if [ $match_count -ne 0 ]; then
            echo "[WARN] Remove CredentialsRequest ${i} which is a ${matched} CR"
            rm -f ${i}
            [ $? -ne 0 ] && echo "[ERROR] error remove CredentialsRequest ${i}" && return 1
        fi
    done
    popd || return 1
    return 0
}


# ------------------------------
# create secret files
# ------------------------------

cr_yaml_d=$(mktemp -d)
echo "extracting CR from image $RELEASE_IMAGE_LATEST"

oc adm release extract ${RELEASE_IMAGE_LATEST} --credentials-requests --cloud=aws --to "${cr_yaml_d}" || exit 1

echo "Extracted CR files:"
ls $cr_yaml_d

if [[ "${FEATURE_SET}" != "TechPreviewNoUpgrade" ]] &&  [[ ! -f ${SHARED_DIR}/manifest_feature_gate.yaml ]]; then
  remove_tech_preview_feature_from_manifests "${cr_yaml_d}" "TechPreviewNoUpgrade" || exit 1
fi

credentials_requests_files=`mktemp`
ls ${cr_yaml_d} > ${credentials_requests_files}

echo "CRs to be processed:"
cat "${credentials_requests_files}"

while IFS= read -r item
do
    name=$(yq-go r "${cr_yaml_d}/${item}" 'spec.secretRef.name')
    ns=$(yq-go r "${cr_yaml_d}/${item}" 'spec.secretRef.namespace')
    echo "creating secret file for: \"${ns}\" \"${name}\""
    create_secret_file ${ns} ${name} ${temp_cred_provider_role} ${key_id} ${key_sec}
done < ${credentials_requests_files}

# ------------------------------
# set up token refresh service
# ------------------------------


cat <<EOF > ${SHARED_DIR}/manifest_cap-token-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cap-token-refresh
EOF

cat <<EOF > ${SHARED_DIR}/manifest_cap-token-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cap-token-refresh
rules:
- apiGroups:
  - ""
  resources:
  - secrets
  verbs:
  - get
  - patch
- apiGroups:
  - cloudcredential.openshift.io
  resources:
  - credentialsrequests
  verbs:
  - list
EOF

cat <<EOF > ${SHARED_DIR}/manifest_cap-token-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cap-token-refresh
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cap-token-refresh
subjects:
- kind: ServiceAccount
  name: cap-token-refresh
  namespace: cap-token-refresh
EOF

cat <<EOF > ${SHARED_DIR}/manifest_cap-token-serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cap-token-refresh
  namespace: cap-token-refresh
EOF


ca_file=`mktemp`
cat "${CLUSTER_PROFILE_DIR}/shift-ca-chain.cert.pem" > ${ca_file}
cat "/var/run/vault/mirror-registry/client_ca.crt" >> ${ca_file}
cat <<EOF > ${SHARED_DIR}/manifest_cap-token-certs-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cap-certs
  namespace: cap-token-refresh
type: Opaque
stringData:
  cap.pem: |
`echo -n ${temp_cred_provider_cert_b64} | base64 -d | sed -e 's/^/    /'`
  cap.key: |
`echo -n "${temp_cred_provider_private_key_b64}" | base64 -d | sed -e 's/^/    /'`
  ca-chain.cert.pem: |
`cat ${ca_file} | sed -e 's/^/    /'`
EOF


if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi

registry_host=$(head -n 1 ${SHARED_DIR}/mirror_registry_url)
token_refresh_repo=${registry_host}/yunjiang/cap-token-refresh
cat <<EOF > ${SHARED_DIR}/manifest_cap-token-cronjob.yaml
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: cap-token-refresh
  namespace: cap-token-refresh
spec:
  schedule: "*/30 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: cap-token-refresh
            image: ${token_refresh_repo}
            imagePullPolicy: IfNotPresent
            args:
            - /bin/sh
            - -c
            - |
              readarray -t secrets <<< \\
                "\$(oc get credentialsrequest -A -ojson | \\
                  jq -r '.items[] | select(.spec.providerSpec.kind == "AWSProviderSpec") | .spec.secretRef | .namespace, .name')"
              secret_namespace=""
              secret_name=""
              for i in "\${secrets[@]}"
              do
                if [ -z "\${secret_namespace}" ]
                then
                  secret_namespace="\${i}"
                else
                  secret_name="\${i}"
                  role="\$(oc extract -n \${secret_namespace} secret/\${secret_name} --keys=role --to=-)"
                  if [ \$? -ne 0 ]
                  then
                    echo "Missing \${secret_namespace}/\${secret_name} secret"
                  elif [ -z "\${role}" ]
                  then
                    echo "Missing role in \${secret_namespace}/\${secret_name} secret"
                  else
                    echo "Updating creds in \${secret_namespace}/\${secret_name} secret"
                    curl "${temp_cred_request_url}" \\
                        --cert /etc/cap-certs/cap.pem \\
                        --key /etc/cap-certs/cap.key \\
                        --cacert /etc/cap-certs/ca-chain.cert.pem | \\
                      jq '.Credentials | {"stringData":{"aws_access_key_id":.AccessKeyId,"aws_secret_access_key":.SecretAccessKey,"credentials":("[default]\naws_access_key_id = "+.AccessKeyId+"\naws_secret_access_key = "+.SecretAccessKey+"\n")}}' | \\
                      xargs -0 -I {} oc patch -n \${secret_namespace} secret \${secret_name} -p '{}'
                  fi
                  secret_namespace=""
                  secret_name=""
                fi
              done
            volumeMounts:
            - name: cap-certs
              mountPath: "/etc/cap-certs"
          restartPolicy: OnFailure
          serviceAccountName: cap-token-refresh
          volumes:
          - name: cap-certs
            secret:
              secretName: cap-certs
EOF


cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
rm /tmp/pull-secret

if (( ocp_minor_version >= 12 && ocp_major_version >= 4 )); then
  echo "For 4.12+, using batch API version: batch/v1"
  cat <<EOF > /tmp/cap-token-cronjob_412plus-patch.yaml
apiVersion: batch/v1
EOF
  yq-go m -x -i "${SHARED_DIR}/manifest_cap-token-cronjob.yaml" "/tmp/cap-token-cronjob_412plus-patch.yaml"
fi

echo "files in dir:"
ls ${SHARED_DIR}/
