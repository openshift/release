#!/bin/bash
set -euo pipefail

[[ ${JOBS2_INSTALL_SLOT:?} == gcp-openshift-gce-devel-ci-2 ]] || { echo "Rehearsal identity or configuration check failed" >&2; exit 1; }
[[ ! -e ${CLUSTER_PROFILE_DIR}/gce.json ]] || { echo "Rehearsal identity or configuration check failed" >&2; exit 1; }
# Each pod gets its own AWS token and temporary gcloud configuration.
# Only scripts and the public federation configuration cross step boundaries.
cat > "${SHARED_DIR}/jobs2-login.sh" <<'LOGIN'
export GOOGLE_PROJECT_ID=openshift-gce-devel-ci-2
export CLOUDSDK_CORE_PROJECT="$GOOGLE_PROJECT_ID"
export CLOUDSDK_CONFIG="$(mktemp -d)"
export AWS_CONFIG_FILE=/var/run/secrets/aws/config/config
export AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1 AWS_PAGER=""
[[ ! -e ${CLUSTER_PROFILE_DIR}/gce.json && -r "$AWS_CONFIG_FILE" ]] || { echo "Rehearsal identity or configuration check failed" >&2; exit 1; }
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
awsdir=$(mktemp -d)
curl -fsSL --retry 3 https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.32.0.zip -o "$awsdir/cli.zip"
echo "2e57ed5587de3789d39841c0f309134ccc13a215af597c7739f7102deca30dad  $awsdir/cli.zip" | sha256sum -c -
python3 -m zipfile -e "$awsdir/cli.zip" "$awsdir"
export JOBS2_AWS="$awsdir/aws/dist/aws"
chmod +x "$JOBS2_AWS"
caller=$("$JOBS2_AWS" sts get-caller-identity --profile hub --query Arn --output text)
[[ "$caller" == arn:aws:sts::320297955214:assumed-role/ci-step-runner-hub/* ]] || { echo "Rehearsal identity or configuration check failed" >&2; exit 1; }
gcloud iam workload-identity-pools create-cred-config \
  projects/263120870185/locations/global/workloadIdentityPools/ci-aws-pilot/providers/aws-ci-hub \
  --aws --service-account=ci-provisioner-2@openshift-gce-devel-ci-2.iam.gserviceaccount.com \
  --output-file="$CLOUDSDK_CONFIG/jobs2.json"
export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$CLOUDSDK_CONFIG/jobs2.json"
export GOOGLE_APPLICATION_CREDENTIALS="$CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE"
# Obtain fresh hub credentials per gcloud invocation without putting secrets
# in shell traces, process arguments, or the shared step directory.
export JOBS2_GCLOUD="$(command -v gcloud)"
mkdir "$awsdir/bin"
cat > "$awsdir/bin/gcloud" <<'PY'
#!/usr/bin/env python3
import json
import os
import subprocess
import sys

creds = json.loads(subprocess.check_output([
    os.environ["JOBS2_AWS"], "configure", "export-credentials", "--profile", "hub",
]))
os.environ.update(AWS_ACCESS_KEY_ID=creds["AccessKeyId"],
                  AWS_SECRET_ACCESS_KEY=creds["SecretAccessKey"],
                  AWS_SESSION_TOKEN=creds["SessionToken"])
os.execv(os.environ["JOBS2_GCLOUD"], ["gcloud", *sys.argv[1:]])
PY
chmod +x "$awsdir/bin/gcloud"
export PATH="$awsdir/bin:$PATH"
jobs2_ssh_source() {
  local ip
  ip=$(curl -fsS --retry 3 https://checkip.amazonaws.com) || return 1
  python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.IPv4Address(sys.argv[1]).is_global else 1)' "$ip" || return 1
  printf '%s/32\n' "$ip"
}
LOGIN

source "${SHARED_DIR}/jobs2-login.sh"
prefix="${NAMESPACE}-${UNIQUE_HASH}"
[[ "$prefix" =~ ^ci-op-[a-z0-9-]+$ ]] || { echo "Rehearsal identity or configuration check failed" >&2; exit 1; }
# Arm cleanup only after confirming that the names are unused.
cat > "${SHARED_DIR}/jobs2-resources.sh" <<'RESOURCES'
vm_zones() { gcloud compute instances list --filter="name=('${prefix}-buildhost')" --format='value(zone.basename())'; }
firewalls() { gcloud compute firewall-rules list --filter="name=('${prefix}-buildhost-ingress-allow')" --format='value(name)'; }
deployments() { gcloud deployment-manager deployments list --filter="name=('${prefix}-vpc')" --format='value(name)'; }
networks() { gcloud compute networks list --filter="name=('${prefix}-network')" --format='value(name)'; }
RESOURCES
source "${SHARED_DIR}/jobs2-resources.sh"
for query in vm_zones firewalls deployments networks; do
  existing=$("$query")
  [[ -z "$existing" ]] || { echo "A resource already exists for $prefix"; exit 1; }
done
printf '%s\n' "$prefix" > "${SHARED_DIR}/jobs2-prefix"
