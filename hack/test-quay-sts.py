"""Offline tests of embedded STS step scripts; no AWS or cluster access."""
import contextlib
import io
import json
import os
import pathlib
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1] / 'ci-operator/step-registry/quay/sts'


class ClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {'Error': {'Code': code}}


# The fake exposes independently mutable AWS state for failure injection.
class AWS:  # pylint: disable=too-many-instance-attributes
    def __init__(self):
        self.calls = []
        self.account = '123456789012'
        self.provider = None
        self.role = None
        self.tags = []
        self.fail = None
        self.pages = {}
        self.race = False

    def __getattr__(self, name):
        def call(**kw):
            self.calls.append((name, kw))
            if name == self.fail:
                raise ClientError('AccessDenied')
            if name == 'get_caller_identity':
                return {'Account': self.account, 'Arn': f'arn:aws:iam::{self.account}:user/ci'}
            if name == 'get_open_id_connect_provider':
                if self.provider is None:
                    raise ClientError('NoSuchEntity')
                return self.provider
            if name == 'create_open_id_connect_provider':
                self.provider = {'ClientIDList': kw['ClientIDList']}
                if self.race:
                    raise ClientError('EntityAlreadyExists')
            if name == 'put_bucket_tagging':
                self.tags = kw['Tagging']['TagSet']
            if name == 'get_bucket_tagging':
                return {'TagSet': self.tags}
            if name == 'create_role':
                self.role = {'Arn': f'arn:aws:iam::{self.account}:role/' + kw['RoleName'], 'Tags': kw['Tags']}
                return {'Role': self.role}
            if name == 'get_role':
                if self.role is None:
                    raise ClientError('NoSuchEntity')
                return {'Role': self.role}
            if name == 'delete_role':
                self.role = None
            return {}
        return call

    def get_paginator(self, name):
        return types.SimpleNamespace(paginate=lambda **kw: self.pages.get(name, [{}]))


