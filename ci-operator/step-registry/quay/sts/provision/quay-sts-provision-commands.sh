#!/bin/bash
set -euo pipefail
set +x
export KUBECONFIG=/var/run/quay-qe-cluster/kubeconfig
python3 - <<'PYTHON'
import json
import os
import pathlib
import re
import subprocess

STATE_PATH = pathlib.Path(os.environ['SHARED_DIR']) / 'quay-sts-state.json'
CLUSTER_CREDENTIAL = pathlib.Path('/var/run/quay-qe-cluster')
os.environ['KUBECONFIG'] = str(CLUSTER_CREDENTIAL / 'kubeconfig')

def oc(*args):
    return subprocess.check_output(['oc', '--request-timeout=30s', *args], text=True)

def read_object(resource, name, namespace=None):
    args = ['get', resource, name, '-o', 'json']
    if namespace:
        args += ['-n', namespace]
    return json.loads(oc(*args))

def verify_cluster():
    expected = (CLUSTER_CREDENTIAL / 'cluster_uid').read_text().strip()
    actual = read_object('namespace', 'kube-system')['metadata']['uid']
    if not expected or actual != expected:
        raise RuntimeError('QE cluster identity mismatch; refusing to change resources')
    return actual

def save(state):
    temporary = STATE_PATH.with_suffix('.tmp')
    temporary.write_text(json.dumps(state))
    temporary.replace(STATE_PATH)

def load_state(cluster_uid):
    state = json.loads(STATE_PATH.read_text())
    run_id = state['run_id']
    if not re.fullmatch(r'[a-f0-9]{16}', run_id):
        raise RuntimeError('Invalid run identity')
    name = 'quay-sts-' + run_id
    if any(state[key] != name for key in ('namespace', 'bucket', 'role')):
        raise RuntimeError('Unexpected resource names in state')
    if state['cluster_uid'] != cluster_uid:
        raise RuntimeError('State belongs to another cluster')
    return state

def verify_namespace(state):
    namespace = read_object('namespace', state['namespace'])
    metadata = namespace['metadata']
    if (metadata['uid'] != state['namespace_uid'] or
            metadata.get('labels', {}).get('quay.redhat.com/sts-ci-run') != state['run_id']):
        raise RuntimeError('Namespace is not owned by this run')
    return namespace
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

# Explicit credentials: never use a worker-node role or the cluster profile.
credential_dir = pathlib.Path('/var/run/quay-dev-aws')
expected_account = (credential_dir / 'account_id').read_text().strip()
if not re.fullmatch(r'[0-9]{12}', expected_account):
    raise RuntimeError('DEV account_id must be a confirmed 12-digit account ID')
credentials = dict(
    aws_access_key_id=(credential_dir / 'access_key').read_text().strip(),
    aws_secret_access_key=(credential_dir / 'secret_key').read_text().strip())
if not all(credentials.values()):
    raise RuntimeError('DEV credentials must not be empty')
if (credential_dir / 'session_token').exists():
    credentials['aws_session_token'] = (credential_dir / 'session_token').read_text().strip()
region = os.environ.get('QUAY_STS_REGION', 'us-east-1')
options = Config(connect_timeout=10, read_timeout=30,
                 retries={'mode': 'standard', 'max_attempts': 5})
session = boto3.Session(region_name=region, **credentials)
identity = session.client('sts', config=options).get_caller_identity()
if identity['Account'] != expected_account:
    raise RuntimeError('AWS identity does not match the configured Quay DEV account')
partition = identity['Arn'].split(':')[1]
iam = session.client('iam', config=options)
s3 = session.client('s3', config=options)
import uuid
from urllib.parse import urlparse

cluster_uid = verify_cluster()
if read_object('infrastructure', 'cluster')['status']['platformStatus']['type'] != 'AWS':
    raise RuntimeError('The QE cluster must run on AWS')
if read_object('cloudcredential', 'cluster')['spec'].get('credentialsMode') != 'Manual':
    raise RuntimeError('The QE cluster must already have CCO Manual mode configured')
