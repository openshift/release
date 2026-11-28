#!/usr/bin/env python3
"""Exercise the image gate and test sequencing without a cluster or registry."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
STEPS = ROOT / 'ci-operator/step-registry/kubevirt/ssp'
# Fake external commands used by the shell scripts. They record call order and
# return canned image, storage and readiness data. SCENARIO injects failures;
# no registry access, deployment or real SSP test execution happens here.
SHIM = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
p=pathlib.Path(os.environ['FIXTURE'])
a=sys.argv[1:]
name=pathlib.Path(sys.argv[0]).name
with (p/'calls').open('a') as f: f.write(json.dumps([name,*a])+'\n')
scenario=os.environ.get('SCENARIO','')
if name=='oc':
    if a[:2]==['image','info']:
        arch='amd64' if scenario=='wrong-arch' else 's390x'
        image={'config':{'architecture':arch,'os':'linux'},'digest':'sha256:'+'a'*64,'listDigest':'sha256:'+'b'*64}
        print(json.dumps([image,image] if scenario=='multiple-members' else [image] if scenario=='array-member' else image))
    elif 'storageclasses' in a:
        items=[] if scenario=='no-storage' else [{'metadata':{'annotations':{'storageclass.kubernetes.io/is-default-class':'true'}},'provisioner':'fixture.dynamic'}]
        print(json.dumps({'items':items}))
    elif 'rollout' in a and scenario=='rollout-failure': sys.exit(5)
    else: print(json.dumps({'status':{'observedVersion':'v1','observedKubeVirtVersion':'v2'}}))
elif name=='make' and a==['functest'] and scenario=='test-failure': sys.exit(7)
elif name=='deploy-kubevirt-and-cdi.sh' and scenario=='dependency-failure': sys.exit(9)
'''

# Each test creates a tiny fake SSP checkout and private/public CI directories.
# Fake oc/make are first on PATH; the scripts under test still run with real bash/jq.
class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        for directory in ['bin','shared','artifacts','automation/common','hack']:
            (self.root/directory).mkdir(parents=True)
        for name in ['bin/oc','bin/make','automation/common/deploy-kubevirt-and-cdi.sh','hack/install-network-policy.sh']:
            p=self.root/name;p.write_text(SHIM);p.chmod(0o755)
        (self.root/'shared/kubeconfig').write_text('fixture')
        self.env=dict(os.environ,FIXTURE=str(self.root),SHARED_DIR=str(self.root/'shared'),ARTIFACT_DIR=str(self.root/'artifacts'),PATH=str(self.root/'bin')+os.pathsep+os.environ['PATH'],CI_OPERATOR_IMG='registry.test:5000/job/operator:latest',CI_VALIDATOR_IMG='registry.test:5000/job/validator@sha256:'+'b'*64)
    # Helpers launch the real shell steps. e2e() first creates the image handoff,
    # matching the prerequisite that the full job has before reaching its test step.
    def run_step(self,step,scenario=''):
        return subprocess.run(['bash',str(STEPS/step)],cwd=self.root,env=dict(self.env,SCENARIO=scenario),capture_output=True,text=True)
    def gate(self,scenario=''):
        return self.run_step('images/check/kubevirt-ssp-images-check-commands.sh',scenario)
    def e2e(self,scenario=''):
        self.assertEqual(self.gate().returncode,0)
        return self.run_step('e2e/kubevirt-ssp-e2e-commands.sh',scenario)
    def calls(self): return [json.loads(s) for s in (self.root/'calls').read_text().splitlines()]
    # Image cases check digest pinning, accepted JSON shapes and architecture rejection.
    def test_pin_preserves_registry_port_for_tag_and_digest(self):
        self.assertEqual(self.gate().returncode,0)
        data=json.loads((self.root/'shared/ssp-images.json').read_text())
        self.assertEqual(data['operator'],'registry.test:5000/job/operator@sha256:'+'a'*64)
        self.assertEqual(data['validator'],'registry.test:5000/job/validator@sha256:'+'a'*64)
    def test_single_array_member(self):
        self.assertEqual(self.gate('array-member').returncode,0)
    def test_ambiguous_members_rejected(self):
        self.assertNotEqual(self.gate('multiple-members').returncode,0)
        self.assertFalse((self.root/'shared/ssp-images.json').exists())
    def test_wrong_architecture_does_not_publish_images(self):
        self.assertNotEqual(self.gate('wrong-arch').returncode,0)
        self.assertFalse((self.root/'shared/ssp-images.json').exists())
    # Test-flow cases check ordering and that failures stop later actions while
    # preserving the failed command exit status in the public result artifact.
    def test_successful_setup_before_tests(self):
        result=self.e2e();self.assertEqual(result.returncode,0,result.stderr)
        calls=self.calls()
        dep=next(i for i,c in enumerate(calls) if c[0]=='deploy-kubevirt-and-cdi.sh')
        self.assertLess(dep,calls.index(['make','deploy']))
        self.assertLess(calls.index(['make','deploy']),calls.index(['make','functest']))
        self.assertEqual(json.loads((self.root/'artifacts/ssp-result.json').read_text()),{'phase':'complete','exit_code':0})
    def test_missing_storage_stops_before_dependency_install(self):
        self.assertNotEqual(self.e2e('no-storage').returncode,0)
        self.assertFalse(any(c[0]=='deploy-kubevirt-and-cdi.sh' for c in self.calls()))
    def test_dependency_failure_stops_deploy(self):
        self.assertEqual(self.e2e('dependency-failure').returncode,9)
        self.assertNotIn(['make','deploy'],self.calls())
    def test_rollout_failure_stops_tests(self):
        self.assertEqual(self.e2e('rollout-failure').returncode,5)
        self.assertNotIn(['make','functest'],self.calls())
    def test_test_failure_retains_status(self):
        self.assertEqual(self.e2e('test-failure').returncode,7)
        self.assertEqual(json.loads((self.root/'artifacts/ssp-result.json').read_text()),{'phase':'functest','exit_code':7})

if __name__=='__main__': unittest.main()
