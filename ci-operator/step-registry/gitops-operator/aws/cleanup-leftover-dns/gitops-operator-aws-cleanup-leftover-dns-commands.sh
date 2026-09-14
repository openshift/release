#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# wipe leftover Route53 for this ci-op name
# install fails if the last deprovision left DNS behind

if [[ -z "${BASE_DOMAIN:-}" ]]; then
  echo "BASE_DOMAIN is not set"
  exit 1
fi

if [[ -z "${NAMESPACE:-}" || -z "${UNIQUE_HASH:-}" ]]; then
  echo "NAMESPACE or UNIQUE_HASH is not set"
  exit 1
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ ! -f "${AWS_SHARED_CREDENTIALS_FILE}" ]]; then
  echo "missing ${AWS_SHARED_CREDENTIALS_FILE}"
  exit 1
fi

if [[ -n "${LEASED_RESOURCE:-}" ]]; then
  export AWS_DEFAULT_REGION="${LEASED_RESOURCE}"
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
export CLUSTER_NAME
export BASE_DOMAIN

echo "cleaning leftover Route53 records for ${CLUSTER_NAME}.${BASE_DOMAIN}"

python3 - <<'PY'
import json
import os
import subprocess
import sys

def aws_json(*args):
    proc = subprocess.run(
        ["aws", *args, "--output", "json"],
        check=True,
        capture_output=True,
        text=True,
    )
    if not proc.stdout.strip():
        return {}
    return json.loads(proc.stdout)

def hosted_zone_id_for(dns_name):
    wanted = dns_name if dns_name.endswith(".") else dns_name + "."
    data = aws_json("route53", "list-hosted-zones-by-name", "--dns-name", wanted)
    for zone in data.get("HostedZones", []):
        if zone.get("Name") == wanted:
            return zone["Id"].rsplit("/", 1)[-1]
    return None

def list_record_sets(zone_id):
    records = []
    kwargs = ["route53", "list-resource-record-sets", "--hosted-zone-id", zone_id]
    start = []
    while True:
        data = aws_json(*(kwargs + start))
        records.extend(data.get("ResourceRecordSets", []))
        if not data.get("IsTruncated"):
            return records
        start = [
            "--start-record-name", data["NextRecordName"],
            "--start-record-type", data["NextRecordType"],
        ]
        if "NextRecordIdentifier" in data:
            start += ["--start-record-identifier", data["NextRecordIdentifier"]]

def change_batch_delete(records, skip_apex_ns_soa, zone_name):
    changes = []
    apex = zone_name if zone_name.endswith(".") else zone_name + "."
    for rec in records:
        if skip_apex_ns_soa and rec.get("Name") == apex and rec.get("Type") in ("NS", "SOA"):
            continue
        change = {"Action": "DELETE", "ResourceRecordSet": rec}
        changes.append(change)
    return changes

def submit_deletes(zone_id, changes):
    if not changes:
        return
    for i in range(0, len(changes), 100):
        batch = {"Changes": changes[i:i + 100]}
        subprocess.run(
            [
                "aws", "route53", "change-resource-record-sets",
                "--hosted-zone-id", zone_id,
                "--change-batch", json.dumps(batch),
            ],
            check=True,
        )

def belongs_to_cluster(name, cluster_fqdn):
    return name == cluster_fqdn or name.endswith("." + cluster_fqdn)

base = os.environ["BASE_DOMAIN"].rstrip(".")
cluster = os.environ["CLUSTER_NAME"]
cluster_fqdn = f"{cluster}.{base}."
parent_fqdn = base + "."

parent_id = hosted_zone_id_for(parent_fqdn)
if not parent_id:
    print(f"no public hosted zone found for {parent_fqdn}; nothing to clean")
    sys.exit(0)

child_id = hosted_zone_id_for(cluster_fqdn)
if child_id:
    print(f"deleting leftover hosted zone {cluster_fqdn} ({child_id})")
    child_records = list_record_sets(child_id)
    submit_deletes(child_id, change_batch_delete(child_records, True, cluster_fqdn))
    subprocess.run(["aws", "route53", "delete-hosted-zone", "--id", child_id], check=True)

parent_records = [
    rec for rec in list_record_sets(parent_id)
    if belongs_to_cluster(rec.get("Name", ""), cluster_fqdn)
]
if not parent_records:
    print(f"no leftover records in {parent_fqdn} for {cluster_fqdn}")
    sys.exit(0)

print("deleting leftover parent-zone records:")
for rec in parent_records:
    print(f"  {rec.get('Type')} {rec.get('Name')}")
submit_deletes(parent_id, change_batch_delete(parent_records, False, parent_fqdn))
print("leftover Route53 records removed")
PY
