#!/bin/bash
set -euo pipefail
set +x
export KUBECONFIG=/var/run/quay-qe-cluster/kubeconfig
[[ -f "${SHARED_DIR}/quay-sts-state.json" ]] || exit 0
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
cluster_uid = verify_cluster()
state = load_state(cluster_uid)
if state['account'] != expected_account or state['region'] != region:
    raise RuntimeError('Cleanup AWS account/region mismatch')
name = state['namespace']
if state['namespace_created']:
    raw = oc('get', 'namespace', name, '--ignore-not-found', '-o', 'json')
    if raw.strip():
        verify_namespace(state)
        # The caller must remove the registry before uninstalling its operator.
        available = set(oc('api-resources', '--verbs=list', '--namespaced=true', '-o', 'name').split())
        candidates = ('quayregistries.quay.redhat.com', 'deployments.apps', 'statefulsets.apps',
                      'jobs.batch', 'pods', 'subscriptions.operators.coreos.com',
                      'clusterserviceversions.operators.coreos.com')
        resources = ','.join(resource for resource in candidates if resource in available)
        if not resources:
            raise RuntimeError('Cannot discover namespaced workloads for cleanup')
        remaining = json.loads(oc('get', resources, '-n', name, '-o', 'json'))
        active = [item for item in remaining['items'] if not (
            item.get('kind') == 'ClusterServiceVersion' and item.get('status', {}).get('reason') == 'Copied')]
        if active:
            raise RuntimeError('Workloads remain: finish registry and operator teardown before AWS cleanup')
        oc('delete', 'namespace', name, '--wait=true', '--timeout=180s')
errors = []
if state['role_created']:
    try:
        role = iam.get_role(RoleName=name)['Role']
        if {'Key': 'quay-sts-run', 'Value': state['run_id']} not in role.get('Tags', []):
            raise RuntimeError('Role ownership tag mismatch')
        try:
            iam.delete_role_policy(RoleName=name, PolicyName='quay-sts-bucket')
        except ClientError as error:
            if error.response['Error']['Code'] != 'NoSuchEntity':
                raise
        iam.delete_role(RoleName=name)
    except ClientError as error:
        if error.response['Error']['Code'] != 'NoSuchEntity':
            errors.append(error)
    except RuntimeError as error:
        errors.append(error)
if state['bucket_created']:
    try:
        s3.head_bucket(Bucket=name, ExpectedBucketOwner=expected_account)
        tags = s3.get_bucket_tagging(Bucket=name, ExpectedBucketOwner=expected_account)['TagSet']
        if {'Key': 'quay-sts-run', 'Value': state['run_id']} not in tags:
            raise RuntimeError('Bucket ownership tag mismatch')
        for page in s3.get_paginator('list_multipart_uploads').paginate(Bucket=name):
            for upload in page.get('Uploads', []):
                s3.abort_multipart_upload(Bucket=name, Key=upload['Key'], UploadId=upload['UploadId'])
        for page in s3.get_paginator('list_object_versions').paginate(Bucket=name):
            objects = [{'Key': obj['Key'], 'VersionId': obj['VersionId']}
                       for obj in page.get('Versions', []) + page.get('DeleteMarkers', [])]
            for start in range(0, len(objects), 1000):
                result = s3.delete_objects(Bucket=name, Delete={'Objects': objects[start:start+1000]})
                if result.get('Errors'):
                    raise RuntimeError('S3 object deletion failed; retain bucket for investigation')
        s3.delete_bucket(Bucket=name, ExpectedBucketOwner=expected_account)
    except ClientError as error:
        if error.response['Error']['Code'] not in ('NoSuchBucket', '404'):
            errors.append(error)
    except RuntimeError as error:
        errors.append(error)
print('Shared OIDC provider retained:', state['provider_arn'])
if errors:
    raise RuntimeError('Incomplete cleanup: ' + '; '.join(str(error) for error in errors))
print('Run-owned resources cleaned up')
PYTHON
