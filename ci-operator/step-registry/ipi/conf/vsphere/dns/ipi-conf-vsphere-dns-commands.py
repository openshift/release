#!/usr/bin/env python

"""Module providing DNS record creation via AWS Route53 for vSphere"""

import os
import random
import sys
import logging
import json
import copy
import time

import boto3
from botocore.config import Config

try:
    from pylint.lint import Run

    file_path = os.path.realpath(__file__)
    Run([file_path], exit=False)
except ImportError:
    print("linter not available, run outside of CI")

# This step uses:
# https://github.com/openshift-splat-team/vsphere-ci-images
# https://github.com/openshift/release/pull/57722
# https://quay.io/repository/ocp-splat/vsphere-ci-python

logging.basicConfig(
    format='%(asctime)s %(levelname)s [%(filename)s:%(lineno)d] %(message)s',
    level=logging.INFO)
logger = logging.getLogger()


def setup_aws_client():
    """configures and creates the boto3 client"""
    logger.info("Connecting to AWS via boto3")
    os.environ.setdefault("AWS_SHARED_CREDENTIALS_FILE", "/var/run/vault/vsphere/.awscred")
    config = Config(
        region_name = 'us-west-2',
        retries = {
            'max_attempts': 50,
            'mode': 'adaptive'
        }
    )

    client = None
    try:
        client = boto3.client('route53', config=config)
        logger.info("Connected to AWS")
    except Exception as e:
        logger.error(e)
        sys.exit(1)

    return client

def get_hosted_zone_id(boto3_client, base_domain):
    """returns the HostedZone Id for the base domain"""
    logger.info(f"Retrieving the Hosted Zone ID for {base_domain}")

    try:
        response = boto3_client.list_hosted_zones_by_name(DNSName=base_domain)
    except Exception as e:
        logger.error(e)

    for hz in response['HostedZones']:
        if not hz['Config']['PrivateZone']:
            if hz['Name'] == f"{base_domain}.":
                logger.info(f"Found Hosted Zone ID {hz['Id']} for {base_domain}")
                return hz['Id']


def change_resource_sets_and_wait(boto3_client, hosted_zone_id, change_batch):
    """change resource record sets and wait with backoff"""
    delay = 1
    max_retries = 50
    response = boto3_client.change_resource_record_sets(
        HostedZoneId=hosted_zone_id,
        ChangeBatch=change_batch
    )
    change_id = response['ChangeInfo']['Id']

    for attempt in range(max_retries):
        logger.info(f"attempt {attempt} out of {max_retries}")
        change_status = {}
        try:
            change_status_response = boto3_client.get_change(Id=change_id)
            change_status = change_status_response['ChangeInfo']['Status']
        except Exception as e:
            logger.error(e)

        if change_status == 'INSYNC':
            logger.info("DNS records created")
            return

        time.sleep(delay)
        delay *= 2
        delay += random.uniform(0,1)


