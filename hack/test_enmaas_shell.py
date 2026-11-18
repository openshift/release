#!/usr/bin/env python3

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STEPS = ROOT / "ci-operator/step-registry/enmaas"
BUILD_ID = "1234567890123456789"
STUB = r'''
import json
import os
from pathlib import Path
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
scenario = os.environ.get("SCENARIO", "normal")
directory = Path(os.environ["SHARED_DIR"])
action = " ".join(args[:2])
with (directory / "calls").open("a") as stream:
    stream.write(json.dumps([command, action]) + "\n")

def fail(code):
    print(f"An error occurred ({code}) when calling the operation", file=sys.stderr)
    sys.exit(254)

def count(name):
    path = directory / name
    value = int(path.read_text()) + 1 if path.exists() else 1
    path.write_text(str(value))
    return value

if command == "openssl":
    print("synthetic-placeholder")
elif command == "jq":
    assert args == ["-r", ".[]"]
    print("\n".join(json.load(sys.stdin)))
elif command == "oc":
    args = [arg for arg in args if not arg.startswith("--request-timeout=")]
    if args[0] == "apply":
        sys.stdin.read()
    elif args[:2] == ["get", "subscription"]:
        if scenario == "csv-transient" and count("subscriptions") < 2:
            sys.exit(17)
        print("installed.v1" if scenario != "csv-unset" else "")
    elif args[:2] == ["get", "csv"]:
        if args[2] == "-n":
            print("clusterserviceversion.operators.coreos.com/cloudnative-pg.old\n"
                  "clusterserviceversion.operators.coreos.com/cloudnative-pg.new")
        else:
            assert args[2] == "installed.v1", args
            print("Succeeded")
    elif args[:2] == ["get", "deployments"]:
        print("synthetic")
    elif "rollout" in args or "wait" in args:
        pass
    elif args[:2] == ["get", "pvc"]:
        if scenario == "pvc-error":
            print("synthetic lookup failure", file=sys.stderr)
            sys.exit(17)
    elif "route" in args or "routes" in args:
        pass
    elif "get" in args and ("statefulsets" in args or "pods" in args):
        pass
    else:
        sys.exit(99)
elif command == "aws":
    if scenario == "auth":
        fail("AccessDenied")
    if action == "rds create-db-subnet-group":
        assert (directory / "rds-subnet-group").read_text().strip() == "enmaas-ci-" + os.environ["BUILD_ID"] + "-subnet-group"
        if scenario == "lost-create":
            fail("RequestTimeout")
        print("synthetic-network-metadata")
    elif action == "ec2 describe-vpcs":
        print("10.0.0.0/16")
    elif action == "ec2 create-security-group":
        if "--tag-specifications" in args:
            build_id = os.environ["BUILD_ID"]
            assert args[args.index("--tag-specifications") + 1] == (
                "ResourceType=security-group,Tags=["
                f"{{Key=Name,Value=enmaas-ci-{build_id}-rds-sg}},"
                f"{{Key=EnMaaS,Value=ci}},{{Key=BuildID,Value={build_id}}}]")
            if scenario == "sg-tag-failure":
                fail("UnauthorizedOperation")
        else:
            assert scenario == "sg-tag-failure"
        print("sg-synthetic")
    elif action == "ec2 create-tags":
        assert scenario == "sg-tag-failure"
        fail("UnauthorizedOperation")
    elif action in ("ec2 authorize-security-group-ingress", "rds create-db-instance"):
        print("synthetic-network-metadata")
    elif action == "rds wait":
        assert args[2] == "db-instance-available"
    elif action == "rds describe-db-instances":
        query = args[args.index("--query") + 1]
        if query.endswith("Endpoint.Address"):
            print("synthetic.internal.invalid")
        elif query.endswith("Endpoint.Port"):
            print(5432)
        elif scenario == "absent":
            fail("DBInstanceNotFound")
        elif query.endswith("DBInstanceArn"):
            print("arn:aws:rds:synthetic:instance")
        elif scenario == "timeout" or (scenario == "deleting" and count("polls") < 2):
            print("deleting")
        else:
            fail("DBInstanceNotFound")
    elif action == "rds describe-db-subnet-groups":
        if scenario == "absent":
            fail("DBSubnetGroupNotFoundFault")
        print("arn:aws:rds:synthetic:subnet")
    elif action in ("rds list-tags-for-resource", "ec2 describe-security-groups"):
        if scenario == "ownership-query-error":
            fail("AccessDenied")
        if scenario == "absent":
            fail("InvalidGroup.NotFound")
        print("other-run" if scenario == "mismatch" else os.environ["BUILD_ID"])
    elif action in ("rds delete-db-instance", "rds delete-db-subnet-group", "ec2 delete-security-group"):
        if scenario == "delete-absent":
            fail({"rds delete-db-instance": "DBInstanceNotFound",
                  "rds delete-db-subnet-group": "DBSubnetGroupNotFoundFault",
                  "ec2 delete-security-group": "InvalidGroup.NotFound"}[action])
        if scenario == "dependency" and action == "ec2 delete-security-group" and count("deletes") < 2:
            fail("DependencyViolation")
        if scenario == "throttled" and count("throttles") < 2:
            fail("ThrottlingException")
        print("synthetic-network-metadata")
    else:
        sys.exit(99)
else:
    sys.exit(99)
'''


class EnmaasShellTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="enmaas shell "))
        self.addCleanup(shutil.rmtree, self.directory)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        for command in ("aws", "oc", "openssl", "jq"):
            path = self.bin / command
            path.write_text(f"#!{sys.executable}\n" + STUB, encoding="utf-8")
            path.chmod(0o755)
        self.environment = {
            "PATH": str(self.bin) + ":/usr/local/bin:/usr/bin:/bin", "HOME": str(self.directory),
            "SHARED_DIR": str(self.directory), "CLUSTER_PROFILE_DIR": str(self.directory),
            "BUILD_ID": BUILD_ID, "VERIFY_TIMEOUT": "1s", "RDS_INSTANCE_CLASS": "db.t3.micro",
            "RDS_ENGINE_VERSION": "16", "RDS_ALLOCATED_STORAGE": "20", "RDS_MASTER_USERNAME": "synthetic",
            "RDS_DB_NAME": "synthetic", "AWS_EC2_METADATA_DISABLED": "true",
        }

    def run_step(self, name, scenario="normal", source=None):
        if source is None:
            source = (STEPS / name / f"enmaas-{name}-commands.sh").read_text(encoding="utf-8")
        prefix = 'set -eu\nsleep() { SECONDS=$((SECONDS + $1)); }; export -f sleep\n'
        return subprocess.run(["bash", "-c", prefix + source], env={**self.environment, "SCENARIO": scenario},
                              capture_output=True, text=True, check=False, timeout=15)

    def recorded_resources(self):
        for name, value in (("instance-id", "synthetic"), ("subnet-group", "synthetic"),
                            ("security-group-id", "sg-synthetic")):
            (self.directory / f"rds-{name}").write_text(value, encoding="utf-8")

    def calls(self):
        path = self.directory / "calls"
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []

    def test_clone_credentials_scoped_and_never_persisted_or_traced(self):
        token = self.directory / "token"
        token.write_text("synthetic-credential-placeholder", encoding="utf-8")
        global_config = self.directory / "gitconfig"
        global_config.write_text("[user]\n\tname = unchanged\n", encoding="utf-8")
        self.environment.update(TEST_TOKEN_FILE=str(token),
                                GIT_CONFIG_GLOBAL=str(global_config), GIT_CONFIG_NOSYSTEM="1",
                                GIT_TERMINAL_PROMPT="0")
        stub = r'''
import os
from pathlib import Path
import subprocess
import sys

arguments = sys.argv[1:]
assert "clone" in arguments
configuration = arguments[:arguments.index("clone")]
token = Path(os.environ["TEST_TOKEN_FILE"]).read_text()
assert all(token not in argument for argument in arguments)
assert configuration[:2] == ["-c", "credential.helper="]
assert "credential.useHttpPath=true" in configuration
key = "credential.https://github.com/redhat-et/EnMaaS-opps.git.helper="
helper = next(argument[len(key):] for argument in configuration if argument.startswith(key))
result = subprocess.run(["/bin/sh", "-c", helper[1:] + " get"], capture_output=True,
                        text=True, check=False)
assert result.returncode == 0
assert token in result.stdout
assert token not in result.stderr
'''
        executable = self.bin / "git"
        executable.write_text(f"#!{sys.executable}\n" + stub, encoding="utf-8")
        executable.chmod(0o755)
        source = (STEPS / "deploy/enmaas-deploy-commands.sh").read_text(encoding="utf-8")
        source = source.split('cd "${WORK_DIR}/EnMaaS-opps"', 1)[0]
        source = source.replace('WORK_DIR=$(mktemp -d)', 'WORK_DIR="$SHARED_DIR"')
        source = source.replace('"/secret/enmaas/token"', '"$TEST_TOKEN_FILE"')
        source = source.replace('cat /secret/enmaas/token', 'cat "$TEST_TOKEN_FILE"')
        self.environment["ENMAAS_BRANCH"] = "synthetic"
        result = self.run_step("deploy", source="set -x\n" + source)
        self.assertEqual(result.returncode, 0, "scoped Git credential checks failed")
        self.assertNotIn(token.read_text(encoding="utf-8"), result.stdout + result.stderr)
        self.assertEqual(global_config.read_text(encoding="utf-8"), "[user]\n\tname = unchanged\n")

    def test_cleanup_ownership_mismatch_never_deletes(self):
        self.recorded_resources()
        result = self.run_step("deprovision-rds", "mismatch")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("delete-", str(self.calls()))
        self.assertEqual(result.stdout.count("mismatch"), 3)

    def test_cleanup_exact_not_found_and_auth_failure(self):
        self.recorded_resources()
        for scenario, expected in (("absent", 0), ("delete-absent", 0), ("auth", 1),
                                   ("ownership-query-error", 1)):
            with self.subTest(scenario=scenario):
                (self.directory / "calls").unlink(missing_ok=True)
                result = self.run_step("deprovision-rds", scenario)
                self.assertEqual(result.returncode, expected, result.stdout)
                if expected:
                    self.assertNotIn("delete-", str(self.calls()))
                    self.assertIn("AccessDenied", result.stdout)

    def test_cleanup_retries_dependencies_transients_and_deletion(self):
        self.recorded_resources()
        for scenario, counter in (("dependency", "deletes"), ("throttled", "throttles"), ("deleting", "polls")):
            with self.subTest(scenario=scenario):
                result = self.run_step("deprovision-rds", scenario)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertGreaterEqual(int((self.directory / counter).read_text(encoding="utf-8")), 2)
                self.assertNotIn("synthetic-network-metadata", result.stdout)

    def test_cleanup_deadline_expires_without_real_sleep(self):
        self.recorded_resources()
        source = (STEPS / "deprovision-rds/enmaas-deprovision-rds-commands.sh").read_text(encoding="utf-8")
        result = self.run_step("deprovision-rds", "timeout", source.replace("SECONDS + 2400", "SECONDS + 2"))
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("delete-db-subnet-group", str(self.calls()))

    def test_missing_resource_files_and_invalid_build_never_delete(self):
        result = self.run_step("deprovision-rds")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.recorded_resources()
        self.environment["BUILD_ID"] = "123-invalid"
        result = self.run_step("deprovision-rds")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), [])

    def test_provision_records_intended_name_and_rejects_invalid_build(self):
        (self.directory / "vpc_id").write_text("vpc-synthetic", encoding="utf-8")
        (self.directory / "private_subnet_ids").write_text("['subnet-synthetic']", encoding="utf-8")
        result = self.run_step("provision-rds", "lost-create")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.directory / "rds-subnet-group").exists())
        self.environment["BUILD_ID"] = "invalid/id"
        (self.directory / "calls").unlink()
        result = self.run_step("provision-rds")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_provision_suppresses_endpoint_network_and_raw_responses(self):
        (self.directory / "vpc_id").write_text("vpc-synthetic", encoding="utf-8")
        (self.directory / "private_subnet_ids").write_text("['subnet-synthetic']", encoding="utf-8")
        result = self.run_step("provision-rds")
        self.assertEqual(result.returncode, 0, result.stderr)
        for value in ("synthetic.internal.invalid", "vpc-synthetic", "sg-synthetic", "10.0.0.0/16",
                      "synthetic-network-metadata", "synthetic-placeholder"):
            self.assertNotIn(value, result.stdout + result.stderr)

    def test_security_group_created_with_exact_tags_without_separate_tag_call(self):
        (self.directory / "vpc_id").write_text("vpc-synthetic", encoding="utf-8")
        (self.directory / "private_subnet_ids").write_text("['subnet-synthetic']", encoding="utf-8")
        result = self.run_step("provision-rds")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.directory / "rds-security-group-id").read_text(encoding="utf-8").strip(),
                         "sg-synthetic")
        actions = [action for command, action in self.calls() if command == "aws"]
        self.assertNotIn("ec2 create-tags", actions)
        self.assertIn("ec2 authorize-security-group-ingress", actions)
        self.assertIn("rds create-db-instance", actions)

    def test_security_group_tag_failure_stops_before_ingress_and_database(self):
        (self.directory / "vpc_id").write_text("vpc-synthetic", encoding="utf-8")
        (self.directory / "private_subnet_ids").write_text("['subnet-synthetic']", encoding="utf-8")
        result = self.run_step("provision-rds", "sg-tag-failure")
        self.assertEqual(result.returncode, 254)
        self.assertIn("UnauthorizedOperation", result.stderr)
        self.assertFalse((self.directory / "rds-security-group-id").exists())
        actions = [action for command, action in self.calls() if command == "aws"]
        self.assertIn("ec2 create-security-group", actions)
        for action in ("ec2 create-tags", "ec2 authorize-security-group-ingress", "rds create-db-instance"):
            self.assertNotIn(action, actions)

    def test_installed_csv_not_grep_and_bounded_unset_status(self):
        result = self.run_step("install-operators")
        self.assertEqual(result.returncode, 0, result.stderr)
        source = (STEPS / "install-operators/enmaas-install-operators-commands.sh").read_text(encoding="utf-8")
        result = self.run_step("install-operators", "csv-unset", source.replace("TIMEOUT=600", "TIMEOUT=2"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Timed out", result.stdout)

    def test_installed_csv_transient_query_recovers(self):
        result = self.run_step("install-operators", "csv-transient")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(int((self.directory / "subscriptions").read_text(encoding="utf-8")), 2)

    def test_pvc_error_not_empty_success(self):
        for scenario, expected in (("normal", 0), ("pvc-error", 17)):
            with self.subTest(scenario=scenario):
                result = self.run_step("verify", scenario)
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected:
                    self.assertIn("synthetic lookup failure", result.stderr)
                    self.assertNotIn("No PVCs found", result.stdout)
                else:
                    self.assertIn("No PVCs found", result.stdout)


if __name__ == "__main__":
    unittest.main()
