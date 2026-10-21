#!/bin/bash

set -euo pipefail

if [[ -f "${SHARED_DIR}/workload_image" ]]; then
  export WORKLOAD_IMAGE
  WORKLOAD_IMAGE="$(cat "${SHARED_DIR}/workload_image")"
fi

echo "=== medik8s system-tests s390x OZ ==="
echo "ECO_TEST_FEATURES: ${ECO_TEST_FEATURES:-<unset>}"
echo "ECO_TEST_LABELS: ${ECO_TEST_LABELS:-<none>}"
echo "ECO_TEST_TIMEOUT: ${ECO_TEST_TIMEOUT:-1h}"
echo "WORKLOAD_IMAGE: ${WORKLOAD_IMAGE:-<unset>}"

if [[ -z "${ECO_TEST_FEATURES:-}" ]]; then
  echo "ERROR: ECO_TEST_FEATURES is required" >&2
  exit 1
fi

# system-tests StopKubeletSSH calls ssh(1) to node InternalIPs. On libvirt OZ
# those IPs are unreachable from the CI pod. We port-forward the in-cluster
# hostNetwork ssh-bastion and force every ssh(1) through it with a PATH wrapper
# (previous ~/.ssh/config Host wildcards were not applied — ssh dialed nodes
# directly and timed out).
cleanup_ssh_bastion_proxy() {
  local sup_pid pf_pid
  # The supervised port-forward loop must die when tests finish; otherwise
  # entrypoint sees an open log pipe and waits until the 3h step timeout
  # (SNR green suites have already failed this way).
  touch /tmp/ssh-bastion-port-forward.stop
  if [[ -f /tmp/ssh-bastion-port-forward.pid ]]; then
    pf_pid="$(cat /tmp/ssh-bastion-port-forward.pid 2>/dev/null || true)"
    if [[ -n "${pf_pid}" ]]; then
      kill "${pf_pid}" 2>/dev/null || true
    fi
  fi
  if [[ -f /tmp/ssh-bastion-port-forward-supervisor.pid ]]; then
    sup_pid="$(cat /tmp/ssh-bastion-port-forward-supervisor.pid 2>/dev/null || true)"
    if [[ -n "${sup_pid}" ]]; then
      kill "${sup_pid}" 2>/dev/null || true
      wait "${sup_pid}" 2>/dev/null || true
    fi
  fi
  pkill -f 'port-forward svc/ssh-bastion' 2>/dev/null || true
  rm -f /tmp/ssh-bastion-port-forward.pid \
    /tmp/ssh-bastion-port-forward-supervisor.pid \
    /tmp/ssh-bastion-port-forward.stop
}
trap cleanup_ssh_bastion_proxy EXIT