def main():
    cluster_profile_name = os.environ.get("CLUSTER_PROFILE_NAME")
    leased_resource = os.environ.get("LEASED_RESOURCE")
    shared_dir = os.environ.get("SHARED_DIR")
    job_name_safe = os.environ.get("JOB_NAME_SAFE")

    if cluster_profile_name is None:
        logger.critical("CLUSTER_PROFILE_NAME is undefined")
        sys.exit(1)
    if leased_resource is None:
        logger.critical("failed to acquire lease")
        sys.exit(1)
    if job_name_safe is None:
        logger.critical("JOB_NAME_SAFE is undefined")
        sys.exit(1)

    vsphere_additional_cluster = os.environ.get("VSPHERE_ADDITIONAL_CLUSTER", "false")

    base_domain = "vmc-ci.devcluster.openshift.com"
    with open(f"{shared_dir}/basedomain.txt", "w") as base_domain_file:
        logger.info(f"base_domain: {base_domain}")
        base_domain_file.write(f"{base_domain}")

    namespace = os.environ.get("NAMESPACE")
    unique_name = os.environ.get("UNIQUE_HASH")
    cluster_name = f"{namespace}-{unique_name}"
    cluster_domain = f"{cluster_name}.{base_domain}"

    with open(f"{shared_dir}/vips.txt", "r") as vip_file:
        vips = vip_file.readlines()

    min_vips = 4 if vsphere_additional_cluster == "true" else 2
    if len(vips) < min_vips:
        logger.critical(f"reading vips.txt resulted in {len(vips)} vips, need at least {min_vips}, exiting")
        sys.exit(1)

    # empty change dictionary for batch and change_resource_record_sets
    change = {
        'Action': 'UPSERT',
        'ResourceRecordSet': {
            'Name': '',
            'TTL': 60,
            'Type': '',
            'ResourceRecords': []
        },
    }

    upsert_change_batch = {
        'Comment': 'Create public OpenShift DNS records for vSphere CI install',
        'Changes': []
    }

    # the list of OCP cluster DNS records that are needed to install the cluster
    # api.<cluster_domain>
    # *.apps.<cluster_domain> wildcard
    resource_names = [f"api.{cluster_domain}", f"*.apps.{cluster_domain}"]

    # When VSPHERE_ADDITIONAL_CLUSTER is true, add spoke cluster DNS records
    # and write additional_cluster.sh for downstream consumers (e.g. hive e2e)
    if vsphere_additional_cluster == "true":
        additional_cluster_name = f"hive-{cluster_name}-spoke"
        additional_cluster_domain = f"{additional_cluster_name}.{base_domain}"
        resource_names.append(f"api.{additional_cluster_domain}")
        resource_names.append(f"*.apps.{additional_cluster_domain}")

        with open(f"{shared_dir}/additional_cluster.sh", "w") as ac_file:
            ac_file.write(f"export ADDITIONAL_CLUSTER_NAME={additional_cluster_name}\n")
            ac_file.write(f"export ADDITIONAL_CLUSTER_API_VIP={vips[2].strip()}\n")
            ac_file.write(f"export ADDITIONAL_CLUSTER_INGRESS_VIP={vips[3].strip()}\n")
        logger.info(f"wrote additional_cluster.sh for spoke {additional_cluster_name}")

    # Windows nodes _still_ require api-int.<cluster_domain>
    # This _should_ _not_ be here as we are not properly testing
    # static pod coredns
    api_int_change = copy.deepcopy(change)
    api_int_change['ResourceRecordSet']['Name'] = f"api-int.{cluster_domain}"
    api_int_change['ResourceRecordSet']['Type'] = 'A'
    api_int_change['ResourceRecordSet']['ResourceRecords'].append({'Value': vips[0].strip()})
    upsert_change_batch['Changes'].append(api_int_change)

    # loop through FQDN DNS records to generate change batches
    for i, rn in enumerate(resource_names):
        temp_change = copy.deepcopy(change)
        temp_change['ResourceRecordSet']['Name'] = rn

        if "launch" in job_name_safe:
            temp_change['ResourceRecordSet']['Type'] = 'CNAME'
            temp_change['ResourceRecordSet']['ResourceRecords'].append(
                {'Value': "vsphere-clusterbot-2284482-dal12.clb.appdomain.cloud"}
            )
        else:
            temp_change['ResourceRecordSet']['Type'] = 'A'
            temp_change['ResourceRecordSet']['ResourceRecords'].append({'Value': vips[i].strip()})

        upsert_change_batch['Changes'].append(temp_change)

    logger.info("Generated Change Resource Record Sets...")
    print(json.dumps(upsert_change_batch,indent=4,ensure_ascii=False))

    boto3_client = setup_aws_client()
    hosted_zone_id = get_hosted_zone_id(boto3_client,base_domain)
    change_resource_sets_and_wait(boto3_client,hosted_zone_id,upsert_change_batch)

if __name__ == '__main__':
    main()
