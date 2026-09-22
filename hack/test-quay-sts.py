"""Offline tests of embedded Quay STS step scripts; no AWS or cluster access."""
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

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
ROOT = REPO_ROOT / 'ci-operator/step-registry/quay/sts'
CONFIG = REPO_ROOT / 'ci-operator/config/quay/quay-operator/quay-quay-operator-master__ocp-latest.yaml'


class ClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {'Error': {'Code': code}}


class AWS:  # pylint: disable=too-many-instance-attributes
    """Small independently mutable fake for AWS failure injection."""

    def __init__(self):
        self.calls = []
        self.account = '123456789012'
        self.provider = {'ClientIDList': ['openshift']}
        self.role = None
        self.tags = []
        self.fail = None
        self.transient = {}
        self.pages = {}

    def __getattr__(self, name):
        def call(**kwargs):
            self.calls.append((name, kwargs))
            if name == self.fail:
                raise ClientError('AccessDenied')
            if self.transient.get(name):
                code, remaining = self.transient[name]
                self.transient[name] = (code, remaining - 1)
                if remaining > 0:
                    raise ClientError(code)
            if name == 'get_caller_identity':
                return {'Account': self.account, 'Arn': f'arn:aws:iam::{self.account}:user/ci'}
            if name == 'get_open_id_connect_provider':
                return self.provider
            if name == 'put_bucket_tagging':
                self.tags = kwargs['Tagging']['TagSet']
            if name == 'get_bucket_tagging':
                return {'TagSet': self.tags}
            if name == 'create_role':
                self.role = {'Arn': f'arn:aws:iam::{self.account}:role/' + kwargs['RoleName'],
                             'Tags': kwargs['Tags']}
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
        return types.SimpleNamespace(paginate=lambda **kwargs: self.pages.get(name, [{}]))