setup_ssh_bastion_proxy() {
  local mode host port bastion_key_src bastion_key_dst worker_key_src worker_key_dst wrapper_dir

  if [[ ! -f "${SHARED_DIR}/medik8s_ssh_bastion_mode" ]]; then
    echo "No ssh-bastion marker in SHARED_DIR; skipping SSH proxy setup"
    return 0
  fi

  if ! oc get svc -n test-ssh-bastion ssh-bastion &>/dev/null; then
    echo "WARNING: medik8s_ssh_bastion_mode set but svc/ssh-bastion missing" >&2
    return 0
  fi

  mode="$(cat "${SHARED_DIR}/medik8s_ssh_bastion_mode")"
  # Bastion hop: dedicated key from ssh-bastion step (falls back to cluster key).
  bastion_key_src="${SHARED_DIR}/medik8s_bastion_ssh_key"
  if [[ ! -f "${bastion_key_src}" ]]; then
    bastion_key_src="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  fi
  # Worker hop: cluster install key (present in node authorized_keys).
  worker_key_src="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  if [[ ! -f "${bastion_key_src}" ]]; then
    echo "ERROR: bastion SSH private key not found at ${bastion_key_src}" >&2
    return 1
  fi
  if [[ ! -f "${worker_key_src}" ]]; then
    echo "ERROR: worker SSH private key not found at ${worker_key_src}" >&2
    return 1
  fi

  export HOME="${HOME:-/tmp}"
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  bastion_key_dst="${HOME}/.ssh/medik8s_bastion_key"
  worker_key_dst="${HOME}/.ssh/medik8s_worker_key"
  cp "${bastion_key_src}" "${bastion_key_dst}"
  cp "${worker_key_src}" "${worker_key_dst}"
  chmod 600 "${bastion_key_dst}" "${worker_key_dst}"

  host=""
  port=22
  case "${mode}" in
    lb-hostname|lb-ip)
      host="$(cat "${SHARED_DIR}/medik8s_ssh_bastion_host")"
      ;;
    port-forward)
      host="127.0.0.1"
      port=12222
      # Supervisor: restart port-forward if it dies (API blip, bastion
      # reschedule). Fully detach stdio so entrypoint does not wait on us.
      # Stop via /tmp/ssh-bastion-port-forward.stop from EXIT trap.
      rm -f /tmp/ssh-bastion-port-forward.stop
      (
        attempt=0
        while [[ ! -f /tmp/ssh-bastion-port-forward.stop ]]; do
          attempt=$((attempt + 1))
          echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) starting oc port-forward attempt=${attempt}"
          oc -n test-ssh-bastion port-forward svc/ssh-bastion "${port}:22" &
          pf_pid=$!
          echo "${pf_pid}" > /tmp/ssh-bastion-port-forward.pid
          wait "${pf_pid}" || true
          [[ -f /tmp/ssh-bastion-port-forward.stop ]] && break
          echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) port-forward exited; restarting in 2s"
          sleep 2
        done
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) port-forward supervisor stopped"
      ) >>"${ARTIFACT_DIR}/ssh-bastion-port-forward.log" 2>&1 </dev/null &
      echo $! > /tmp/ssh-bastion-port-forward-supervisor.pid
      for _ in $(seq 1 90); do
        if (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      if ! (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1; then
        echo "ERROR: ssh-bastion port-forward did not become ready on :${port}" >&2
        cat "${ARTIFACT_DIR}/ssh-bastion-port-forward.log" >&2 || true
        return 1
      fi
      echo "SSH bastion port-forward ready on localhost:${port} (supervised restart enabled)"
      ;;
    *)
      echo "WARNING: unknown medik8s_ssh_bastion_mode=${mode}; skipping SSH proxy" >&2
      return 0
      ;;
  esac

  if [[ -z "${host}" ]]; then
    echo "WARNING: empty bastion host for mode=${mode}; skipping SSH proxy" >&2
    return 0
  fi

  wrapper_dir="$(mktemp -d)"
  # Bake bastion coordinates into the wrapper so Go subprocesses do not depend
  # on exported env. Inner hop uses /usr/bin/ssh (not this wrapper).
  # ProxyCommand authenticates to bastion with BASTION_KEY; outer -i uses
  # WORKER_KEY for core@node (cluster install key).
  cat > "${wrapper_dir}/ssh" <<EOF
#!/bin/bash
set -euo pipefail
REAL_SSH=/usr/bin/ssh
BASTION_HOST=${host}
BASTION_PORT=${port}
BASTION_KEY=${bastion_key_dst}
WORKER_KEY=${worker_key_dst}
# Do not re-proxy if caller already set ProxyCommand (or nested hop).
if [[ "\$*" == *ProxyCommand* ]]; then
  exec "\${REAL_SSH}" "\$@"
fi
exec "\${REAL_SSH}" \\
  -o "ProxyCommand=\${REAL_SSH} -p \${BASTION_PORT} -i \${BASTION_KEY} -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p core@\${BASTION_HOST}" \\
  -i "\${WORKER_KEY}" \\
  -o BatchMode=yes \\
  -o StrictHostKeyChecking=no \\
  -o UserKnownHostsFile=/dev/null \\
  "\$@"
EOF
  chmod 755 "${wrapper_dir}/ssh"
  export PATH="${wrapper_dir}:${PATH}"

  echo "SSH bastion proxy configured: mode=${mode} host=${host} port=${port} wrapper=$(command -v ssh)"
  echo "Bastion key: ${bastion_key_src}  Worker key: ${worker_key_src}"

  local worker_ip
  worker_ip="$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  if [[ -n "${worker_ip}" ]]; then
    echo "Verifying SSH via bastion to worker InternalIP ${worker_ip}..."
    if ! ssh -o ConnectTimeout=20 "core@${worker_ip}" 'hostname; systemctl is-active kubelet'; then
      echo "ERROR: bastion-proxied SSH to ${worker_ip} failed; kubelet-stop tests will fail" >&2
      echo "--- port-forward log ---" >&2
      cat "${ARTIFACT_DIR}/ssh-bastion-port-forward.log" >&2 || true
      echo "--- direct bastion login test ---" >&2
      /usr/bin/ssh -vvv -p "${port}" -i "${bastion_key_dst}" \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 "core@${host}" 'echo bastion-ok; id -un' >&2 || true
      return 1
    fi
    echo "Bastion SSH verification succeeded"
  else
    echo "WARNING: no worker InternalIP found for SSH verification" >&2
  fi
}

