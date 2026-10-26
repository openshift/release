#!/usr/bin/env python3
"""Exercise production CI scripts with fake Git, cluster, SSH and download endpoints."""

import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time
import unittest
from contextlib import ExitStack
from unittest import mock

REG = pathlib.Path(__file__).resolve().parents[2] / "ci-operator/step-registry/openshift-qe"
INIT = REG / "microshift-perf-init/openshift-qe-microshift-perf-init-commands.sh"
CYCLE = REG / "microshift-perf-cycle/openshift-qe-microshift-perf-cycle-commands.sh"
NET = REG / "microshift-netperf/openshift-qe-microshift-netperf-commands.sh"
DEPLOY = REG / "microshift-deploy/openshift-qe-microshift-deploy-commands.sh"
CLEAN = REG / "microshift-perf-cleanup/openshift-qe-microshift-perf-cleanup-commands.sh"
SCHED = REG / "installer/bm/self-sched/openshift-qe-installer-bm-self-sched-commands.sh"
TERM = REG / "installer/bm/self-sched-terminate/openshift-qe-installer-bm-self-sched-terminate-commands.sh"
FIXTURE = pathlib.Path(__file__).resolve().parent / "fixtures/e2e-benchmarking"
REAL_JQ = shutil.which("jq")
FAKE = r"""#!/usr/bin/env python3
import io,json,os,pathlib,sys,tarfile,time,gzip,shutil
name=pathlib.Path(sys.argv[0]).name; a=sys.argv[1:];root=pathlib.Path(os.environ['FAKE_ROOT'])
with (root/'calls').open('a') as f:f.write(json.dumps([name,*a])+'\n')
if name=='git':
 d=pathlib.Path(a[1]) if a[0]=='-C' else pathlib.Path(a[-1]);d.mkdir(parents=True,exist_ok=True)
 if 'checkout' in a:
  if d.name=='e2e':
   if os.getenv('FAKE_REAL_WRAPPERS')=='1':
    shutil.copytree(os.environ['FIXTURE_DIR'],d,dirs_exist_ok=True)
    for fixture in d.rglob('*.sh.fixture'):fixture.rename(fixture.with_suffix(''))
   for sub in (() if os.getenv('FAKE_REAL_WRAPPERS')=='1' else ('kube-burner-ocp-wrapper','network-perf-v2')):
    p=d/'workloads'/sub;p.mkdir(parents=True,exist_ok=True)
    (p/'run.sh').write_text((root/(sub+'.sh')).read_text());(p/'run.sh').chmod(0o755)
   if os.getenv('FAKE_NO_SWEEP')!='1':(d/'workloads/kube-burner-ocp-wrapper/sweep.sh').touch()
   (d/'workloads/network-perf-v2/full-run.yaml').write_text('tests: []')
  else:
   p=d/'cmd/config/metrics-profiles';p.mkdir(parents=True,exist_ok=True);(p/'microshift-metrics.yml').write_text('[]')
 if 'rev-parse' in a:print('a'*40)
elif name=='jq':
 if os.getenv('FAKE_WINDOW_WRITER_FAIL')=='1' and 'end_epoch' in a and '--argjson' in a:
  print('partial JSON');sys.exit(73)
 os.execv(os.environ['REAL_JQ'],[os.environ['REAL_JQ'],*a])
elif name=='curl':
 if a[-1].startswith('file://'):
  sys.stdout.buffer.write(pathlib.Path(a[-1][7:]).read_bytes());sys.exit(0)
 if a[-1].endswith('/releases/latest'):
  if os.getenv('FAKE_RELEASE_FAILURE')=='both' or (os.getenv('FAKE_RELEASE_FAILURE') and os.environ['FAKE_RELEASE_FAILURE'] in a[-1]):
   print('HTTP/2 404');sys.exit(22)
  if os.getenv('FAKE_RELEASE_HTTP_FAILURE')=='1':print('HTTP/2 503');sys.exit(22)
  if 'FAKE_RELEASE_HEADERS' in os.environ:print(os.environ['FAKE_RELEASE_HEADERS']);sys.exit(0)
  tag=os.getenv('FAKE_NET_TAG','v0.1.43') if 'k8s-netperf' in a[-1] else os.getenv('FAKE_KB_TAG','v1.12.7')
  print('HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 302\r\nLocation: '+a[-1].removesuffix('/latest')+'/tag/'+tag+'\r\n');sys.exit(0)
 if '/k8s-netperf/releases/' in a[-1]:
  content=(root/'net-binary.py').read_bytes();filename='k8s-netperf'
  stream=io.BytesIO()
  with tarfile.open(fileobj=stream,mode='w') as t:
   info=tarfile.TarInfo(filename);info.size=len(content);info.mode=0o755;t.addfile(info,io.BytesIO(content))
  sys.stdout.buffer.write(gzip.compress(stream.getvalue(),mtime=0));sys.exit(0)
 if a[-1].endswith('/api/v3/login/'):
  print('{"auth_token":"fake-quads-session-token"}')
 elif '/api/v3/available?' in a[-1]:
  print('[]' if os.getenv('FAKE_NO_HOSTS')=='1' else '["n.example"]')
 elif '/instack/' in a[-1]:
  pathlib.Path(a[a.index('-o')+1]).write_text('{"nodes":[{"name":"n.example"}]}');print('200',end='')
 elif '-o' in a:
  content=(root/'kb.py').read_bytes(); info=tarfile.TarInfo('kube-burner-ocp');info.size=len(content);info.mode=0o755
  stream=io.BytesIO()
  with tarfile.open(fileobj=stream,mode='w') as t:t.addfile(info,io.BytesIO(content))
  pathlib.Path(a[a.index('-o')+1]).write_bytes(gzip.compress(stream.getvalue(),mtime=0))
 elif '/api/v1/targets' in a[-1]:
  jobs=['node','process','crio','kubelet-microshift','kubelet-microshift-cadvisor']
  if os.getenv('FAKE_MISSING'):jobs.remove(os.environ['FAKE_MISSING'])
  print(json.dumps({'status':'success','data':{'activeTargets':[{'labels':{'job':j,'instance':'n.example'},'scrapeUrl':'http://'+os.getenv('FAKE_HOST','n.example')+':9100/metrics','health':'down' if j==os.getenv('FAKE_DOWN') else 'up'} for j in jobs]}}))
 else:
  print(json.dumps({'status':'success','data':{'result':[{'metric':{'job':j,'instance':'n.example'},'value':[time.time(),'0' if j==os.getenv('FAKE_UP_ZERO') else '1']} for j in ['node','process','crio','kubelet-microshift','kubelet-microshift-cadvisor']]}}))
elif name in ('oc','kubectl'):
 if 'get' in a and 'pods' in a and 'json' in a and os.getenv('FAKE_POD_PRIORITY')=='1':
  print(json.dumps({'items':[{'metadata':{'name':'pause','namespace':'node-density-0'}},{'metadata':{'name':'dns','namespace':'openshift-dns'}}]}))
 elif 'get' in a and 'pods' in a:print('{"items":[{"metadata":{"name":"system","namespace":"kube-system"}}]}' if 'json' in a else 'system Running')
 elif 'get' in a:print('{}')
elif name=='ssh':
 cmd=a[-1]
 assert cmd!='\\','cleanup passed a literal backslash'
 if os.getenv('FAKE_SSH_FAIL')=='1':sys.exit(255)
 if 'ansible-playbook -i' in cmd and '.perf-install-vars.json' in cmd:
  subprocess=__import__('subprocess');subprocess.run(['bash','-n'],input=cmd,text=True,check=True)
  assert '"${perf_args[@]}"' in cmd
  (root/'ansible-command').write_text(cmd)
  if os.getenv('FAKE_DEPLOY_ANSIBLE_FAIL')=='1':
   print('fake ready.sh startup failure');sys.exit(2)
  print('fake ansible ok')
 elif 'ansible-playbook -i' in cmd and '--start-at-task' in cmd and os.getenv('FAKE_EXEC_INSTALL')=='1':
  sys.exit(__import__('subprocess').run(['bash','-c',cmd]).returncode)
 elif cmd.startswith('mkdir -p ') and os.getenv('FAKE_EXEC_INSTALL')=='1':
  sys.exit(__import__('subprocess').run(['bash','-c',cmd]).returncode)
 elif 'node_checkout_sha' in cmd:
  print('node_checkout_sha='+os.environ['PULL_PULL_SHA']+'\nbinary_git_commit='+os.environ['PULL_PULL_SHA'])
 elif 'Makefile.version' in cmd:print('4.22')
 elif 'rev-parse' in cmd:print(os.environ['PULL_PULL_SHA'])
 elif 'uname -m' in cmd:print('x86_64')
 elif 'microshift version' in cmd:print('gitCommit: '+os.environ['PULL_PULL_SHA'])
 else:print('fake remote ok')
elif name=='ansible-playbook':
 n=os.getenv('FAKE_INSTALL_FAIL_ITERATION')
 if n and any('/iteration-'+n+'/vars.json' in arg for arg in a):
  print('fake ready.sh startup failure');sys.exit(2)
 print('fake reinstall ok')
elif name=='scp':
 src,dst=a[-2:];dst=pathlib.Path(dst)
 if ':/' in src:
  if src.endswith('/ansible'):
   dst=dst/'ansible';dst.mkdir(parents=True,exist_ok=True)
   if not os.getenv('FAKE_NO_MEASUREMENTS') and not (os.getenv('FAKE_NO_INSTALL_MEASUREMENTS')=='1' and '/iteration-2/' in src):(dst/'measurements.ndjson').write_text('{"measurement_type":"startup"}\n')
   (dst/'boot0.txt').write_text('cold start');(dst/'boot1.txt').write_text('warm start')
  else:dst.write_text('fake kubeconfig')
 else:
  p=pathlib.Path(src)
  if p.exists() and p.name.startswith('tmp') and dst.name.endswith('.perf-install-vars.json'):
   (root/'first-install-vars.json').write_text(p.read_text())
  if p.name=='install-vars.json':
   j=json.loads(p.read_text());assert j['manage_repos'] is False;assert j['setup_microshift_host'] is False;assert isinstance(j['build_microshift'],bool);assert isinstance(j['perf_extra_metadata']['iteration'],str)
elif name=='sleep':
 if os.getenv('FAKE_STALL')=='1' and a[0]!='2':time.sleep(60)
"""
KB = r"""#!/usr/bin/env python3
import json,os,pathlib,sys,hashlib
args=sys.argv[1:]
if args[0]!='index':
 record={'args':args,'binary_sha256':hashlib.sha256(pathlib.Path(sys.argv[0]).read_bytes()).hexdigest(),'binary':sys.argv[0]}
 with (pathlib.Path(os.environ['FAKE_ROOT'])/'sweep-binary-calls').open('a') as f:f.write(json.dumps(record)+'\n')
 uuid=args[args.index('--uuid')+1];d=pathlib.Path('collected-metrics-'+uuid);d.mkdir(exist_ok=True)
 (d/'jobSummary.json').write_text('[{"passed":true}]');sys.exit(0)
d=pathlib.Path(next(v.split('=',1)[1] for v in args if v.startswith('--metrics-directory=')))
assert '--step=5s' in args
assert pathlib.Path(next(v.split('=',1)[1] for v in args if v.startswith('--metrics-profile='))).exists()
d.mkdir(parents=True,exist_ok=True);(d/'jobSummary.json').write_text(json.dumps([{'passed':True,'args':args}]))
if os.getenv('FAKE_CORRUPT_WINDOW')=='1':(d.parent/'window-cold.json').write_text('{partial')
"""
SWEEP = r"""#!/bin/bash
set -eu
[[ $QPS_LIST == '2 4 6 8 10 12 14 16 18 20' ]]
[[ $EXTRA_FLAGS == *--pods-per-node=245* && $EXTRA_FLAGS == *--local-indexing* ]]
[[ -z ${ES_SERVER:-} && $KUBE_BURNER_URL == file://* && $KUBE_DIR != /tmp ]]
endpoint=${EXTRA_FLAGS#*--metrics-endpoint=};endpoint=${endpoint%% *}
python3 - "$endpoint" <<'ENDPOINT'
import json,sys
j=json.load(open(sys.argv[1])); assert j[0]['step']=='5s';assert j[0]['indexer']['metricsDirectory']=='collected-metrics-{{.UUID}}'
ENDPOINT
printf '[{"uuid":"%s-qps2","workload":"%s","qps":2,"burst":2,"rc":0,"cleanup_rc":0}]' "$UUID" "$WORKLOAD" > "sweep-$UUID.json"
printf 'fake password: %%s\n' > "sweep-$UUID-qps2.log"
mkdir -p "collected-metrics-$UUID-qps2"
echo '[{"passed":true}]' > "collected-metrics-$UUID-qps2/jobSummary.json"
if [[ ${FAKE_SWEEP_FAIL:-} == "$WORKLOAD" ]]; then exit 7; fi
"""
NETRUN = r"""#!/bin/bash
set -eu
[[ $PLATFORM == microshift && $LOCAL == true && $METRICS == true && $WORKLOAD == full-run.yaml && $NETPERF_VERSION == $(jq -r .netperf_version "$SHARED_DIR/microshift-perf-tools.json") && $NETPERF_VERSION != latest ]]
[[ -z ${ES_INDEX:-} ]]
echo throughput > results.csv
echo fake-binary > k8s-netperf
echo fake-netperf
"""