class Tests(unittest.TestCase):  # pylint: disable=too-many-instance-attributes
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.addCleanup(tmp.cleanup)
        self.path = pathlib.Path(tmp.name)
        self.aws = AWS()
        self.namespace = None
        self.cluster_uid = 'ephemeral-uid'
        self.oc_calls = []
        self.collision = False
        self.wrong_role = False
        (self.path / 'kubeconfig').write_text('test')
        (self.path / '.awscred').write_text('[default]\n')
        (self.path / 'aws_oidc_provider_arn').write_text(
            'arn:aws:iam::123456789012:oidc-provider/issuer.example/cluster')

    def state(self):
        return json.loads((self.path / 'quay-sts-state.json').read_text())

    def oc(self, args, **kwargs):  # pylint: disable=too-many-return-statements
        self.oc_calls.append(args)
        verb, resource = args[2:4]
        if verb == 'create':
            if self.collision:
                raise RuntimeError('Namespace collision')
            self.namespace = json.loads(kwargs['input'])
            self.namespace['metadata']['uid'] = 'run-uid'
            return json.dumps(self.namespace)
        if verb == 'rollout':
            return 'rolled out'
        if resource == 'namespace':
            if args[4] == 'kube-system':
                return json.dumps({'metadata': {'uid': self.cluster_uid}})
            return json.dumps(self.namespace) if self.namespace else ''
        if resource == 'deployment':
            state = self.state()
            return json.dumps({'metadata': {'name': 'quay-operator-tng'}, 'spec': {'template': {
                'metadata': {'annotations': {'olm.targetNamespaces': ''}},
                'spec': {'containers': [{'command': ['/workspace/manager', '--namespace=$(WATCH_NAMESPACE)'],
                    'env': [{'name': 'ROLEARN',
                             'value': 'wrong' if self.wrong_role else state['role_arn']},
                            {'name': 'WATCH_NAMESPACE', 'valueFrom': {'fieldRef': {
                                'fieldPath': "metadata.annotations['olm.targetNamespaces']"}}}]}]}}}})
        return json.dumps({
            'infrastructure': {'status': {'platformStatus': {'type': 'AWS'}}},
            'cloudcredential': {'spec': {'credentialsMode': 'Manual'}},
            'authentication': {'spec': {
                'serviceAccountIssuer': 'https://issuer.example/cluster'}}}[resource])

    def execute(self, step):
        script = (ROOT / step / f'quay-sts-{step}-commands.sh').read_text()
        code = script.split("<<'PYTHON'\n", 1)[1].split('\nPYTHON\n', 1)[0]
        modules = {
            'boto3': types.SimpleNamespace(Session=lambda **kwargs: types.SimpleNamespace(
                client=lambda *args, **client_kwargs: self.aws)),
            'botocore': types.ModuleType('botocore'),
            'botocore.config': types.SimpleNamespace(Config=lambda **kwargs: None),
            'botocore.exceptions': types.SimpleNamespace(ClientError=ClientError),
        }
        output = io.StringIO()
        with patch.dict(sys.modules, modules), patch.dict(os.environ, {
                'SHARED_DIR': str(self.path), 'CLUSTER_PROFILE_DIR': str(self.path),
                'LEASED_RESOURCE': 'us-east-1', 'QUAY_STS_REGION': '',
                'QUAY_STS_PERMISSIONS_BOUNDARY': '',
                'QUAY_STS_OPERATOR_NAMESPACE': 'openshift-operators',
                'QUAY_STS_OPERATOR_DEPLOYMENT': 'quay-operator-tng'}), \
                patch('subprocess.check_output', side_effect=self.oc), \
                contextlib.redirect_stdout(output):
            exec(compile(code, str(ROOT / step), 'exec'), {})  # pylint: disable=exec-used
        return output.getvalue()

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
            'issuer.example/cluster:sub':
                f"system:serviceaccount:{state['namespace']}:sts-cco-quay-app"})
        policy = json.loads(calls['put_role_policy']['PolicyDocument'])
        self.assertEqual(policy['Statement'][1]['Resource'],
                         'arn:aws:s3:::' + state['bucket'] + '/*')
        self.execute('test')
        self.execute('cleanup')
        self.assertIn('delete_bucket', self.names())
        self.assertIn('delete_role', self.names())
        self.assertNotIn('create_open_id_connect_provider', self.names())
        self.assertNotIn('delete_open_id_connect_provider', self.names())

    def test_provider_account_mismatch_has_no_mutations(self):
        (self.path / 'aws_oidc_provider_arn').write_text(
            'arn:aws:iam::999999999999:oidc-provider/issuer.example/cluster')
        with self.assertRaises(RuntimeError):
            self.execute('provision')
        self.assertNotIn('create_bucket', self.names())
        self.assertIsNone(self.namespace)

    def test_provider_issuer_mismatch_has_no_mutations(self):
        (self.path / 'aws_oidc_provider_arn').write_text(
            'arn:aws:iam::123456789012:oidc-provider/other.example/cluster')
        with self.assertRaises(RuntimeError):
            self.execute('provision')
        self.assertFalse(self.names())
        self.assertIsNone(self.namespace)

    def test_provider_without_openshift_audience_is_rejected(self):
        self.aws.provider = {'ClientIDList': ['sts.amazonaws.com']}
        with self.assertRaises(RuntimeError):
            self.execute('provision')
        self.assertNotIn('create_bucket', self.names())
        self.assertIsNone(self.namespace)

    def test_namespace_collision_not_adopted(self):
        self.collision = True
        with self.assertRaises(RuntimeError):
            self.execute('provision')
        self.assertNotIn('create_bucket', self.names())

    def test_partial_policy_failure_cleanup(self):
        self.aws.fail = 'put_role_policy'
        with self.assertRaises(ClientError):
            self.execute('provision')
        self.aws.fail = None
        self.execute('cleanup')
        self.assertIn('delete_role', self.names())
        self.assertIn('delete_bucket', self.names())

    def test_iam_eventual_consistency_is_retried(self):
        self.aws.transient['put_role_policy'] = ('NoSuchEntity', 2)
        with patch('time.sleep'):
            self.execute('provision')
        self.assertEqual(self.names().count('put_role_policy'), 3)
        self.aws.transient['delete_role'] = ('DeleteConflict', 1)
        with patch('time.sleep'):
            self.execute('cleanup')
        self.assertEqual(self.names().count('delete_role'), 2)

    def test_cleanup_rejects_different_account(self):
        self.execute('provision')
        self.aws.account = '999999999999'
        with self.assertRaises(RuntimeError):
            self.execute('cleanup')
        self.assertNotIn('delete_role', self.names())
        self.assertNotIn('delete_bucket', self.names())

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

    def test_test_rejects_state_from_another_cluster(self):
        self.execute('provision')
        self.cluster_uid = 'different-cluster'
        with self.assertRaises(RuntimeError):
            self.execute('test')

    def test_versioned_objects_and_uploads_cleaned(self):
        self.execute('provision')
        self.aws.pages = {
            'list_object_versions': [{'Versions': [{'Key': 'image', 'VersionId': 'v1'}],
                                      'DeleteMarkers': [{'Key': 'image', 'VersionId': 'v2'}]}],
            'list_multipart_uploads': [{'Uploads': [{'Key': 'partial', 'UploadId': 'u1'}]}],
        }
        self.execute('cleanup')
        calls = dict(self.aws.calls)
        self.assertEqual(len(calls['delete_objects']['Delete']['Objects']), 2)
        self.assertEqual(calls['abort_multipart_upload']['UploadId'], 'u1')

    def test_status_output_omits_account_and_issuer(self):
        output = self.execute('provision') + self.execute('cleanup')
        self.assertNotIn('123456789012', output)
        self.assertNotIn('issuer.example', output)
        self.assertNotIn('oidc-provider/', output)

    def test_job_uses_ephemeral_manual_oidc_sts_lifecycle(self):
        config = CONFIG.read_text()
        self.assertIn('as: e2e-sts', config)
        self.assertIn('chain: ipi-aws-pre-manual-oidc-sts', config)
        self.assertIn('chain: ipi-aws-post-manual-oidc-sts', config)
        self.assertIn('ref: quay-sts-install', config)
        self.assertIn('ref: quay-sts-teardown', config)
        for ref in ('provision', 'test', 'cleanup'):
            self.assertNotIn('collection: quay-qe',
                             (ROOT / ref / f'quay-sts-{ref}-ref.yaml').read_text())
            self.assertNotIn('collection: quay-dev',
                             (ROOT / ref / f'quay-sts-{ref}-ref.yaml').read_text())

    def test_install_uses_olm_all_namespaces_and_rolearn(self):
        script = (ROOT / 'install/quay-sts-install-commands.sh').read_text()
        self.assertIn('--install-mode=AllNamespaces', script)
        self.assertIn('oc patch subscription', script)
        self.assertIn('ROLEARN', script)
        self.assertNotIn('oc set env deployment', script)

    def test_teardown_targets_only_the_run_registry(self):
        script = (ROOT / 'teardown/quay-sts-teardown-commands.sh').read_text()
        self.assertIn("'delete', 'quayregistry/sts-cco'", script)
        self.assertNotIn('quayregistries --all', script)
        self.assertNotIn('delete crd', script)


if __name__ == '__main__':
    unittest.main()
