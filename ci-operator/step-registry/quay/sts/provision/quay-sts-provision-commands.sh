#!/bin/bash
set -euo pipefail
set +x
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_EC2_METADATA_DISABLED=true
python3 - <<'PYTHON'
import json
import os
import pathlib
import re
import subprocess
import time
import uuid
from urllib.parse import urlparse

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

STATE_PATH = pathlib.Path(os.environ['SHARED_DIR']) / 'quay-sts-state.json'
OIDC_ARN_PATH = pathlib.Path(os.environ['SHARED_DIR']) / 'aws_oidc_provider_arn'
os.environ['KUBECONFIG'] = str(pathlib.Path(os.environ['SHARED_DIR']) / 'kubeconfig')


def oc(*args):
    return subprocess.check_output(['oc', '--request-timeout=30s', *args], text=True)


def read_object(resource, name):
    return json.loads(oc('get', resource, name, '-o', 'json'))


def save(state):
    temporary = STATE_PATH.with_suffix('.tmp')
    temporary.write_text(json.dumps(state))
    temporary.replace(STATE_PATH)


if STATE_PATH.exists():
    raise RuntimeError('Previous state exists; complete cleanup before a new run')

cluster_uid = read_object('namespace', 'kube-system')['metadata']['uid']
if not cluster_uid:
    raise RuntimeError('The ephemeral cluster has no kube-system UID')
if read_object('infrastructure', 'cluster')['status']['platformStatus']['type'] != 'AWS':
    raise RuntimeError('The ephemeral cluster must run on AWS')
if read_object('cloudcredential', 'cluster')['spec'].get('credentialsMode') != 'Manual':
    raise RuntimeError('The ephemeral cluster must have CCO Manual mode configured')
issuer = read_object('authentication', 'cluster')['spec'].get('serviceAccountIssuer', '').rstrip('/')
url = urlparse(issuer)
if url.scheme != 'https' or not url.netloc or url.query or url.fragment or url.username:
    raise RuntimeError('The ephemeral cluster must have a valid HTTPS OIDC issuer')

provider_arn = OIDC_ARN_PATH.read_text().strip()
provider_match = re.fullmatch(r'arn:([^:]+):iam::([0-9]{12}):oidc-provider/(.+)', provider_arn)
if not provider_match:
    raise RuntimeError('The IPI STS chain did not provide a valid OIDC provider ARN')
partition, provider_account, provider_issuer = provider_match.groups()
if provider_issuer != issuer.removeprefix('https://'):
    raise RuntimeError('The OIDC provider does not belong to the ephemeral cluster issuer')

region = os.environ.get('QUAY_STS_REGION') or os.environ['LEASED_RESOURCE']
options = Config(connect_timeout=10, read_timeout=30,
                 retries={'mode': 'standard', 'max_attempts': 5})
session = boto3.Session(region_name=region)
identity = session.client('sts', config=options).get_caller_identity()
if identity['Account'] != provider_account or identity['Arn'].split(':')[1] != partition:
    raise RuntimeError('AWS identity does not own the ephemeral cluster OIDC provider')
iam = session.client('iam', config=options)
s3 = session.client('s3', config=options)
provider = iam.get_open_id_connect_provider(OpenIDConnectProviderArn=provider_arn)
if 'openshift' not in provider['ClientIDList']:
    raise RuntimeError('The cluster OIDC provider lacks the openshift audience')

run_id = uuid.uuid4().hex[:16]
name = 'quay-sts-' + run_id
state = dict(account=provider_account, region=region, cluster_uid=cluster_uid,
             run_id=run_id, namespace=name, bucket=name, role=name,
             namespace_created=False, bucket_created=False, role_created=False,
             provider_arn=provider_arn)
save(state)

namespace = json.loads(subprocess.check_output(
    ['oc', '--request-timeout=30s', 'create', '-f', '-', '-o', 'json'],
    input=json.dumps({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {
        'name': name, 'labels': {'quay.redhat.com/sts-ci-run': run_id}}}), text=True))
state['namespace_uid'] = namespace['metadata']['uid']
state['namespace_created'] = True
save(state)

tags = [{'Key': 'quay-sts-run', 'Value': run_id}]
bucket_args = dict(Bucket=name)
if region != 'us-east-1':
    bucket_args['CreateBucketConfiguration'] = {'LocationConstraint': region}
s3.create_bucket(**bucket_args)
state['bucket_created'] = True
save(state)
s3.put_bucket_tagging(Bucket=name, Tagging={'TagSet': tags})
s3.put_public_access_block(Bucket=name, PublicAccessBlockConfiguration=dict(
    BlockPublicAcls=True, IgnorePublicAcls=True, BlockPublicPolicy=True, RestrictPublicBuckets=True))
s3.put_bucket_encryption(Bucket=name, ServerSideEncryptionConfiguration={'Rules': [
    {'ApplyServerSideEncryptionByDefault': {'SSEAlgorithm': 'AES256'}}]})

claim_prefix = issuer.removeprefix('https://')
trust = {'Version': '2012-10-17', 'Statement': [{'Effect': 'Allow',
    'Principal': {'Federated': provider_arn}, 'Action': 'sts:AssumeRoleWithWebIdentity',
    'Condition': {'StringEquals': {claim_prefix + ':aud': 'openshift',
        claim_prefix + ':sub': f'system:serviceaccount:{name}:sts-cco-quay-app'}}}]}
role_args = dict(RoleName=name, AssumeRolePolicyDocument=json.dumps(trust), Tags=tags)
boundary = os.environ.get('QUAY_STS_PERMISSIONS_BOUNDARY', '')
if boundary:
    if not boundary.startswith(f'arn:{partition}:iam::{provider_account}:policy/'):
        raise RuntimeError('Permissions boundary must be a policy in the cluster AWS account')
    role_args['PermissionsBoundary'] = boundary
role = iam.create_role(**role_args)
state['role_created'] = True
state['role_arn'] = role['Role']['Arn']
save(state)

bucket_arn = f'arn:{partition}:s3:::{name}'
policy = {'Version': '2012-10-17', 'Statement': [
    {'Effect': 'Allow', 'Action': ['s3:ListBucket', 's3:GetBucketLocation', 's3:ListBucketMultipartUploads'], 'Resource': bucket_arn},
    {'Effect': 'Allow', 'Action': ['s3:GetObject', 's3:PutObject', 's3:DeleteObject', 's3:AbortMultipartUpload', 's3:ListMultipartUploadParts'], 'Resource': bucket_arn + '/*'}]}
for attempt in range(1, 11):
    try:
        iam.put_role_policy(
            RoleName=name, PolicyName='quay-sts-bucket', PolicyDocument=json.dumps(policy))
        break
    except ClientError as error:
        if error.response['Error']['Code'] != 'NoSuchEntity' or attempt == 10:
            raise
        time.sleep(attempt)
for key, value in {'STS_TEST_NAMESPACE': name, 'STS_S3_BUCKET': name,
                   'STS_S3_REGION': region, 'STS_ROLE_ARN': state['role_arn']}.items():
    (STATE_PATH.parent / key).write_text(value)
print('Prepared run-owned Quay STS resources')
PYTHON
