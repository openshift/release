#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

KUBEVIRT_BASE_DOMAIN="gcp.devcluster.openshift.com"
KUBEVIRT_API_VIP=10.123.124.5
KUBEVIRT_INGRESS_VIP=10.123.124.6
KUBEVIRT_CIDR="10.123.124.0/24"
KUBEVIRT_NAMESPACE=tenantcluster
KUBEVIRT_NETWORK_NAME=mynet
KUBEVIRT_TENANT_STORAGE_CLASS_NAME=standard
KUBEVIRT_VOLUME_ACCESS_MODE=ReadWriteOnce

ssh_pub_key="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDKi+4B9xNPIapfrpP6n1ZGJFBRlLHeeAxAHLrA3vZhANEGGhP79vPCEa61b456/gtJn76lK1M3uvkigbwkL7N9pqC2gjOfSJw4MiKqaA+b2fjBS6w+l5FNhV4f4Pupk+8mrnp/suPTpqJ7oRxftQlawHWr9utSU2X2vYmpPfzbP84a6CsewvFFRLqMYF7WRuvJOrz9ZNX+iOo22gq2tZxhsNvtHMOY3qAXc2et6nvHzqhoFHby7g3MH7DRikS8/qw7KRfyFgMkOIzo0qQUwptsuCdotbTULAtRirRpfdFcQ7+q4jMvzyQ0cPW4sC2J0Qt8e1QHHlEXXL7AMRiHlE9FwuIhvSBWPNqtjHtXPY2C4hEdBuiGzGn8Qm3j7Je6pN3miW+eLJa5y5vA319aTkNnH0kB28L4mPbOXfVjSCnh+shgP/XjwFtZyly5W48JRuA2unmG1vwT6uRONmPUonTfr8nu4Kq/NLI7kg1mFB4T905yER1R71xwx5jBBlvmnbrN1tuBEUE0FPbravpSMqc/In9DnJM/0OyVz+oC1fXzH9t5tbPpF7sLWYZvSC0NfEwZ2nbH7ADMqDAPNW5pbJxoS3CsQADYKWFMjTodGDdlbI8/dRbveus7jbAXiIrALhnGP8cddDWw6JF6hy/8gEeCmSDiIVUcUrZkcGHOfwkcmw== dbarda@redhat.com"
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

#ssh_pub_key=$(<"/tmp/secrets/ssh-public-key")
#pull_secret=$(<"/tmp/secrets/pull-secret")

cat >> "${CONFIG}" << EOF
apiVersion: v1
baseDomain: ${KUBEVIRT_BASE_DOMAIN}
metadata:
  name: ${KUBEVIRT_NAMESPACE}
networking:
  machineNetwork:
  - cidr: ${KUBEVIRT_CIDR}
  serviceNetwork:
  - 172.31.0.0/16
compute:
- name: worker
  platform:
    kubevirt:
      cpu: 4
      memory: 10G
      storageSize: 35Gi
controlPlane:
  name: master
  platform:
    kubevirt:
      cpu: 8
      memory: 16G
      storageSize: 35Gi
platform:
  kubevirt:
    # TODO this section is WIP - see the installer PR
    ingressVIP: ${KUBEVIRT_INGRESS_VIP}
    apiVIP: ${KUBEVIRT_API_VIP}
    namespace: ${KUBEVIRT_NAMESPACE}
    networkName: ${KUBEVIRT_NETWORK_NAME}
    storageClass: ${KUBEVIRT_TENANT_STORAGE_CLASS_NAME}
    persistentVolumeAccessMode: ${KUBEVIRT_VOLUME_ACCESS_MODE}
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF
cat "${CONFIG}"
echo "**************"