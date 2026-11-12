#!/bin/bash

set -euo pipefail
# Keep credentials and kubeconfig paths out of traced CI logs.
set +x
umask 077

state_file="$SHARED_DIR/nutanix_route53_dns_state.json"
if [[ ! -e "$state_file" ]]; then
  echo "No run-owned Nutanix Route53 records were attempted."
  exit 0
fi
if [[ ! -s "$state_file" ]]; then
  echo "Nutanix Route53 state is empty; retaining it for investigation."
  exit 1
fi

if [[ ! -s "$SHARED_DIR/cluster-name" ]]; then
  echo "The HostedCluster name is missing; retaining Route53 state."
  exit 1
fi
cluster=$(<"$SHARED_DIR/cluster-name")
expected_cluster=$(printf '%s' "${PROW_JOB_ID:?}" | sha256sum | cut -c1-20)
owner_hash=$(printf '%s:%s' "$PROW_JOB_ID" "${NUTANIX_QUOTA_SLICE:-}" | sha256sum | cut -c1-32)
if [[ "$cluster" != "$expected_cluster" ]] || ! jq -e \
  --arg job "$PROW_JOB_ID" --arg lease "${NUTANIX_QUOTA_SLICE:-}" \
  --arg cluster "$cluster" --arg owner "\"ci-operator-nutanix-$owner_hash\"" '
    .schemaVersion == 1 and .prowJobID == $job and .lease == $lease and
    .cluster == $cluster and (.domain | test("^[a-z0-9][a-z0-9.-]*[a-z0-9]$")) and
    (.zoneID | test("^[A-Z0-9]+$")) and (.records | length == 4) and
    .records[0].Name == ("api."+$cluster+"."+.domain+".") and
    .records[1].Name == ("api-int."+$cluster+"."+.domain+".") and
    .records[2].Name == ("*.apps."+$cluster+"."+.domain+".") and
    .records[3].Name == ("_ci-operator."+$cluster+"."+.domain+".") and
    [.records[].Type] == ["A","A","A","TXT"] and
    all(.records[]; .TTL == 60 and (.ResourceRecords | length == 1)) and
    .records[3].ResourceRecords[0].Value == $owner and
    (.phase == "prepared" or .phase == "created")
  ' "$state_file" >/dev/null; then
  echo "The Nutanix Route53 state does not match this run; retaining it."
  exit 1
fi

credentials=/etc/hypershift-pool-aws-credentials/credentials
if [[ ! -s "$credentials" ]]; then
  echo "The pool AWS credentials are unavailable; retaining Route53 state."
  exit 1
fi
export AWS_SHARED_CREDENTIALS_FILE="$credentials"
export AWS_DEFAULT_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=

domain=$(jq -r '.domain' "$state_file")
zone_id=$(jq -r '.zoneID' "$state_file")
zone_json=$(aws route53 list-hosted-zones-by-name --dns-name "$domain" --output json)
if ! jq -e --arg name "$domain." --arg zone "/hostedzone/$zone_id" \
  'any(.HostedZones[]; .Name == $name and .Id == $zone and .Config.PrivateZone == false)' \
  <<<"$zone_json" >/dev/null; then
  echo "The recorded public Route53 zone does not match the run; retaining state."
  exit 1
fi

# Route53 returns wildcard names escaped as \052. Compare a normalized copy, but use
# the actual returned record set in the DELETE request so every field matches exactly.
zone_records=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json)
present='[]'
marker_found=false
while IFS= read -r expected; do
  name=$(jq -r '.Name' <<<"$expected")
  type=$(jq -r '.Type' <<<"$expected")
  matches=$(jq -c --arg name "$name" --arg type "$type" '
    [.ResourceRecordSets[] | select((.Name | gsub("\\\\052"; "*") | ascii_downcase) ==
      ($name | ascii_downcase) and .Type == $type)]' <<<"$zone_records")
  count=$(jq 'length' <<<"$matches")
  if (( count > 1 )); then
    echo "Multiple Route53 record sets match $name; retaining state."
    exit 1
  fi
  if (( count == 0 )); then
    continue
  fi
  actual=$(jq -c '.[0]' <<<"$matches")
  normalized=$(jq -c '.Name |= gsub("\\\\052"; "*")' <<<"$actual")
  if [[ "$(jq -Sc . <<<"$normalized")" != "$(jq -Sc . <<<"$expected")" ]]; then
    echo "Route53 record $name changed; refusing to delete it."
    exit 1
  fi
  if [[ "$type" == TXT ]]; then marker_found=true; fi
  present=$(jq -c --argjson record "$actual" '. + [$record]' <<<"$present")
done < <(jq -c '.records[]' "$state_file")

if [[ "$marker_found" == false ]]; then
  if [[ "$(jq 'length' <<<"$present")" != 0 ]]; then
    echo "The Route53 ownership marker is absent while A records remain; retaining state."
    exit 1
  fi
  rm -f "$state_file"
  echo "Run-owned Nutanix Route53 records are already absent."
  exit 0
fi

batch_file=$(mktemp)
trap 'rm -f "$batch_file"' EXIT
jq -n --argjson records "$present" \
  '{Changes:[$records[] | {Action:"DELETE",ResourceRecordSet:.}]}' > "$batch_file"
change_id=$(aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" \
  --change-batch "file://$batch_file" --query ChangeInfo.Id --output text)
aws route53 wait resource-record-sets-changed --id "$change_id"

remaining=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json)
if ! jq -e --argjson records "$(jq '.records' "$state_file")" '
  [.ResourceRecordSets[] |
   {Name:(.Name | gsub("\\\\052"; "*")),Type}] as $actual |
  all($records[]; . as $wanted |
    all($actual[]; .Name != $wanted.Name or .Type != $wanted.Type))
' <<<"$remaining" >/dev/null; then
  echo "Run-owned Route53 records still exist after deletion; retaining state."
  exit 1
fi
rm -f "$state_file"
printf 'Removed run-owned Route53 records for %s.%s.\n' "$cluster" "$domain"
