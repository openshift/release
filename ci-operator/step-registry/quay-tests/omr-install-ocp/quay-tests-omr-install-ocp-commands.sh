#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#check versions
oc version || true
openshift-install version || true
which openshift-install || true

#Check AWS CLI
AWS_ACCESS_KEY_ID=$(cat /var/run/quay-qe-omr-secret/access_key) && export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$(cat /var/run/quay-qe-omr-secret/secret_key) && export AWS_SECRET_ACCESS_KEY
AWS_DEFAULT_REGION="us-west-2" && export AWS_DEFAULT_REGION
aws s3 ls

cat "${SHARED_DIR}/new_pull_secret" | jq
cat "${SHARED_DIR}/local_registry_icsp_file.yaml"
OMR_HOST_NAME=$(cat ${SHARED_DIR}/OMR_HOST_NAME)
OCP_NAME="omrocpprowci$RANDOM"

echo ${OMR_HOST_NAME}
echo ${OCP_NAME}

cat >> ${SHARED_DIR}/install-config.yaml << EOF
apiVersion: v1
baseDomain: qe.devcluster.openshift.com 
credentialsMode: Mint
controlPlane:   
  hyperthreading: Enabled 
  name: master
  platform:
    aws:
      zones:
      - us-west-2a
      - us-west-2b
      rootVolume:
        iops: 4000
        size: 500
        type: io1 
      type: m4.2xlarge
  replicas: 
compute: 
- hyperthreading: Enabled 
  name: worker
  platform:
    aws:
      rootVolume:
        iops: 2000
        size: 500
        type: io1 
      type: m4.2xlarge
      zones:
      - us-west-2c
  replicas: 3
metadata:
  name: ${OCP_NAME}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: us-west-2
    userTags:
      adminContact: luffy
      costCenter: 7536
fips: false 
sshKey: ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDN8nUzLnPHq9o6Crika8brT4i5CL0a0azoHJoHe02BH8/vgDyhgHin+1qDrHA414t6smDIhYRM/L503J0kD2/jUTPVqeFNmbxbzXnEXWv2RaAyKChMzw2PkrKiLntY4CxcukdSN6lqtJa8TH3/Vmy/YUOMJOKWEsYkg6qojDWPYbFHMubm6JWPydiEJJYPYCH7tHPaq4Y3CWNw+jx2sL69Sltnsdc/oj5Icl+u/ClF7lm0LPXkrkUF745ktCg6r06dLju3Ap+A0HJ/doTpCymZrt88eEy0RqW9koDYPJsRm380caT0J4wux3HlZiHP0b1mhx9pp7DB0FuhZHxeQawGs4V3aYDisBE27YMoMBqoCmBOqkVqC7uY47HOYiS15YHpriCXSnflE628e6a7zfFVV+CcrcqtcqPltZlXmbm2PeQY547VphB1nivinALOVM+CcSgOchX1Phmj63nXKt/IbsUJhUnZQicFhh2bJzXWKBtCQkodwTnu90RaKJN2pn8= lizhang@lzha-mac 
pullSecret: '{"auths":{"${OMR_HOST_NAME}:8443": {"auth": "cXVheTpwYXNzd29yZA==","email": "lzha@redhat.com"}, "registry.ci.openshift.org": {"auth": "dXNlcm5hbWUtdW51c2VkOmV5SmhiR2NpT2lKU1V6STFOaUlzSW10cFpDSTZJa0Z3U3pBdGIwWjRiVzFGVEV0R01TMDBVRGt3Y2xBMFEyVkJUVGRETTBkV1JGcHZiRjlZZWkxRFFuTWlmUS5leUpwYzNNaU9pSnJkV0psY201bGRHVnpMM05sY25acFkyVmhZMk52ZFc1MElpd2lhM1ZpWlhKdVpYUmxjeTVwYnk5elpYSjJhV05sWVdOamIzVnVkQzl1WVcxbGMzQmhZMlVpT2lKeFpTSXNJbXQxWW1WeWJtVjBaWE11YVc4dmMyVnlkbWxqWldGalkyOTFiblF2YzJWamNtVjBMbTVoYldVaU9pSmpZMmt0YW1WdWEybHVjeTEwYjJ0bGJpMXRjbU15WnlJc0ltdDFZbVZ5Ym1WMFpYTXVhVzh2YzJWeWRtbGpaV0ZqWTI5MWJuUXZjMlZ5ZG1salpTMWhZMk52ZFc1MExtNWhiV1VpT2lKalkya3RhbVZ1YTJsdWN5SXNJbXQxWW1WeWJtVjBaWE11YVc4dmMyVnlkbWxqWldGalkyOTFiblF2YzJWeWRtbGpaUzFoWTJOdmRXNTBMblZwWkNJNklqTmlZMlZoWkdVNUxUQXdORGN0TkdWaU1pMDRZakUyTFRBNE9UUmtNbU01TnpWaVlpSXNJbk4xWWlJNkluTjVjM1JsYlRwelpYSjJhV05sWVdOamIzVnVkRHB4WlRwalkya3RhbVZ1YTJsdWN5SjkueF82T2diTk83eDFnX0lIXzhqWF9BUkRVVXptZ2tUb0xELWI2YWw1UDZYZnJMRXBJR3dUblpOalcyMDVCS3F1bGtzSXZrMTZaRkJScHFNaTcxaW9YVzZYaEd3RjE5WUdCcnpaZXd1N1AwdWdwUDMteGY0TWhZVUUwZk9IWlVqTkI1UEhMb09lUDRia1ZlVXFqa0lKVDRMQUpYZE1OZGlacHJORjFmV2JoamxJVk5LcndpSlFfTlF6ajI0cG1rRlI0NGhfSks0cVc2Y096UGQyOVRnOTJTQXhfd1UtZEdiZ1lQTkZyWGE5emo4bXpqdEs2VHZXczQwVlFrQ0FIOXFydWxMMjhSeF92VEhSZUZMYWEyNGR0TDBHWVdsLTc0dGN1WGdwYng5clFldThtY0dvNzJKRTVxSlBGZTBOczBxamtNaVZjMmNNaGxNOWU3VV85T2ZqdXh3","email": "lzha@redhat.com"}}}'
additionalTrustBundle: |
$(cat "${SHARED_DIR}/rootCA.pem" | awk '{print "    "$0}')
$(cat "${SHARED_DIR}/install-config-mirrors")
EOF

cat "${SHARED_DIR}/install-config.yaml"

cp "${SHARED_DIR}/install-config.yaml" /tmp
openshift-install --dir=/tmp create cluster --log-level=debug || true
ls /tmp

cp "${SHARED_DIR}/install-config.yaml" /tmp
openshift-install --dir=/tmp desttroy cluster --log-level=debug || true


