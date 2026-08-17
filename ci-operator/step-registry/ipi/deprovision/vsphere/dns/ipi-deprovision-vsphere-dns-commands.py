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

    base_domain = "vmc-ci.devcluster.openshift.com"
    namespace = os.environ.get("NAMESPACE")
    unique_name = os.environ.get("UNIQUE_HASH")
    cluster_name = f"{namespace}-{unique_name}"
    cluster_domain = f"{cluster_name}.{base_domain}"

    with open(f"{shared_dir}/vips.txt", "r") as vip_file:
        vips = vip_file.readlines()

    if len(vips) < 2:
        logger.critical("reading vips.txt resulted in a list less than 2, exiting")
        sys.exit(1)

    # empty change dictionary for batch and change_resource_record_sets
    change = {
        'Action': 'DELETE',
        'ResourceRecordSet': {
            'Name': '',
            'TTL': 60,
            'Type': '',
            'ResourceRecords': []
        },
    }

    delete_change_batch = {
        'Comment': 'Delete public OpenShift DNS records for vSphere CI install',
        'Changes': []
    }

    # the list of OCP cluster DNS records that are needed to install the cluster
    # api.<cluster_domain>
    # *.apps.<cluster_domain> wildcard
    resource_names = [f"api.{cluster_domain}", f"*.apps.{cluster_domain}"]

    # Windows nodes _still_ require api-int.<cluster_domain>
    # This _should_ _not_ be here as we are not properly testing
    # static pod coredns
    api_int_change = copy.deepcopy(change)
    api_int_change['ResourceRecordSet']['Name'] = f"api-int.{cluster_domain}"
    api_int_change['ResourceRecordSet']['Type'] = 'A'
    api_int_change['ResourceRecordSet']['ResourceRecords'].append({'Value': vips[0].strip()})
    delete_change_batch['Changes'].append(api_int_change)

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

        delete_change_batch['Changes'].append(temp_change)

    logger.info("Generated Change Resource Record Sets...")
    print(json.dumps(delete_change_batch,indent=4,ensure_ascii=False))

    boto3_client = setup_aws_client()
    hosted_zone_id = get_hosted_zone_id(boto3_client,base_domain)
    change_resource_sets_and_wait(boto3_client,hosted_zone_id,delete_change_batch)

if __name__ == '__main__':
    main()