# Each test exercises a separate production contract in the same fake infrastructure.
class CycleTests(unittest.TestCase):  # pylint: disable=too-many-public-methods
    def setUp(self):
        # Transfer ownership to unittest so the directory lasts through the test.
        with ExitStack() as stack:
            self.root = pathlib.Path(stack.enter_context(tempfile.TemporaryDirectory()))
            self.addCleanup(stack.pop_all().close)
        self.shared = self.root / "shared"
        self.shared.mkdir()
        self.art = self.root / "art"
        self.art.mkdir()
        self.profile = self.root / "cluster"
        self.profile.mkdir()
        (self.profile / "address").write_text("b.example")
        (self.shared / "microshift_node").write_text("n.example")
        (self.shared / "prometheus_url").write_text("http://b.example:9091")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "fake").write_text(FAKE)
        (self.bin / "fake").chmod(0o755)
        for name in ("git", "curl", "oc", "kubectl", "ssh", "scp", "sleep", "ansible-playbook", "jq"):
            (self.bin / name).symlink_to("fake")
        (self.root / "kb.py").write_text(KB)
        (self.root / "kube-burner-ocp-wrapper.sh").write_text(SWEEP)
        (self.root / "network-perf-v2.sh").write_text(NETRUN)
        self.env = dict(
            os.environ,
            PATH=str(self.bin) + ":" + os.environ["PATH"],
            FAKE_ROOT=str(self.root),
            REAL_JQ=REAL_JQ,
            FIXTURE_DIR=str(FIXTURE),
            SHARED_DIR=str(self.shared),
            ARTIFACT_DIR=str(self.art),
            CLUSTER_PROFILE_DIR=str(self.profile),
            ITERATIONS="2",
            COLD_WINDOW="1",
            WARM_WINDOW="1",
            SETTLE_SECONDS="1",
            SWEEP_SLEEP="1",
            SWEEP_CLEANUP_TIMEOUT="1",
            CYCLE_BUDGET_SECONDS="50000",
            MIN_ITERATION_BUDGET_SECONDS="1",
            E2E_REPO="https://example/e2e",
            E2E_VERSION="sweep",
            KUBE_BURNER_VERSION="1.12.7",
            METRICS_PROFILE_REPO="https://example/kb",
            METRICS_PROFILE_REVISION="v1.12.7",
            NETPERF_VERSION="v0.1.43",
            NETPERF_TIMEOUT_SECONDS="10",
            PERF_ES_URL="",
            PERF_ES_INDEX="microshift-perf-v1",
            KUBE_BURNER_ES_INDEX="ripsaw-kube-burner",
            ES_SECRETS_PATH=str(self.root / "missing"),
            PERF_RC="",
            MICROSHIFT_PROMETHEUS_URL="",
            PULL_PULL_SHA="c" * 40,
            BUILD_FROM_PR="true",
            MODEL="R640",
        )
        (self.root / "net-binary.py").write_text("""#!/usr/bin/env python3
import json,os,pathlib,sys
root=pathlib.Path(os.environ['FAKE_ROOT'])
with (root/'native-net-calls').open('a') as f:f.write(json.dumps({'args':sys.argv[1:],'es':os.getenv('ES_SERVER','')})+'\\n')
assert not any(arg.startswith('--index=') for arg in sys.argv[1:])
search=[arg for arg in sys.argv[1:] if arg.startswith('--search=')]
assert search==(['--search='+os.environ['ES_SERVER']] if os.getenv('ES_SERVER') else [])
print('native endpoint '+os.getenv('ES_SERVER',''))
pathlib.Path('results.csv').write_text('throughput,123\\n')
pathlib.Path('results.json').write_text('{"throughput":123}\\n')
print('fake native netperf')
""")

    def propagate(self):
        # ci-operator persists only flat regular files, with a 1MiB aggregate Secret limit.
        entries = list(self.shared.iterdir())
        self.assertTrue(all(p.is_file() and not p.is_symlink() for p in entries), "non-flat handoff")
        self.assertLessEqual(sum(p.stat().st_size for p in entries), 1024 * 1024, "oversized handoff")
        dest = self.root / ("shared-step-" + str(len(list(self.root.glob("shared-step-*")))))
        dest.mkdir()
        for p in entries:
            shutil.copy2(p, dest / p.name)
        self.shared = dest
        self.env["SHARED_DIR"] = str(dest)

    def run_script(self, path, **extra):
        return subprocess.run(
            ["bash", str(path)],
            check=False,
            env=dict(self.env, **extra),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=25,
        )

    def setup_cycle(self):
        r = self.run_script(INIT)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.propagate()
        p = self.shared
        (p / "microshift-perf-deploy.json").write_text(
            json.dumps(
                {
                    "automation_repo": "/tmp/microshift-test",
                    "ansible_inventory": "inventory/custom",
                    "ansible_playbook": "setup-node.yml",
                    "install_vars": {
                        "build_microshift": True,
                        "microshift_git_revision": "c" * 40,
                        "microshift_git_refspec": "+refs/pull/1/head:refs/remotes/origin/pr-1",
                        "microshift_version": "5.0",
                        "prometheus_logging": True,
                        "install_microshift": True,
                    },
                }
            )
        )
        r = self.run_script(NET, NETPERF_STAGE_ONLY="true")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.propagate()

    def test_complete_two_iterations(self):
        self.setup_cycle()
        r = self.run_script(CYCLE)
        self.assertEqual(r.returncode, 0, r.stdout)
        for n in (1, 2):
            p = self.art / f"iteration-{n}"
            self.assertEqual(json.loads((p / "status.json").read_text())["status"], "complete")
            self.assertEqual(json.loads((p / "window-cold.json").read_text())["step_seconds"], 5)
            self.assertTrue((p / "pod-logs.txt").exists())
            self.assertTrue((p / "ansible/measurements.ndjson").exists())
            self.assertTrue((p / "netperf/results.csv").exists())
            self.assertEqual(len(list(p.glob("sweep-*.json"))), 2)
            self.assertTrue((self.art / f"iteration-{n}.tar.gz.sha256").exists())
        self.assertIn("inventory/custom", (self.root / "calls").read_text())
        manifest = json.loads((self.art / "cycle.json").read_text())
        self.assertEqual(manifest["status"], "complete")
        self.assertEqual(manifest["measurement_type"], "report_cycle")
        self.assertEqual([i["id"] for i in manifest["iterations"]], ["1", "2"])
        ids = [run["uuid"] for i in manifest["iterations"] for run in i["workloads"] + i["windows"]] + [
            u for i in manifest["iterations"] for u in i["netperf_uuids"]
        ]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(
            manifest["iterations"][0]["windows"][0], json.loads((self.art / "iteration-1/window-cold.json").read_text())
        )
        self.assertTrue(manifest["iterations"][0]["windows"][0]["all_pods_ready"])
        self.assertEqual(len(manifest["tool_pins"]["pipeline"]["sha256"]), 64)

    def test_failed_qps_invalidates_and_continues(self):
        self.setup_cycle()
        r = self.run_script(CYCLE, FAKE_SWEEP_FAIL="node-density")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertEqual(json.loads((self.art / "cycle.json").read_text())["status"], "incomplete")
        for n in (1, 2):
            j = json.loads((self.art / f"iteration-{n}/status.json").read_text())
            self.assertEqual((j["stage"], j["exit_code"]), ("node-density", 7))
            self.assertFalse((self.art / f"iteration-{n}/netperf").exists())

    def test_down_target(self):
        self.assert_preflight_failure(FAKE_DOWN="kubelet-microshift")

    def test_missing_target(self):
        self.assert_preflight_failure(FAKE_MISSING="process")

    def test_wrong_host(self):
        self.assert_preflight_failure(FAKE_HOST="other.example")

    def test_zero_up(self):
        self.assert_preflight_failure(FAKE_UP_ZERO="crio")

    def assert_preflight_failure(self, **env):
        self.setup_cycle()
        r = self.run_script(CYCLE, **env)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertEqual(json.loads((self.art / "iteration-1/status.json").read_text())["stage"], "cold-preflight")
        self.assertFalse((self.art / "iteration-1/window-cold.json").exists())

    def test_missing_measurements_fails(self):
        self.setup_cycle()
        r = self.run_script(CYCLE, FAKE_NO_MEASUREMENTS="1")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertEqual(json.loads((self.art / "iteration-1/status.json").read_text())["stage"], "artifact-collection")

    def test_insufficient_budget(self):
        self.setup_cycle()
        r = self.run_script(CYCLE, CYCLE_BUDGET_SECONDS="10", MIN_ITERATION_BUDGET_SECONDS="20")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertFalse((self.art / "iteration-1").exists())

    def test_missing_upstream_sweep_fails_before_reservation(self):
        r = self.run_script(INIT, FAKE_NO_SWEEP="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("lacks QPS sweep", r.stdout)

    def test_iteration_cap(self):
        r = self.run_script(INIT, ITERATIONS="6")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("1..5", r.stdout)

    def test_no_credentials_means_no_es_request(self):
        self.setup_cycle()
        j = json.loads((self.art / "microshift-perf-es-status.json").read_text())
        self.assertFalse(j["enabled"])
        self.assertNotIn("amazonaws", (self.root / "calls").read_text())

    def test_endpoint_and_redaction(self):
        self.setup_cycle()
        p = self.shared
        (p / "microshift-perf-es-status.json").write_text('{"enabled":true}')
        (p / "microshift-perf-es-credentials.json").write_text(json.dumps({"username": "testuser", "password": "p:@ss/word"}))
        (p / "microshift-perf-es-url").write_text("https://testuser:p%3A%40ss%2Fword@example")
        cmd = 'source "$SHARED_DIR/microshift-perf-library.sh"; prepare_tools; PROM_URL=http://prom; metrics_endpoint "$SHARED_DIR/endpoint" \'collected-metrics-{{.UUID}}\'; printf "%s\\n" "testuser p:@ss/word p%3A%40ss%2Fword" | redact'
        r = subprocess.run(["bash", "-euo", "pipefail", "-c", cmd], check=False, env=self.env, text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "<redacted> <redacted> <redacted>\n")
        j = json.loads((self.shared / "endpoint").read_text())
        self.assertEqual(len(j), 2)
        self.assertFalse(j[1]["indexer"]["insecureSkipVerify"])

    def test_probe_success_and_bulk_failure_without_network(self):
        script = INIT.read_text().split("<<'PROBE'\n", 1)[1].split("\nPROBE", 1)[0]
        p = self.root / "probe"
        p.mkdir()
        secret = self.root / "secret"
        secret.mkdir()
        (secret / "username").write_text("test")
        (secret / "password").write_text("pass")
        (secret / "host").write_text("example.invalid")

        class Response(io.StringIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                self.close()

        for errors in (False, True):
            response = {"errors": errors, "items": [{"create": {"status": 403 if errors else 201}} for _ in range(1)]}
            opener = mock.Mock()
            opener.open.return_value = Response(json.dumps(response))
            with mock.patch.dict(
                os.environ, dict(self.env, PERF_DIR=str(p), CYCLE_ID="probe", ES_SECRETS_PATH=str(secret),
                                 PERF_HARDWARE="r640", PERF_PLATFORM="BareMetal")
            ), mock.patch("urllib.request.build_opener", return_value=opener):
                # Execute the production block with network/inputs mocked above.
                exec(compile(script, "probe", "exec"), {})  # pylint: disable=exec-used
            self.assertEqual(json.loads((p / "microshift-perf-es-status.json").read_text())["enabled"], not errors)
            self.assertEqual(opener.open.call_count, 1)
            body = opener.open.call_args.args[0].data.decode()
            self.assertIn("microshift-perf-v1", body)
            self.assertNotIn("ripsaw-kube-burner", body)
            self.assertNotIn("k8s-netperf", body)
            probe = json.loads(body.splitlines()[1])
            self.assertEqual((probe["hardware"], probe["platform"]), ("r640", "BareMetal"))

    def test_system_pod_logs_prioritized(self):
        self.setup_cycle()
        r = self.run_script(CYCLE, ITERATIONS="1", FAKE_POD_PRIORITY="1")
        self.assertEqual(r.returncode, 0, r.stdout)
        logs = [json.loads(line) for line in (self.root / "calls").read_text().splitlines() if '"logs"' in line]
        self.assertTrue(logs)
        self.assertEqual(logs[0][logs[0].index("-n") + 1], "openshift-dns")

    def test_manifest_records_selected_model(self):
        self.env["MODEL"] = "R650"
        self.setup_cycle()
        handoff = json.loads((self.shared / "microshift-perf-install-vars.json").read_text())
        self.assertEqual((handoff["perf_hardware"], handoff["perf_platform"]), ("r650", "BareMetal"))
        # The cycle step no longer reads MODEL; init's declaration is the single source.
        r = self.run_script(CYCLE, ITERATIONS="1", MODEL="R999")
        self.assertEqual(r.returncode, 0, r.stdout)
        j = json.loads((self.art / "cycle.json").read_text())
        self.assertEqual((j["hardware"], j["platform"]), ("r650", "BareMetal"))
        self.assertEqual((j["environment"]["hardware"], j["environment"]["platform"]), ("r650", "BareMetal"))
        self.assertEqual(j["expected"]["min_iterations"], 3)

    def test_invalid_model_fails_before_init_side_effects(self):
        for model in ("", "R640 ", "R6/40", "-r640"):
            with self.subTest(model=model):
                r = self.run_script(INIT, MODEL=model)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn("MODEL must be a QUADS model name", r.stdout)
                self.assertFalse((self.shared / "microshift-perf-cycle-id").exists())

    def test_provenance_uses_deploy_handoff(self):
        self.setup_cycle()
        r = self.run_script(CYCLE, BUILD_FROM_PR="false")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("microshift version -o yaml", (self.root / "calls").read_text())

    def test_cycle_package_mode(self):
        self.setup_cycle()
        p = self.shared / "microshift-perf-deploy.json"
        j = json.loads(p.read_text())
        j["install_vars"]["build_microshift"] = False
        j["install_vars"].pop("microshift_git_revision")
        j["install_vars"].pop("microshift_git_refspec")
        p.write_text(json.dumps(j))
        r = self.run_script(CYCLE, BUILD_FROM_PR="false")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_cleanup_and_failure_still_remove_credentials(self):
        for fail in ("0", "1"):
            self.setup_cycle()
            for name in ("microshift-perf-es-credentials.json", "microshift-perf-es-url"):
                (self.shared / name).write_text("private")
            r = self.run_script(CLEAN, FAKE_SSH_FAIL=fail)
            self.assertEqual(r.returncode, 0, r.stdout)
            self.assertFalse((self.shared / "microshift-perf-es-credentials.json").exists())
            self.assertFalse((self.shared / "microshift-perf-es-url").exists())
            self.assertIn("find", (self.root / "calls").read_text())
            # New isolated initialization for the next case.
            self.shared = self.root / ("shared-cleanup-" + fail)
            self.shared.mkdir()
            self.env["SHARED_DIR"] = str(self.shared)
            (self.shared / "microshift_node").write_text("n.example")
            (self.shared / "prometheus_url").write_text("http://b.example:9091")

    def test_full_deploy_perf_handoff_pr_and_package(self):
        for case, build in (("pr", "true"), ("package", "false"), ("es", "true")):
            self.setup_cycle()
            for name in ("lab", "lab_cloud", "login", "pull_secret", "quads_pwd"):
                (self.profile / name).write_text("fake-" + name)
            (self.profile / "quads_instance_fake-lab").write_text("https://quads.example")
            if case == "es":
                (self.shared / "microshift-perf-es-status.json").write_text('{"enabled":true}')
                (self.shared / "microshift-perf-es-credentials.json").write_text(
                    json.dumps(
                        {"username": "ci-test-user", "password": "ci-private-password", "endpoint": "https://example.invalid"}
                    )
                )
            env = {
                "PERF_CYCLE": "true",
                "BUILD_FROM_PR": build,
                "REPO_NAME": "microshift",
                "PULL_NUMBER": "1",
                "MICROSHIFT_BRANCH": "main",
                "ANSIBLE_PLAYBOOK": "setup-node.yml",
                "ANSIBLE_INVENTORY": "inventory/custom",
                "NUM_NODES": "1",
                "MICROSHIFT_VERSION": "4.22",
                "SETUP_MICROSHIFT_HOST": "true",
                "INSTALL_MICROSHIFT": "true",
                "MANAGE_REPOS": "true",
                "PROMETHEUS_LOGGING": "true",
                "VG_NAME": "custom-vg",
                "LVM_DISK": "/dev/custom",
            }
            r = self.run_script(DEPLOY, **env)
            self.assertEqual(r.returncode, 0, r.stdout)
            j = json.loads((self.shared / "microshift-perf-deploy.json").read_text())
            self.assertEqual(j["ansible_inventory"], "inventory/custom")
            self.assertEqual(j["install_vars"]["vg_name"], "custom-vg")
            self.assertEqual(j["install_vars"]["build_microshift"], build == "true")
            self.assertEqual("microshift_git_revision" in j["install_vars"], build == "true")
            v = json.loads((self.root / "first-install-vars.json").read_text())
            self.assertEqual(v["perf_extra_metadata"]["iteration"], "1")
            self.assertEqual("perf_es_credentials_file" in v, case == "es")
            self.assertNotIn("ci-private-password", r.stdout)
            self.assertTrue(v["results_dir"].endswith("/iteration-1/ansible"))
            self.propagate()
            self.shared = self.root / ("shared-deploy-" + case)
            self.shared.mkdir()
            self.env["SHARED_DIR"] = str(self.shared)
            (self.shared / "microshift_node").write_text("n.example")
            (self.shared / "prometheus_url").write_text("http://b.example:9091")

    def test_no_matching_host_creates_no_assignment_and_safe_post(self):
        r = self.run_script(INIT)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.propagate()
        r = self.run_script(NET, NETPERF_STAGE_ONLY="true")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.propagate()
        (self.profile / "quads_pwd").write_text("fake-password")
        (self.profile / "quads_instance_fake-lab").write_text("https://quads.example")
        r = self.run_script(SCHED, LAB="fake-lab", MODEL="R640", NUM_SERVERS="1", FAKE_NO_HOSTS="1")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.propagate()
        for name in ("assignment_id", "lab_cloud", "bastion", "microshift-perf-deploy.json"):
            self.assertFalse((self.shared / name).exists(), name)
        for name in ("microshift-perf-es-credentials.json", "microshift-perf-es-url"):
            (self.shared / name).write_text("private")
        r = self.run_script(CLEAN)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.propagate()
        for name in ("microshift-perf-es-credentials.json", "microshift-perf-es-url"):
            self.assertFalse((self.shared / name).exists())
        r = self.run_script(TERM, LAB="fake-lab")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("assignment_id", r.stdout)
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        self.assertFalse(any("/api/v3/assignments" in arg or "/api/v3/schedules" in arg for call in calls for arg in call))
        self.assertFalse(any(call[0] == "ssh" for call in calls))
        # Current shared terminate is non-destructive but not a successful no-op: it logs in before cat fails.
        self.assertEqual(sum(call[0] == "curl" and call[-1].endswith("/api/v3/login/") for call in calls), 2)

    def test_initial_ansible_startup_failure_stops_deploy(self):
        self.setup_cycle()
        for name in ("lab", "lab_cloud", "login", "pull_secret", "quads_pwd"):
            (self.profile / name).write_text("fake-" + name)
        (self.profile / "quads_instance_fake-lab").write_text("https://quads.example")
        env = {
            "PERF_CYCLE": "true",
            "BUILD_FROM_PR": "true",
            "REPO_NAME": "microshift",
            "PULL_NUMBER": "1",
            "MICROSHIFT_BRANCH": "main",
            "ANSIBLE_PLAYBOOK": "setup-node.yml",
            "ANSIBLE_INVENTORY": "inventory/custom",
            "NUM_NODES": "1",
            "MICROSHIFT_VERSION": "4.22",
            "SETUP_MICROSHIFT_HOST": "true",
            "INSTALL_MICROSHIFT": "true",
            "MANAGE_REPOS": "true",
            "PROMETHEUS_LOGGING": "true",
            "VG_NAME": "custom-vg",
            "LVM_DISK": "/dev/custom",
            "FAKE_DEPLOY_ANSIBLE_FAIL": "1",
        }
        r = self.run_script(DEPLOY, **env)
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("fake ready.sh startup failure", r.stdout)
        self.assertTrue((self.art / "microshift-deploy-diagnostics").is_dir())
        self.assertFalse((self.art / "cycle.json").exists())
        self.assertFalse((self.art / "iteration-1/status.json").exists())

    def assert_install_failure(self, missing=False):
        self.setup_cycle()
        deployment = self.shared / "microshift-perf-deploy.json"
        j = json.loads(deployment.read_text())
        repo = self.root / "automation"
        (repo / "ansible").mkdir(parents=True)
        j["automation_repo"] = str(repo)
        deployment.write_text(json.dumps(j))
        remote = pathlib.Path("/tmp/microshift-perf-" + (self.shared / "microshift-perf-cycle-id").read_text().strip())
        self.addCleanup(lambda: shutil.rmtree(remote, ignore_errors=True))
        r = self.run_script(
            CYCLE,
            ITERATIONS="3",
            FAKE_EXEC_INSTALL="1",
            FAKE_INSTALL_FAIL_ITERATION="2",
            FAKE_NO_INSTALL_MEASUREMENTS="1" if missing else "0",
        )
        self.assertEqual(r.returncode, 1, r.stdout)
        status = json.loads((self.art / "iteration-2/status.json").read_text())
        self.assertEqual((status["status"], status["stage"], status["exit_code"]), ("invalid", "install", 2))
        if missing:
            self.assertIn("no structured Ansible measurements after install failed (exit 2)", r.stdout)
            self.assertNotIn("upstream indexing dependency required", r.stdout)
        self.assertIn("fake ready.sh startup failure", (self.art / "iteration-2/iteration.log").read_text())
        self.assertFalse((self.art / "iteration-2/window-cold.json").exists())
        self.assertFalse((self.art / "iteration-2/netperf").exists())
        for name in ("service-journal.txt", "events.json", "pods.txt", "host-state.txt", "pod-logs.txt"):
            self.assertTrue((self.art / "iteration-2" / name).exists())
        self.assertTrue((self.art / "iteration-2.tar.gz.sha256").exists())
        with tarfile.open(self.art / "iteration-2.tar.gz") as archive:
            bundled = json.load(archive.extractfile("iteration-2/status.json"))
            self.assertEqual(bundled, status)
        self.assertEqual(json.loads((self.art / "iteration-3/status.json").read_text())["status"], "complete")
        manifest = json.loads((self.art / "cycle.json").read_text())
        self.assertEqual(manifest["status"], "incomplete")
        self.assertEqual([i["status"] for i in manifest["iterations"]], ["complete", "invalid", "complete"])
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        self.assertEqual(sum(call[0] == "ansible-playbook" for call in calls), 2)
        fetches = [
            call
            for call in calls
            if call[0] == "scp" and any("root@n.example:/var/lib/microshift/resources/" in arg for arg in call)
        ]
        self.assertEqual(len(fetches), 1, "failed Ansible invocation must skip its kubeconfig fetch")

    def test_ansible_install_failure_retains_partial_collection(self):
        self.assert_install_failure()

    def test_ansible_install_failure_without_measurements_preserves_cause(self):
        self.assert_install_failure(missing=True)

    def test_latest_release_resolution_is_frozen_across_cycle(self):
        self.env.update(KUBE_BURNER_VERSION="latest", NETPERF_VERSION="latest")
        self.setup_cycle()
        pins = json.loads((self.shared / "microshift-perf-tools.json").read_text())
        self.assertEqual(
            (pins["kube_burner_version"], pins["kube_burner_release_tag"], pins["netperf_version"]),
            ("1.12.7", "v1.12.7", "v0.1.43"),
        )
        r = self.run_script(CYCLE, FAKE_RELEASE_FAILURE="both")
        self.assertEqual(r.returncode, 0, r.stdout)
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        resolutions = [call for call in calls if call[0] == "curl" and call[-1].endswith("/releases/latest")]
        self.assertEqual(len(resolutions), 2)
        self.assertTrue(all("--max-time" in call and "--connect-timeout" in call for call in resolutions))
        self.assertFalse(any("Authorization" in arg for call in resolutions for arg in call))
        for call in resolutions:
            self.assertIn("--head", call)
            self.assertNotIn("--location", call)
            self.assertNotIn("--insecure", call)
            self.assertEqual(call[call.index("--max-time") + 1], "20")
            self.assertEqual(call[call.index("--connect-timeout") + 1], "5")
            self.assertTrue(call[-1].startswith("https://github.com/"))
        manifest = json.loads((self.art / "cycle.json").read_text())
        self.assertEqual(manifest["tool_pins"]["kube-burner-ocp"]["release_tag"], "v1.12.7")
        self.assertEqual(manifest["tool_pins"]["k8s-netperf"]["release_tag"], "v0.1.43")
        self.assertEqual(len(manifest["tool_pins"]["k8s-netperf"]["sha256"]), 64)
        self.assertEqual(manifest["tool_pins"]["e2e-benchmarking"]["version"], pins["e2e_sha"])

    def test_explicit_release_pins_bypass_latest_redirect(self):
        self.env.update(KUBE_BURNER_VERSION="v1.12.7", NETPERF_VERSION="0.1.43")
        self.setup_cycle()
        pins = json.loads((self.shared / "microshift-perf-tools.json").read_text())
        self.assertEqual(
            (pins["kube_burner_version"], pins["kube_burner_release_tag"], pins["netperf_version"]),
            ("1.12.7", "v1.12.7", "v0.1.43"),
        )
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        self.assertFalse(any(call[0] == "curl" and call[-1].endswith("/releases/latest") for call in calls))

    def test_latest_resolution_failure_is_clear_and_precedes_reservation(self):
        for project in ("kube-burner-ocp", "k8s-netperf"):
            r = self.run_script(INIT, KUBE_BURNER_VERSION="latest", NETPERF_VERSION="latest", FAKE_RELEASE_FAILURE=project)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("Could not resolve latest release", r.stdout)
            self.assertFalse((self.shared / "assignment_id").exists())
        self.assertNotIn("/api/v3/assignments", (self.root / "calls").read_text())

    def test_latest_redirect_rejects_invalid_headers(self):
        prefix = "https://github.com/kube-burner/kube-burner-ocp/releases/tag/"
        bad = [
            "HTTP/2 302\r\n",
            "HTTP/2 200\r\nLocation: " + prefix + "v1.12.7\r\n",
            "HTTP/2 404\r\nLocation: " + prefix + "v1.12.7\r\n",
            "HTTP/2 302\r\nLocation: http://github.com/kube-burner/kube-burner-ocp/releases/tag/v1.12.7\r\n",
            "HTTP/2 302\r\nLocation: https://github.com.evil.example/kube-burner/kube-burner-ocp/releases/tag/v1.12.7\r\n",
            "HTTP/2 302\r\nLocation: https://github.com/cloud-bulldozer/k8s-netperf/releases/tag/v1.12.7\r\n",
            "HTTP/2 302\r\nLocation: " + prefix + "not-a-version\r\n",
            "HTTP/2 302\r\nLocation: " + prefix + "v1.12.7?query=1\r\n",
            "HTTP/2 302\r\nLocation: " + prefix + "v1.12.7#fragment\r\n",
            "HTTP/2 302\r\nLocation: " + prefix + "v1.12.7/extra\r\n",
            "HTTP/2 302\r\nLocation: " + prefix + "v1.12.7\r\nLocation: " + prefix + "v1.12.7\r\n",
            "HTTP/2 302\r\nLocation: https://github.com:443/kube-burner/kube-burner-ocp/releases/tag/v1.12.7\r\n",
            "HTTP/2 302\r\nLocation: " + prefix + "v1%2e12.7\r\n",
            "malformed response\r\nLocation: " + prefix + "v1.12.7\r\n",
        ]
        for headers in bad:
            with self.subTest(headers=headers):
                r = self.run_script(INIT, KUBE_BURNER_VERSION="latest", FAKE_RELEASE_HEADERS=headers)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn("invalid GitHub release redirect", r.stdout)
                self.assertFalse((self.shared / "microshift-perf-tools.json").exists())
        self.assertNotIn("/api/v3/assignments", (self.root / "calls").read_text())

    def test_latest_redirect_http_failure(self):
        r = self.run_script(INIT, KUBE_BURNER_VERSION="latest", FAKE_RELEASE_HTTP_FAILURE="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("GitHub HEAD request failed", r.stdout)
        self.assertFalse((self.shared / "microshift-perf-tools.json").exists())

    def test_python_minimum_fails_before_init_side_effects(self):
        shim = self.bin / "python3"
        shim.write_text(
            "#!/bin/bash\nif [[ $1 == -c && $2 == *sys.version_info* ]]; then exit 1; fi\nexec "
            + shutil.which("python3")
            + ' "$@"\n'
        )
        shim.chmod(0o755)
        r = self.run_script(INIT)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Python >= 3.9", r.stdout)
        self.assertFalse((self.root / "calls").exists())
        self.assertFalse((self.shared / "microshift-perf-cycle-id").exists())

    def test_jq_reserved_variable_guard(self):
        reserved = "end def as if then else elif reduce foreach try catch label break module import include and or".split()
        pattern = re.compile(r"\$(?:" + "|".join(reserved) + r")\b|--arg(?:json)?\s+(?:" + "|".join(reserved) + r")\b")
        for script in (INIT, CYCLE, NET, DEPLOY, CLEAN, *FIXTURE.rglob("*.sh.fixture")):
            with self.subTest(script=str(script)):
                self.assertIsNone(pattern.search(script.read_text()))

    def test_window_record_under_jq16(self):
        configured = os.environ.get("JQ16")
        if not configured:
            self.skipTest("Set JQ16 to a jq 1.6 executable for compatibility qualification")
        jq16 = shutil.which(configured)
        self.assertIsNotNone(jq16, "JQ16 must name an executable jq 1.6 path")
        self.assertEqual(subprocess.check_output([jq16, "--version"], text=True).strip(), "jq-1.6")
        self.setup_cycle()
        r = self.run_script(CYCLE, ITERATIONS="1", REAL_JQ=str(jq16))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(json.loads((self.art / "iteration-1/window-cold.json").read_text())["phase"], "cold")
        self.assertEqual(json.loads((self.art / "cycle.json").read_text())["status"], "complete")

    def test_window_writer_failure_is_atomic_and_stops_iteration(self):
        self.setup_cycle()
        r = self.run_script(CYCLE, ITERATIONS="1", FAKE_WINDOW_WRITER_FAIL="1")
        self.assertEqual(r.returncode, 1, r.stdout)
        status = json.loads((self.art / "iteration-1/status.json").read_text())
        self.assertEqual((status["stage"], status["exit_code"], status["status"]), ("cold-window-record", 73, "invalid"))
        self.assertFalse((self.art / "iteration-1/window-cold.json").exists())
        self.assertFalse(list((self.art / "iteration-1").glob(".window-*")))
        self.assertFalse(list((self.art / "iteration-1").glob("sweep-*")))
        self.assertEqual(json.loads((self.art / "cycle.json").read_text())["status"], "incomplete")

    def test_malformed_window_fails_job_with_incomplete_manifest(self):
        self.setup_cycle()
        r = self.run_script(CYCLE, ITERATIONS="1", FAKE_CORRUPT_WINDOW="1")
        self.assertNotEqual(r.returncode, 0, r.stdout)
        manifest = json.loads((self.art / "cycle.json").read_text())
        self.assertEqual(manifest["status"], "incomplete")
        self.assertEqual(manifest["iterations"][0]["status"], "invalid")
        self.assertTrue(manifest["artifact_errors"])

    def test_manifest_tolerates_malformed_partial_artifacts(self):
        self.setup_cycle()
        directory = self.art / "iteration-1"
        directory.mkdir()
        (directory / "status.json").write_text("")
        (directory / "window-cold.json").write_text("{")
        (directory / "sweep-partial.json").write_text("[{}]")
        (directory / "measurements.ndjson").write_text('{"kernel":"test"}\n{partial\n')
        (directory / "netperf-sha256.txt").write_text("")
        script = CYCLE.read_text().split("<<'MANIFEST'", 1)[1].split("\n", 1)[1].split("\nMANIFEST", 1)[0]
        with mock.patch("sys.argv", ["manifest", str(self.art), str(self.shared), "1", "1", "n.example", str(CYCLE)]):
            # Execute the production block with network/inputs mocked above.
            exec(compile(script, "manifest", "exec"), {})  # pylint: disable=exec-used
        manifest = json.loads((self.art / "cycle.json").read_text())
        self.assertEqual(manifest["status"], "incomplete")
        self.assertEqual(manifest["iterations"][0]["status"], "invalid")
        self.assertGreaterEqual(len(manifest["artifact_errors"]), 5)
        self.assertEqual(manifest["environment"]["kernel"], "test")
        self.assertEqual((manifest["hardware"], manifest["environment"]["hardware"]), ("r640", "r640"))
        self.assertFalse(list(self.art.glob(".cycle.json.*")))

    def test_upstream_wrapper_fixtures_are_unmodified(self):
        manifest = json.loads((FIXTURE / "source.json").read_text())
        self.assertEqual(manifest["commit"], "449056e2083614240e886c19a956dfb1f002a21d")
        for name, expected in manifest["files"].items():
            self.assertEqual(hashlib.sha256((FIXTURE / (name + ".fixture")).read_bytes()).hexdigest(), expected)

    def test_changed_kube_burner_archive_is_rejected(self):
        self.setup_cycle()
        path = self.shared / "microshift-perf-tools.json"
        manifest = json.loads(path.read_text())
        manifest["kube_burner_archive_sha256"] = "0" * 64
        path.write_text(json.dumps(manifest))
        r = self.run_script(CYCLE)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("archive checksum mismatch", r.stdout)
        self.assertFalse((self.root / "sweep-binary-calls").exists())

    def test_real_wrapper_sweeps_use_verified_archive_every_point(self):
        self.env["FAKE_REAL_WRAPPERS"] = "1"
        self.setup_cycle()
        r = self.run_script(CYCLE, ITERATIONS="1")
        self.assertEqual(r.returncode, 0, r.stdout)
        pins = json.loads((self.shared / "microshift-perf-tools.json").read_text())
        runs = [json.loads(line) for line in (self.root / "sweep-binary-calls").read_text().splitlines()]
        self.assertEqual(len(runs), 20)
        self.assertTrue(all(run["binary_sha256"] == pins["kube_burner_sha256"] for run in runs))
        self.assertTrue(all("/kube-bin/" in run["binary"] for run in runs))
        for workload in ("node-density", "node-density-cni"):
            selected = [run for run in runs if run["args"][0] == workload]
            self.assertEqual(
                [int(next(a.split("=", 1)[1] for a in run["args"] if a.startswith("--qps="))) for run in selected],
                list(range(2, 21, 2)),
            )
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        local_downloads = [call for call in calls if call[0] == "curl" and call[-1].startswith("file://")]
        self.assertEqual(len(local_downloads), 20)
        summary = json.loads((self.art / "cycle.json").read_text())
        self.assertEqual(summary["tool_pins"]["kube-burner-ocp"]["archive_sha256"], pins["kube_burner_archive_sha256"])

    def test_real_netperf_wrapper_uses_default_indexes_and_redacts_credentials(self):
        self.env["FAKE_REAL_WRAPPERS"] = "1"
        self.setup_cycle()
        (self.shared / "microshift-perf-es-credentials.json").write_text(
            '{"username":"private-user","password":"private-pass"}'
        )
        endpoint = "https://private-user:private-pass@es.invalid"
        (self.shared / "microshift-perf-es-url").write_text(endpoint)
        for enabled in (False, True):
            (self.shared / "microshift-perf-es-status.json").write_text(json.dumps({"enabled": enabled}))
            (self.root / "native-net-calls").unlink(missing_ok=True)
            (self.root / "calls").write_text("")
            r = self.run_script(
                NET,
                ES_SERVER="https://ambient-secret@es.invalid",
                ES_INDEX="unsupported",
                ES_METADATA_INDEX="unsupported",
                PROW_JOB_ID="fake-ci",
                JOB_TYPE="presubmit",
                JOB_NAME="pull-ci-test",
                BUILD_ID="1",
                PULL_NUMBER="1",
                REPO_OWNER="openshift",
                REPO_NAME="microshift",
            )
            self.assertEqual(r.returncode, 0, r.stdout)
            native = [json.loads(line) for line in (self.root / "native-net-calls").read_text().splitlines()]
            self.assertEqual(len(native), 1)
            self.assertEqual(native[0]["es"], endpoint if enabled else "")
            self.assertFalse(any(a.startswith("--index=") for a in native[0]["args"]))
            search = [a for a in native[0]["args"] if a.startswith("--search=")]
            self.assertEqual(search, ["--search=" + endpoint] if enabled else [])
            self.assertEqual((self.art / "results.csv").read_text(), "throughput,123\n")
            self.assertEqual(json.loads((self.art / "results.json").read_text()), {"throughput": 123})
            calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
            metadata = [call for call in calls if call[0] == "curl" and "es.invalid" in call[-1]]
            self.assertEqual(len(metadata), 1 if enabled else 0)
            if enabled:
                self.assertIn("/perf_scale_ci/_doc/", metadata[0][-1])
            else:
                self.assertIn("Elastic server is not defined", r.stdout)
            self.assertNotIn("private-pass", r.stdout)
            self.assertNotIn("private-user", r.stdout)
            archived = (self.art / "netperf.log").read_text()
            self.assertNotIn("private-pass", archived)
            self.assertNotIn("private-user", archived)

    def assert_netperf_interrupt(self, cycle=False, bypass_cleanup=False):
        self.setup_cycle()
        (self.shared / "microshift-perf-es-credentials.json").write_text(
            '{"username":"private-user","password":"private-pass"}'
        )
        if bypass_cleanup:
            staged = self.shared / "microshift-perf-netperf.sh"
            staged.write_text(staged.read_text().replace("trap cleanup_netperf EXIT", "trap ':' EXIT"))
        (self.root / "network-perf-v2.sh").write_text(
            '#!/bin/bash\nprintf "throughput,123,private-pass\\n" > partial.csv\nprintf "{\\"value\\":123}\\n" > partial.json\ntouch "$FAKE_ROOT/net-started"\n/bin/sleep 60\n'
        )
        script = CYCLE if cycle else NET
        with subprocess.Popen(
            ["bash", str(script)],
            env=dict(self.env, ITERATIONS="1"),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        ) as process:
            try:
                for _ in range(200):
                    if (self.root / "net-started").exists():
                        break
                    time.sleep(0.05)
                self.assertTrue((self.root / "net-started").exists())
                os.killpg(process.pid, signal.SIGTERM)
                out, _ = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 143, out)
                directory = self.art / "iteration-1/netperf" if cycle else self.art
                self.assertTrue((directory / "partial.csv").exists(), out)
                self.assertEqual((directory / "partial.csv").read_text(), "throughput,123,<redacted>\n")
                self.assertEqual(json.loads((directory / "partial.json").read_text()), {"value": 123})
                if cycle:
                    with tarfile.open(self.art / "iteration-1.tar.gz") as archive:
                        self.assertEqual(
                            archive.extractfile("iteration-1/netperf/partial.csv").read().decode(),
                            "throughput,123,<redacted>\n",
                        )
                    self.assertEqual(json.loads((self.art / "cycle.json").read_text())["status"], "incomplete")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)

    def test_interrupted_netperf_archives_partial_csv(self):
        self.assert_netperf_interrupt()

    def test_interrupted_cycle_archives_partial_netperf_in_bundle(self):
        self.assert_netperf_interrupt(cycle=True)

    def test_cycle_recovers_partial_netperf_when_runner_exit_trap_is_bypassed(self):
        self.assert_netperf_interrupt(cycle=True, bypass_cleanup=True)

    def test_completion_publication_without_network(self):
        script = CYCLE.read_text().split("<<'PUBLISH'\n", 1)[1].split("\nPUBLISH", 1)[0]
        manifest = self.root / "cycle.json"
        manifest.write_text(json.dumps({"cycle_id": "test-cycle", "status": "complete", "measurement_type": "report_cycle"}))
        (self.shared / "microshift-perf-es-credentials.json").write_text(
            json.dumps({"username": "test", "password": "pass", "endpoint": "https://example.invalid"})
        )

        class Response(io.StringIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                self.close()

        opener = mock.Mock()
        opener.open.return_value = Response('{"errors":false,"items":[{"index":{"status":201}}]}')
        with mock.patch("sys.argv", ["publish", str(manifest), str(self.shared), "microshift-perf-v1"]), mock.patch(
            "urllib.request.build_opener", return_value=opener
        ):
            # Execute the production block with network/inputs mocked above.
            exec(compile(script, "publish", "exec"), {})  # pylint: disable=exec-used
        body = opener.open.call_args.args[0].data.decode()
        self.assertIn("report_cycle", body)
        self.assertIn("test-cycle", body)
        self.assertNotIn("ripsaw-kube-burner", body)

    def test_signal_preserves_status_and_bundle(self):
        self.setup_cycle()
        with subprocess.Popen(
            ["bash", str(CYCLE)],
            env=dict(self.env, FAKE_STALL="1"),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        ) as p:
            try:
                for _ in range(100):
                    if '"sleep", "1"' in (self.root / "calls").read_text():
                        break
                    time.sleep(0.05)
                p.send_signal(signal.SIGTERM)
                out, _ = p.communicate(timeout=15)
                self.assertEqual(p.returncode, 143, out)
                self.assertEqual(json.loads((self.art / "iteration-1/status.json").read_text())["status"], "interrupted")
                self.assertTrue((self.art / "iteration-1.tar.gz").exists())
                self.assertEqual(json.loads((self.art / "cycle.json").read_text())["status"], "incomplete")
            finally:
                if p.poll() is None:
                    p.kill()


if __name__ == "__main__":
    unittest.main(verbosity=2)