class Tests(unittest.TestCase):  # pylint: disable=too-many-instance-attributes
    def setUp(self):
        # unittest cleanup keeps the directory alive for the entire test.
        tmp = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.addCleanup(tmp.cleanup)
        self.p = pathlib.Path(tmp.name)
        self.aws = AWS()
        self.namespace = None
        self.cluster_uid = 'qe-uid'
        self.workloads = []
        self.oc_calls = []
        self.collision = False
        self.wrong_role = False
        self.global_operator = False
        for key, value in {'account_id': '123456789012', 'access_key': 'test',
                           'secret_key': 'test', 'cluster_uid': 'qe-uid'}.items():
            (self.p / key).write_text(value)

    def state(self):
        return json.loads((self.p / 'quay-sts-state.json').read_text())

    def oc(self, args, **kw):  # pylint: disable=too-many-return-statements
        # Dispatch the small set of API responses needed by these scenarios.
        self.oc_calls.append(args)
        verb, resource = args[2:4]
        if verb == 'create':
            if self.collision:
                raise RuntimeError('Namespace collision')
            self.namespace = json.loads(kw['input'])
            self.namespace['metadata']['uid'] = 'run-uid'
            return json.dumps(self.namespace)
        if verb == 'delete':
            self.namespace = None
            return ''
        if verb == 'rollout':
            return 'rolled out'
        if verb == 'api-resources':
            return 'pods deployments.apps quayregistries.quay.redhat.com'
        if resource == 'namespace':
            if args[4] == 'kube-system':
                return json.dumps({'metadata': {'uid': self.cluster_uid}})
            return json.dumps(self.namespace) if self.namespace else ''
        if resource == 'deployment':
            s = self.state()
            return json.dumps({'metadata': {'name': 'quay-operator-tng'}, 'spec': {'template': {
                'metadata': {}, 'spec': {'containers': [{'args': ['--namespace=$(WATCH_NAMESPACE)'],
                    'env': [{'name': 'ROLEARN', 'value': 'wrong' if self.wrong_role else s['role_arn']},
                            {'name': 'WATCH_NAMESPACE', 'value': s['namespace']}]}]}}}})
        if resource == 'clusterserviceversions':
            return json.dumps({'items': [{'metadata': {'namespace': 'openshift-operators'},
                'spec': {'customresourcedefinitions': {'owned': [{'name': 'quayregistries.quay.redhat.com'}]}}}]
                if self.global_operator else []})
        if ',' in resource:
            return json.dumps({'items': self.workloads})
        return json.dumps({'infrastructure': {'status': {'platformStatus': {'type': 'AWS'}}},
                           'cloudcredential': {'spec': {'credentialsMode': 'Manual'}},
                           'authentication': {'spec': {'serviceAccountIssuer': 'https://issuer.example/cluster'}}}[resource])

    def execute(self, step):
        script = (ROOT / step / f'quay-sts-{step}-commands.sh').read_text()
        code = script.split("<<'PYTHON'\n", 1)[1].split('\nPYTHON\n', 1)[0]
        for mount in ('quay-dev-aws', 'quay-qe-cluster'):
            code = code.replace(f"pathlib.Path('/var/run/{mount}')", f'pathlib.Path({str(self.p)!r})')
        modules = {'boto3': types.SimpleNamespace(Session=lambda **kw: types.SimpleNamespace(client=lambda *a, **k: self.aws)),
                   'botocore': types.ModuleType('botocore'),
                   'botocore.config': types.SimpleNamespace(Config=lambda **kw: None),
                   'botocore.exceptions': types.SimpleNamespace(ClientError=ClientError)}
        with patch.dict(sys.modules, modules), patch.dict(os.environ, {
                'SHARED_DIR': str(self.p), 'QUAY_STS_REGION': 'us-east-1',
                'QUAY_STS_PERMISSIONS_BOUNDARY': '', 'QUAY_STS_OPERATOR_DEPLOYMENT': 'quay-operator-tng'}), \
                patch('subprocess.check_output', side_effect=self.oc), contextlib.redirect_stdout(io.StringIO()):
            # Execute the repository's actual embedded script with mocked I/O.
            exec(compile(code, str(ROOT / step), 'exec'), {})  # pylint: disable=exec-used

    def names(self):
        return [name for name, _ in self.aws.calls]

    def test_web_identity_and_bucket_scope(self):
        self.execute('provision')
        state = self.state()
        calls = dict(self.aws.calls)
        trust = json.loads(calls['create_role']['AssumeRolePolicyDocument'])['Statement'][0]
        self.assertEqual(trust['Action'], 'sts:AssumeRoleWithWebIdentity')
        self.assertEqual(trust['Condition']['StringEquals'], {
            'issuer.example/cluster:aud': 'openshift',
            'issuer.example/cluster:sub': f"system:serviceaccount:{state['namespace']}:sts-cco-quay-app"})
        policy = json.loads(calls['put_role_policy']['PolicyDocument'])
        self.assertEqual(policy['Statement'][1]['Resource'], 'arn:aws:s3:::' + state['bucket'] + '/*')
        self.execute('test')
        self.execute('cleanup')
        self.assertIn('delete_bucket', self.names())
        self.assertIn('delete_role', self.names())
        self.assertNotIn('delete_open_id_connect_provider', self.names())

    def test_reused_provider_retained(self):
        self.aws.provider = {'ClientIDList': ['openshift']}
        self.execute('provision')
        self.assertFalse(self.state()['provider_created'])
        self.execute('cleanup')
        self.assertNotIn('create_open_id_connect_provider', self.names())
        self.assertNotIn('delete_open_id_connect_provider', self.names())

    def test_provider_creation_race(self):
        self.aws.race = True
        self.execute('provision')
        self.assertFalse(self.state()['provider_created'])

    def test_wrong_account_no_mutations(self):
        self.aws.account = '999999999999'
        with self.assertRaises(RuntimeError):
            self.execute('provision')
        self.assertEqual(self.names(), ['get_caller_identity'])
        self.assertFalse(self.oc_calls)

    def test_wrong_cluster_no_mutations(self):
        self.cluster_uid = 'wrong'
        with self.assertRaises(RuntimeError):
            self.execute('provision')
        self.assertEqual(self.names(), ['get_caller_identity'])
        self.assertIsNone(self.namespace)

    def test_existing_provider_not_modified(self):
        self.aws.provider = {'ClientIDList': ['sts.amazonaws.com']}
        with self.assertRaises(RuntimeError):
            self.execute('provision')
        self.assertNotIn('create_bucket', self.names())
        self.execute('cleanup')
        self.assertEqual(self.aws.provider['ClientIDList'], ['sts.amazonaws.com'])

    def test_namespace_collision_not_deleted(self):
        self.collision = True
        with self.assertRaises(RuntimeError):
            self.execute('provision')
        self.execute('cleanup')
        self.assertFalse(any(args[2] == 'delete' for args in self.oc_calls))

    def test_partial_policy_failure_cleanup(self):
        self.aws.fail = 'put_role_policy'
        with self.assertRaises(ClientError):
            self.execute('provision')
        self.aws.fail = None
        self.execute('cleanup')
        self.assertIn('delete_role', self.names())
        self.assertIn('delete_bucket', self.names())

    def test_unowned_namespace_preserves_aws(self):
        self.execute('provision')
        self.namespace['metadata']['uid'] = 'different'
        with self.assertRaises(RuntimeError):
            self.execute('cleanup')
        self.assertNotIn('delete_role', self.names())
        self.assertNotIn('delete_bucket', self.names())

    def test_live_workload_preserves_aws(self):
        self.execute('provision')
        self.workloads = [{'kind': 'Pod'}]
        with self.assertRaises(RuntimeError):
            self.execute('cleanup')
        self.assertNotIn('delete_role', self.names())
        self.assertIsNotNone(self.namespace)

    def test_unowned_role_retained(self):
        self.execute('provision')
        self.aws.role['Tags'] = []
        with self.assertRaises(RuntimeError):
            self.execute('cleanup')
        self.assertNotIn('delete_role', self.names())
        self.assertIn('delete_bucket', self.names())

    def test_unowned_bucket_retained(self):
        self.execute('provision')
        self.aws.tags = []
        with self.assertRaises(RuntimeError):
            self.execute('cleanup')
        self.assertNotIn('delete_bucket', self.names())

    def test_wrong_test_role_rejected(self):
        self.execute('provision')
        self.wrong_role = True
        with self.assertRaises(RuntimeError):
            self.execute('test')

    def test_global_operator_rejected(self):
        self.execute('provision')
        self.global_operator = True
        with self.assertRaises(RuntimeError):
            self.execute('test')

    def test_versioned_objects_and_uploads_cleaned(self):
        self.execute('provision')
        self.aws.pages = {'list_object_versions': [{'Versions': [{'Key': 'image', 'VersionId': 'v1'}],
                                                  'DeleteMarkers': [{'Key': 'image', 'VersionId': 'v2'}]}],
                          'list_multipart_uploads': [{'Uploads': [{'Key': 'partial', 'UploadId': 'u1'}]}]}
        self.execute('cleanup')
        calls = dict(self.aws.calls)
        self.assertEqual(len(calls['delete_objects']['Delete']['Objects']), 2)
        self.assertEqual(calls['abort_multipart_upload']['UploadId'], 'u1')


if __name__ == '__main__':
    unittest.main()
