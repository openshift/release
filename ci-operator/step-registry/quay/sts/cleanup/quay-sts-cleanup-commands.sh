#!/bin/bash
set -euo pipefail
set +x
[[ -f "${SHARED_DIR}/quay-sts-state.json" ]] || exit 0
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_EC2_METADATA_DISABLED=true
python3 - <<'PYTHON'
import json
import os
import pathlib
import re
import time

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

STATE_PATH = pathlib.Path(os.environ['SHARED_DIR']) / 'quay-sts-state.json'


def load_state():
    state = json.loads(STATE_PATH.read_text())
    run_id = state['run_id']
    if not re.fullmatch(r'[a-f0-9]{16}', run_id):
        raise RuntimeError('Invalid run identity')
    name = 'quay-sts-' + run_id
    if any(state[key] != name for key in ('namespace', 'bucket', 'role')):
        raise RuntimeError('Unexpected resource names in state')
    if not re.fullmatch(r'[0-9]{12}', state['account']):
        raise RuntimeError('Invalid AWS account in state')
    return state


state = load_state()
name = state['role']
options = Config(connect_timeout=10, read_timeout=30,
                 retries={'mode': 'standard', 'max_attempts': 5})
session = boto3.Session(region_name=state['region'])
identity = session.client('sts', config=options).get_caller_identity()
if identity['Account'] != state['account']:
    raise RuntimeError('Cleanup AWS identity differs from provisioning state')
iam = session.client('iam', config=options)
s3 = session.client('s3', config=options)

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
        for attempt in range(1, 11):
            try:
                iam.delete_role(RoleName=name)
                break
            except ClientError as error:
                code = error.response['Error']['Code']
                if code == 'NoSuchEntity':
                    break
                if code != 'DeleteConflict' or attempt == 10:
                    raise
                time.sleep(attempt)
    except ClientError as error:
        if error.response['Error']['Code'] != 'NoSuchEntity':
            errors.append(error)
    except RuntimeError as error:
        errors.append(error)

if state['bucket_created']:
    try:
        s3.head_bucket(Bucket=state['bucket'], ExpectedBucketOwner=state['account'])
        tags = s3.get_bucket_tagging(
            Bucket=state['bucket'], ExpectedBucketOwner=state['account'])['TagSet']
        if {'Key': 'quay-sts-run', 'Value': state['run_id']} not in tags:
            raise RuntimeError('Bucket ownership tag mismatch')
        for page in s3.get_paginator('list_multipart_uploads').paginate(Bucket=state['bucket']):
            for upload in page.get('Uploads', []):
                s3.abort_multipart_upload(
                    Bucket=state['bucket'], Key=upload['Key'], UploadId=upload['UploadId'])
        for page in s3.get_paginator('list_object_versions').paginate(Bucket=state['bucket']):
            objects = [{'Key': obj['Key'], 'VersionId': obj['VersionId']}
                       for obj in page.get('Versions', []) + page.get('DeleteMarkers', [])]
            for start in range(0, len(objects), 1000):
                result = s3.delete_objects(
                    Bucket=state['bucket'], Delete={'Objects': objects[start:start + 1000]})
                if result.get('Errors'):
                    raise RuntimeError('S3 object deletion failed; retain bucket for investigation')
        s3.delete_bucket(Bucket=state['bucket'], ExpectedBucketOwner=state['account'])
    except ClientError as error:
        if error.response['Error']['Code'] not in ('NoSuchBucket', '404'):
            errors.append(error)
    except RuntimeError as error:
        errors.append(error)

if errors:
    raise RuntimeError('Incomplete cleanup: ' + '; '.join(str(error) for error in errors))
print('Run-owned Quay STS AWS resources cleaned up')
PYTHON