issuer = read_object('authentication', 'cluster')['spec'].get('serviceAccountIssuer', '').rstrip('/')
url = urlparse(issuer)
if url.scheme != 'https' or not url.netloc or url.query or url.fragment or url.username:
    raise RuntimeError('The QE cluster must have a valid HTTPS OIDC issuer')
if STATE_PATH.exists():
    raise RuntimeError('Previous state exists; complete cleanup before a new run')
run_id = uuid.uuid4().hex[:16]
name = 'quay-sts-' + run_id
provider_arn = f'arn:{partition}:iam::{expected_account}:oidc-provider/{issuer.removeprefix("https://")}'
state = dict(account=expected_account, region=region, cluster_uid=cluster_uid,
             run_id=run_id, namespace=name, bucket=name, role=name,
             namespace_created=False, bucket_created=False, role_created=False,
             provider_arn=provider_arn, provider_created=False)
save(state)
# Never adopt a pre-existing namespace. A create collision fails without deletion.
namespace = json.loads(subprocess.check_output(
    ['oc', '--request-timeout=30s', 'create', '-f', '-', '-o', 'json'],
    input=json.dumps({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {
        'name': name, 'labels': {'quay.redhat.com/sts-ci-run': run_id}}}), text=True))
state['namespace_uid'] = namespace['metadata']['uid']
state['namespace_created'] = True
save(state)
tags = [{'Key': 'quay-sts-run', 'Value': run_id}]
try:
    provider = iam.get_open_id_connect_provider(OpenIDConnectProviderArn=provider_arn)
except ClientError as error:
    if error.response['Error']['Code'] != 'NoSuchEntity':
        raise
    try:
        iam.create_open_id_connect_provider(Url=issuer, ClientIDList=['openshift'],
            Tags=[{'Key': 'quay-sts-shared', 'Value': cluster_uid}])
        state['provider_created'] = True
        save(state)
    except ClientError as create_error:
        if create_error.response['Error']['Code'] != 'EntityAlreadyExists':
            raise
    provider = iam.get_open_id_connect_provider(OpenIDConnectProviderArn=provider_arn)
if 'openshift' not in provider['ClientIDList']:
    raise RuntimeError('Existing OIDC provider lacks openshift audience; ask its owner to configure it')
# Issuer registration is shared across runs. Never change its audience or delete it.
args = dict(Bucket=name)
if region != 'us-east-1':
    args['CreateBucketConfiguration'] = {'LocationConstraint': region}
s3.create_bucket(**args)
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
    if not boundary.startswith(f'arn:{partition}:iam::{expected_account}:policy/'):
        raise RuntimeError('Permissions boundary must be a policy in the DEV account')
    role_args['PermissionsBoundary'] = boundary
role = iam.create_role(**role_args)
state['role_created'] = True
state['role_arn'] = role['Role']['Arn']
save(state)
bucket_arn = f'arn:{partition}:s3:::{name}'
policy = {'Version': '2012-10-17', 'Statement': [
    {'Effect': 'Allow', 'Action': ['s3:ListBucket', 's3:GetBucketLocation', 's3:ListBucketMultipartUploads'], 'Resource': bucket_arn},
    {'Effect': 'Allow', 'Action': ['s3:GetObject', 's3:PutObject', 's3:DeleteObject', 's3:AbortMultipartUpload', 's3:ListMultipartUploadParts'], 'Resource': bucket_arn + '/*'}]}
iam.put_role_policy(RoleName=name, PolicyName='quay-sts-bucket', PolicyDocument=json.dumps(policy))
for key, value in {'STS_TEST_NAMESPACE': name, 'STS_S3_BUCKET': name,
                   'STS_S3_REGION': region, 'STS_ROLE_ARN': state['role_arn']}.items():
    (STATE_PATH.parent / key).write_text(value)
print('Prepared run-owned resources:', name)
print('Shared OIDC provider retained between runs:', provider_arn)
PYTHON
