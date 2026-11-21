#!/usr/bin/env python3
"""Exercise the proposed API client with fixture API/oc commands; no cluster access.

TODO(API handoff): Align these simulated responses with the delivered API contract.
Passing fixtures proves client behavior against this proposal, not API compatibility.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

# These are local tests of the real shell scripts, not Prow runtime scripts.
# All identities, URLs and credentials below are deliberately fake fixture data.
ROOT = Path(__file__).resolve().parents[2]
STEPS = ROOT / 'ci-operator/step-registry/kubevirt/ssp/cluster'
SLOT = 'libvirt-s390x-virt-0-0'
VERSION = '4.19.12'
RELEASE = 'example.test/release@sha256:' + 'a' * 64
CLUSTER_ID = '00000000-0000-0000-0000-000000000001'

# The shim models response loss, API states and cluster reads. It deliberately
# emits private errors on failure to test that the scripts suppress raw stderr.
SHIM = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['FIXTURE'])
a = sys.argv[1:]
scenario = os.environ.get('SCENARIO', '')
with (p/'calls').open('a') as f:
    f.write(json.dumps([pathlib.Path(sys.argv[0]).name, *a]) + '\n')
def value(flag): return a[a.index(flag)+1]
def emit(obj): print(json.dumps(obj))
slot = 'libvirt-s390x-virt-0-0'
version = '4.19.12'
release = 'example.test/release@sha256:' + 'a'*64
cid = '00000000-0000-0000-0000-000000000001'
if pathlib.Path(sys.argv[0]).name == 'curl':
    url, method = a[-1], value('--request')
    body, code = {}, '200'
    if method == 'POST':
        (p/'posted').touch()
        if scenario == 'lost-response':
            print('PRIVATE-ERROR token=TEST-SECRET', file=sys.stderr)
            sys.exit(28)
        body = dict(slot=slot, state='running', generation='new', build_id='build1')
        code = '202'
        if scenario == 'post-conflict': code='409'
        if scenario == 'stale-accepted': body['generation']='old'
    elif 'kubeconfig?' in url:
        body = json.loads((p/'kubeconfig').read_text())
        if scenario == 'stale-kubeconfig': code='409'
        if scenario == 'executable-config': body['users'][0]['user']['exec']={'command':'private-command'}
        if scenario == 'insecure-config': body['clusters'][0]['cluster']['insecure-skip-tls-verify']=True
    elif '/builds/' in url:
        if scenario in ('transient-get', 'unavailable-get'):
            if scenario == 'unavailable-get' or not (p/'retried').exists(): code='503'
            (p/'retried').touch()
        if scenario == 'transient-transport' and not (p/'retried').exists():
            (p/'retried').touch()
            print('PRIVATE-ERROR', file=sys.stderr)
            sys.exit(28)
        body = dict(slot=slot,state='ready',generation='new',build_id='build1',openshift_version=version,release_image=release)
        if scenario == 'build-failed': body['state']='failed'; body['error']='PRIVATE-ERROR'
        if scenario == 'build-running': body['state']='running'
        if scenario == 'wrong-generation': body['generation']='other'
        if scenario == 'wrong-version': body['openshift_version']='4.19.99'
        if scenario == 'mutable-release': body['release_image']='example.test/release:latest'
    else:
        body = dict(slot=slot,state='ready',generation='new' if (p/'posted').exists() else 'old',build_id='build1',openshift_version=version,release_image=release,cluster_id=cid if (p/'posted').exists() else '00000000-0000-0000-0000-000000000002')
        if scenario == 'empty-slot' and not (p/'posted').exists(): body.update(state='empty',generation=None,cluster_id=None)
        if scenario == 'reused-identity': body['cluster_id']=cid
        if scenario == 'slot-busy': body['state']='building'
        if scenario == 'wrong-slot': body['slot']='other'
        if scenario == 'missing-cluster-id': body.pop('cluster_id')
    if scenario == 'redirect': code='302'
    pathlib.Path(value('--output')).write_text(json.dumps(body))
    print(code, end='')
else:
    if a[:2] == ['config','view']:
        path = next(v.split('=',1)[1] for v in a if v.startswith('--kubeconfig='))
        print(pathlib.Path(path).read_text())
    elif 'clusterversion' in a:
        emit({'spec':{'clusterID':'wrong' if scenario=='wrong-cluster' else cid},'status':{'desired':{'version':version,'image':release},'history':[{'state':'Completed'}],'conditions':[{'type':k,'status':v} for k,v in [('Available','True'),('Progressing','False'),('Failing','False')]]}})
    elif 'nodes' in a:
        emit({'items':[{'metadata':{'labels':{'node-role.kubernetes.io/master' if n<3 else 'node-role.kubernetes.io/worker':''}},'status':{'nodeInfo':{'architecture':'amd64' if scenario=='wrong-arch' else 's390x'},'conditions':[{'type':'Ready','status':'True'}]}} for n in range(5)]})
    elif 'clusteroperators' in a:
        emit({'items':[{'status':{'conditions':[{'type':k,'status':v} for k,v in [('Available','True'),('Progressing','False'),('Degraded','True' if scenario=='degraded' else 'False')]]}}]})
    else: sys.exit(99)
'''


# Each test gets an isolated directory and fake curl/oc executables. Putting
# them first on PATH intercepts network/cluster commands while bash and jq run
# normally. SCENARIO tells the fake commands which response or failure to return.
class ProvisioningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ('bin', 'shared', 'artifacts', 'credentials'):
            (self.root/name).mkdir()
        for name in ('curl', 'oc'):
            p = self.root/'bin'/name
            p.write_text(SHIM)
            p.chmod(0o755)
        for name, val in dict(url='https://private-api.example.test', token='TEST-SECRET', slots=SLOT).items():
            (self.root/'credentials'/name).write_text(val)
        config = {'apiVersion':'v1','kind':'Config','current-context':'test',
                  'clusters':[{'name':'cluster','cluster':{'server':'https://private-cluster.example.test','certificate-authority-data':'Y2E='}}],
                  'contexts':[{'name':'test','context':{'cluster':'cluster','user':'user'}}],
                  'users':[{'name':'user','user':{'token':'KUBECONFIG-SECRET'}}]}
        (self.root/'kubeconfig').write_text(json.dumps(config))
        self.env = dict(os.environ, PATH=str(self.root/'bin')+os.pathsep+os.environ['PATH'], FIXTURE=str(self.root),
                        SHARED_DIR=str(self.root/'shared'), ARTIFACT_DIR=str(self.root/'artifacts'),
                        CLUSTER_API_CREDENTIALS_DIR=str(self.root/'credentials'),
                        CLUSTER_TYPE='libvirt-s390x-vpn-virt', LEASED_RESOURCE=SLOT, PROW_JOB_ID='test-job-1',
                        CLUSTER_API_OPENSHIFT_VERSION=VERSION, CLUSTER_API_REBUILD_ENABLED='true',
                        CLUSTER_API_TIMEOUT_SECONDS='9000', CLUSTER_API_VERIFY_SECONDS='1')

    # Run the real provision/verify script and check its console output and public
    # artifacts for leaked fixture secrets. Private shared files are checked separately.
    def run_step(self, name, **env):
        result = subprocess.run(['bash', str(STEPS/name/f'kubevirt-ssp-cluster-{name}-commands.sh')],
                                env=dict(self.env, **env), capture_output=True, text=True, timeout=20)
        public = result.stdout+result.stderr+''.join(p.read_text() for p in (self.root/'artifacts').iterdir())
        for secret in ('TEST-SECRET', 'KUBECONFIG-SECRET', 'PRIVATE-ERROR', 'private-api.example.test', 'private-cluster.example.test'):
            self.assertNotIn(secret, public)
        return result

    def calls(self):
        p = self.root/'calls'
        return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []

    # Success case: rebuild once, fetch the new generation, protect the kubeconfig,
    # then independently verify the live-cluster responses simulated by fake oc.
    def test_successful_provision_and_independent_verification(self):
        result = self.run_step('provision')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root/'shared/kubeconfig').stat().st_mode & 0o777, 0o600)
        calls = self.calls()
        self.assertEqual(sum('POST' in c for c in calls), 1)
        self.assertTrue(any('?generation=new' in c[-1] for c in calls))
        self.assertFalse(any('--location' in c or '--retry' in c for c in calls))
        result = self.run_step('verify')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_embedded_client_certificate_is_accepted_without_token(self):
        # Certificate authentication is an alternative to a token, not an extra
        # requirement. Keep that distinction when splitting validation rules.
        path = self.root/'kubeconfig'
        config = json.loads(path.read_text())
        config['users'][0]['user'] = {
            'client-certificate-data': 'Y2VydA==', 'client-key-data': 'a2V5',
        }
        path.write_text(json.dumps(config))
        self.assertEqual(self.run_step('provision').returncode, 0)

    def test_kubeconfig_rejections_explain_the_failed_rule(self):
        # Each case starts with a valid kubeconfig and breaks one rule. The
        # explanation must be specific, without exposing the rejected value.
        cases = [
            ('cluster', 'server', 'http://private-cluster.example.test', 'endpoint must use HTTPS'),
            ('cluster', 'certificate-authority-data', '', 'must embed CA data'),
            ('user', 'token', '', 'needs a token or embedded client certificate'),
        ]
        for field in ('certificate-authority', 'proxy-url'):
            cases.append(('cluster', field, 'PRIVATE-ERROR', 'must not use ' + field))
        for field in ('exec', 'auth-provider', 'tokenFile', 'client-certificate', 'client-key'):
            cases.append(('user', field, 'PRIVATE-ERROR', 'must not use ' + field))
        for section, field, value, message in cases:
            with self.subTest(section=section, field=field):
                self.setUp()
                path = self.root/'kubeconfig'
                config = json.loads(path.read_text())
                target = config['clusters'][0]['cluster'] if section == 'cluster' else config['users'][0]['user']
                target[field] = value
                path.write_text(json.dumps(config))
                result = self.run_step('provision')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse((self.root/'shared/kubeconfig').exists())

    def test_disabled_and_invalid_inputs_never_call_api(self):
        for change in ({'CLUSTER_API_REBUILD_ENABLED':'false'}, {'LEASED_RESOURCE':'other'},
                       {'CLUSTER_API_OPENSHIFT_VERSION':''}, {'CLUSTER_TYPE':'other'}):
            with self.subTest(change=change):
                self.assertNotEqual(self.run_step('provision', **change).returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_transient_read_failure_retries_without_another_rebuild(self):
        for scenario in ('transient-get', 'transient-transport'):
            with self.subTest(scenario=scenario):
                # Each case uses a separate fixture/operation.
                self.setUp()
                result = self.run_step('provision', SCENARIO=scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(sum('POST' in c for c in self.calls()), 1)
                self.assertEqual(sum('/v1/builds/' in c[-1] for c in self.calls()), 2)

    def test_empty_slot_installation(self):
        result = self.run_step('provision', SCENARIO='empty-slot')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unconfirmed_slot_is_not_rebuilt(self):
        (self.root/'credentials/slots').write_text('another-slot')
        self.assertNotEqual(self.run_step('provision').returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_wrong_cluster_and_unhealthy_nodes_or_operators_fail(self):
        self.assertEqual(self.run_step('provision').returncode, 0)
        cases = [('wrong-cluster', 'different cluster identity'),
                 ('wrong-arch', 'Some nodes are not s390x'),
                 ('degraded', 'Some cluster operators are degraded')]
        for scenario, message in cases:
            with self.subTest(scenario=scenario):
                result = self.run_step('verify', SCENARIO=scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_prior_handoff_is_not_overwritten(self):
        (self.root/'shared/kubeconfig').write_text('original')
        self.assertNotEqual(self.run_step('provision').returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertEqual((self.root/'shared/kubeconfig').read_text(), 'original')


# Generate one test per failure scenario below. None may publish a kubeconfig;
# early failures must send no POST, and failures after submission must not retry it.
def scenario_test(scenario, no_post=False):
    def test(self):
        result = self.run_step('provision', SCENARIO=scenario, CLUSTER_API_TIMEOUT_SECONDS='10' if scenario == 'build-running' else '9000')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root/'shared/kubeconfig').exists())
        posts = sum('POST' in c for c in self.calls())
        self.assertEqual(posts, 0 if no_post else 1)
    return test


# Register these generated cases with unittest so each failure has its own name.
for scenario in ('slot-busy', 'wrong-slot', 'redirect', 'post-conflict', 'lost-response', 'stale-accepted',
                 'build-failed', 'build-running', 'unavailable-get', 'wrong-generation', 'wrong-version', 'mutable-release',
                 'missing-cluster-id', 'reused-identity', 'stale-kubeconfig', 'executable-config', 'insecure-config'):
    setattr(ProvisioningTests, 'test_'+scenario.replace('-', '_'), scenario_test(scenario, scenario in ('slot-busy', 'wrong-slot', 'redirect', 'missing-cluster-id')))

if __name__ == '__main__':
    unittest.main()