setup_ssh_bastion_proxy

echo "=== Operator status before tests ==="
oc get csv,subscription,pods -n openshift-workload-availability -o wide || true

# After control-plane remediation / heavy SNR work, the test client often hits
# client-go rate-limiter deadlines and later specs cascade-fail even when pods
# look healthy. For NHC on small libvirt OZ, run the suite in phases with an
# API/node settle between them so resiliency + test_id:69711 can stay in-job.
wait_cluster_settle() {
  local reason="${1:-post-phase}"
  local i not_ready
  echo "=== Cluster settle (${reason}) ==="
  for i in $(seq 1 90); do
    if ! oc get --raw=/readyz >/dev/null 2>&1; then
      echo "API not ready (attempt ${i}/90); sleeping 10s"
      sleep 10
      continue
    fi
    not_ready="$(oc get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}' || true)"
    if [[ -n "${not_ready}" ]]; then
      echo "Nodes not Ready yet: ${not_ready} (attempt ${i}/90)"
      sleep 10
      continue
    fi
    if ! oc -n openshift-workload-availability get deploy node-healthcheck-controller-manager &>/dev/null; then
      break
    fi
    if oc -n openshift-workload-availability wait --for=condition=Available \
      deploy/node-healthcheck-controller-manager --timeout=30s &>/dev/null; then
      echo "API, nodes, and NHC deployment are healthy; cooling down 90s for client rate limiter"
      sleep 90
      return 0
    fi
    sleep 10
  done
  echo "WARNING: settle timed out (${reason}); continuing after 90s cooldown" >&2
  sleep 90
}

# Keep per-phase reports OUT of ARTIFACT_DIR while phases run. test-runner.sh
# does a recursive find for *_testrun.xml under ARTIFACT_DIR and fails with
# "will not overwrite just-created" if prior-phase copies live there.
NHC_PHASE_REPORTS_DIR="${NHC_PHASE_REPORTS_DIR:-/tmp/medik8s-nhc-phases}"

# Snapshot per-phase junit/report XML so later phases cannot erase earlier
# results (ginkgo overwrites nhc_suite_test_junit.xml each run).
preserve_phase_reports() {
  local phase_slug="$1"
  local dest="${NHC_PHASE_REPORTS_DIR}/${phase_slug}"
  mkdir -p "${dest}"
  # Copy whatever the suite just wrote; ignore missing files.
  find "${ARTIFACT_DIR}" -maxdepth 1 -type f \( \
      -name '*_junit.xml' -o -name '*_testrun.xml' -o -name 'junit*.xml' \
    \) -exec cp -f {} "${dest}/" \; 2>/dev/null || true
  echo "Preserved phase reports under ${dest}"
}

