#!/bin/bash

set -euo pipefail
# The credentials and kubeconfig must not appear in traced CI logs.
set +x
umask 077

state_file="$SHARED_DIR/nutanix_route53_dns_state.json"
if [[ -e "$state_file" ]]; then
  echo "Nutanix Route53 state already exists; clean up the previous attempt before retrying."
  exit 1
fi

credentials=/etc/hypershift-pool-aws-credentials/credentials
if [[ ! -s "$credentials" || ! -s "$SHARED_DIR/cluster-name" ||
      ! -s "$SHARED_DIR/nutanix_context.sh" || ! -s "$SHARED_DIR/kubeconfig" ]]; then
  echo "AWS credentials, HostedCluster name, Nutanix context, or management kubeconfig is missing."
  exit 1
fi
export AWS_SHARED_CREDENTIALS_FILE="$credentials"
export AWS_DEFAULT_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=

cluster=$(<"$SHARED_DIR/cluster-name")
domain=${HYPERSHIFT_BASE_DOMAIN%.}
expected_cluster=$(printf '%s' "${PROW_JOB_ID:?}" | sha256sum | cut -c1-20)
if [[ "$cluster" != "$expected_cluster" || ! "$domain" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ||
      ! "${NUTANIX_QUOTA_SLICE:-}" =~ ^[a-zA-Z0-9-]+$ ]]; then
  echo "The HostedCluster name, base domain, or Nutanix lease is invalid."
  exit 1
fi

# shellcheck source=/dev/null
source "$SHARED_DIR/nutanix_context.sh"
if [[ ! "$INGRESS_VIP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "The Nutanix ingress VIP is not an IPv4 address."
  exit 1
fi

hosted_domain=$(oc --kubeconfig="$SHARED_DIR/kubeconfig" get hostedcluster "$cluster" \
  -n local-cluster -o jsonpath='{.spec.dns.baseDomain}')
if [[ "$hosted_domain" != "$domain" ]]; then
  echo "The HostedCluster base domain does not match the Route53 base domain."
  exit 1
fi

management_ip=$(oc --kubeconfig="$SHARED_DIR/kubeconfig" get nodes \
  -l node-role.kubernetes.io/worker= -o json | jq -r \
  '[.items[].status.addresses[]? | select(.type == "InternalIP") | .address | select(test("^[0-9.]+$"))] | first // empty')
for address in "$management_ip" "$INGRESS_VIP"; do
  if ! awk -F. 'NF == 4 { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1; exit 0 } { exit 1 }' <<<"$address"; then
    echo "A valid management worker IP and Nutanix ingress VIP are required."
    exit 1
  fi
done

zone_json=$(aws route53 list-hosted-zones-by-name --dns-name "$domain" --output json)
zone_id=$(jq -r --arg name "$domain." \
  '[.HostedZones[] | select(.Name == $name and .Config.PrivateZone == false)] |
   if length == 1 then .[0].Id else empty end' <<<"$zone_json")
zone_id=${zone_id##*/}
if [[ -z "$zone_id" ]]; then
  echo "Exactly one public Route53 hosted zone for $domain is required."
  exit 1
fi

owner_hash=$(printf '%s:%s' "$PROW_JOB_ID" "$NUTANIX_QUOTA_SLICE" | sha256sum | cut -c1-32)
records=$(jq -n --arg cluster "$cluster" --arg domain "$domain" \
  --arg management "$management_ip" --arg ingress "$INGRESS_VIP" \
  --arg owner "ci-operator-nutanix-$owner_hash" '
  def a($name; $value): {Name:$name,Type:"A",TTL:60,ResourceRecords:[{Value:$value}]};
  [a("api."+$cluster+"."+$domain+"."; $management),
   a("api-int."+$cluster+"."+$domain+"."; $management),
   a("*.apps."+$cluster+"."+$domain+"."; $ingress),
   {Name:("_ci-operator."+$cluster+"."+$domain+"."),Type:"TXT",TTL:60,
    ResourceRecords:[{Value:("\""+$owner+"\"")}]}]')

jq -n --arg job "$PROW_JOB_ID" --arg lease "$NUTANIX_QUOTA_SLICE" \
  --arg cluster "$cluster" --arg domain "$domain" --arg zone "$zone_id" \
  --argjson records "$records" \
  '{schemaVersion:1,prowJobID:$job,lease:$lease,cluster:$cluster,domain:$domain,
    zoneID:$zone,phase:"prepared",records:$records}' > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

batch_file=$(mktemp)
trap 'rm -f "$batch_file"' EXIT
jq '{Changes:[.records[] | {Action:"CREATE",ResourceRecordSet:.}]}' \
  "$state_file" > "$batch_file"
change_id=$(aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" \
  --change-batch "file://$batch_file" --query ChangeInfo.Id --output text)
jq --arg change "$change_id" '.phase="created" | .changeID=$change' \
  "$state_file" > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"
aws route53 wait resource-record-sets-changed --id "$change_id"
printf 'Created run-owned Route53 records for %s.%s in zone %s.\n' \
  "$cluster" "$domain" "$zone_id"