# Merge preserved phase reports: for each unique testcase, prefer
# failure > pass > skip so a earlier-phase pass is not shown as skipped
# after a later phase that label-filtered it out.
merge_phased_junit_reports() {
  local phases_dir="${NHC_PHASE_REPORTS_DIR}"
  if [[ ! -d "${phases_dir}" ]]; then
    return 0
  fi
  echo "=== Merging phased NHC junit reports (pass wins over skip) ==="
  python3 - "${phases_dir}" "${ARTIFACT_DIR}" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

phases_dir = Path(sys.argv[1])
artifact_dir = Path(sys.argv[2])

# Higher rank wins when the same testcase appears in multiple phases.
RANK = {"failure": 3, "error": 3, "passed": 2, "skipped": 1}


def status(tc: ET.Element) -> str:
    if tc.find("failure") is not None:
        return "failure"
    if tc.find("error") is not None:
        return "error"
    if tc.find("skipped") is not None:
        return "skipped"
    return "passed"


def case_key(tc: ET.Element) -> str:
    # classname+name uniquely identifies a ginkgo/reportxml case.
    return f"{tc.get('classname') or ''}\0{tc.get('name') or ''}"


def merge_files(paths, out_path: Path, root_tag: str) -> None:
    best: dict[str, ET.Element] = {}
    total_time = 0.0
    for path in paths:
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as exc:
            print(f"Warning: skip unreadable {path}: {exc}", file=sys.stderr)
            continue
        suites = [root] if root.tag == "testsuite" else list(root.findall("testsuite"))
        if root.tag == "testsuites":
            try:
                total_time += float(root.get("time") or 0)
            except ValueError:
                pass
        for suite in suites:
            if root.tag == "testsuite":
                try:
                    total_time += float(suite.get("time") or 0)
                except ValueError:
                    pass
            for tc in suite.findall("testcase"):
                key = case_key(tc)
                st = status(tc)
                prev = best.get(key)
                if prev is None or RANK[st] > RANK[status(prev)]:
                    best[key] = tc

    if not best:
        print(f"No testcases to merge for {out_path.name}")
        return

    tests = len(best)
    failures = sum(1 for tc in best.values() if status(tc) == "failure")
    errors = sum(1 for tc in best.values() if status(tc) == "error")
    skipped = sum(1 for tc in best.values() if status(tc) == "skipped")

    if root_tag == "testsuites":
        root = ET.Element(
            "testsuites",
            {
                "tests": str(tests),
                "failures": str(failures),
                "errors": str(errors),
                "disabled": str(skipped),
                "time": f"{total_time:.6f}",
            },
        )
        suite = ET.SubElement(
            root,
            "testsuite",
            {
                "name": "NHC (phased merge)",
                "tests": str(tests),
                "failures": str(failures),
                "errors": str(errors),
                "skipped": str(skipped),
                "time": f"{total_time:.6f}",
            },
        )
    else:
        root = ET.Element(
            "testsuite",
            {
                "name": "NHC (phased merge)",
                "tests": str(tests),
                "failures": str(failures),
                "errors": str(errors),
                "skipped": str(skipped),
                "time": f"{total_time:.6f}",
            },
        )
        suite = root

    for tc in best.values():
        suite.append(tc)

    ET.ElementTree(root).write(out_path, encoding="utf-8", xml_declaration=True)
    print(
        f"Wrote {out_path.name}: tests={tests} passed={tests - failures - errors - skipped} "
        f"failed={failures + errors} skipped={skipped}"
    )


junit_paths = sorted(phases_dir.glob("*/*_junit.xml"))
testrun_paths = sorted(phases_dir.glob("*/*_testrun.xml"))
if junit_paths:
    # Keep a copy of the last raw junit, then overwrite the canonical name.
    merge_files(junit_paths, artifact_dir / "nhc_suite_test_junit.xml", "testsuites")
if testrun_paths:
    merge_files(testrun_paths, artifact_dir / "report_testrun.xml", "testsuite")
PY
  # Publish raw per-phase reports for debugging only after all make run-tests
  # finished (so test-runner's recursive find cannot see them mid-job).
  mkdir -p "${ARTIFACT_DIR}/nhc-phases"
  cp -a "${phases_dir}/." "${ARTIFACT_DIR}/nhc-phases/" 2>/dev/null || true
}

run_tests_with_labels() {
  local phase_name="$1"
  local labels="$2"
  local phase_slug
  phase_slug="$(echo "${phase_name}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_\{2,\}/_/g;s/^_//;s/_$//')"
  echo "=== Phase: ${phase_name} ==="
  echo "ECO_TEST_LABELS: ${labels}"
  ECO_TEST_LABELS="${labels}" make run-tests
  preserve_phase_reports "${phase_slug}"
}

# Base excludes for this GA-subscribe job (never run upgrade/fresh-install here).
nhc_base_exclude='!tier:upgrade && !tier:upgrade-cluster && !tier:upgrade-operator && !tier:fresh-install'

if [[ "${MEDIK8S_NHC_PHASED_RUN:-}" == "true" && "${ECO_TEST_FEATURES}" == "nhc-operator" ]]; then
  echo "MEDIK8S_NHC_PHASED_RUN=true: running NHC in phases (base → resiliency → 69711)"
  run_tests_with_labels "nhc-base (exclude resiliency + 69711)" \
    "${nhc_base_exclude} && !tier:resiliency && !test_id:69711"
  wait_cluster_settle "after nhc-base"
  run_tests_with_labels "nhc-resiliency" \
    "${nhc_base_exclude} && tier:resiliency"
  wait_cluster_settle "after nhc-resiliency"
  # 69711 remediates a control-plane node; keep it last so cascade cannot
  # poison earlier phases.
  run_tests_with_labels "nhc-69711 (control-plane remediation)" \
    "${nhc_base_exclude} && test_id:69711"
  merge_phased_junit_reports
else
  make run-tests
fi

echo "=== system-tests complete ==="
