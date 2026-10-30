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

# system-tests StopKubeletSSH calls ssh(1) to node addresses. On libvirt OZ
# those addresses are unreachable from the CI pod. The ssh-bastion step starts
# an oc debug jump on a control-plane node; we wrap ssh(1) with ProxyCommand
# that relays TCP through that jump.

cleanup_ssh_bastion_proxy() {
  local jump_ns jump_pod
  if [[ -f "${SHARED_DIR}/medik8s_ssh_jump_ns" && -f "${SHARED_DIR}/medik8s_ssh_jump_pod" ]]; then
    jump_ns="$(cat "${SHARED_DIR}/medik8s_ssh_jump_ns" 2>/dev/null || true)"
    jump_pod="$(cat "${SHARED_DIR}/medik8s_ssh_jump_pod" 2>/dev/null || true)"
    if [[ -n "${jump_ns}" && -n "${jump_pod}" ]]; then
      oc -n "${jump_ns}" delete pod "${jump_pod}" --wait=false --ignore-not-found >/dev/null 2>&1 || true
    fi
  fi
  pkill -f 'oc debug node/' 2>/dev/null || true
}
trap cleanup_ssh_bastion_proxy EXIT

setup_ssh_bastion_proxy() {
  local mode jump_ns jump_pod worker_key_src worker_key_dst wrapper_dir worker_ip

  if [[ ! -f "${SHARED_DIR}/medik8s_ssh_bastion_mode" ]]; then
    echo "No ssh-bastion marker in SHARED_DIR; skipping SSH proxy setup"
    return 0
  fi

  mode="$(cat "${SHARED_DIR}/medik8s_ssh_bastion_mode")"
  worker_key_src="${SHARED_DIR}/medik8s_bastion_ssh_key"
  if [[ ! -f "${worker_key_src}" ]]; then
    worker_key_src="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  fi
  if [[ ! -f "${worker_key_src}" ]]; then
    echo "ERROR: worker SSH private key not found" >&2
    return 1
  fi

  export HOME="${HOME:-/tmp}"
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  worker_key_dst="${HOME}/.ssh/medik8s_worker_key"
  cp "${worker_key_src}" "${worker_key_dst}"
  chmod 600 "${worker_key_dst}"

  case "${mode}" in
    oc-debug-jump)
      if [[ ! -f "${SHARED_DIR}/medik8s_ssh_jump_pod" || ! -f "${SHARED_DIR}/medik8s_ssh_jump_ns" ]]; then
        echo "ERROR: oc-debug-jump mode missing jump pod/namespace markers" >&2
        return 1
      fi
      jump_pod="$(cat "${SHARED_DIR}/medik8s_ssh_jump_pod")"
      jump_ns="$(cat "${SHARED_DIR}/medik8s_ssh_jump_ns")"
      if ! oc -n "${jump_ns}" get pod "${jump_pod}" &>/dev/null; then
        echo "ERROR: SSH jump pod is missing" >&2
        return 1
      fi
      ;;
    # Legacy modes from earlier rehearses (port-forward / LB) are no longer set up.
    port-forward|lb-hostname|lb-ip)
      echo "ERROR: unsupported legacy ssh bastion mode=${mode}; re-run with oc-debug-jump" >&2
      return 1
      ;;
    *)
      echo "WARNING: unknown medik8s_ssh_bastion_mode=${mode}; skipping SSH proxy" >&2
      return 0
      ;;
  esac

  wrapper_dir="$(mktemp -d)"
  # Bake jump coordinates into the wrapper. %h/%p are expanded by ssh(1).
  cat > "${wrapper_dir}/ssh" <<EOF
#!/bin/bash
set -euo pipefail
REAL_SSH=/usr/bin/ssh
JUMP_NS=${jump_ns}
JUMP_POD=${jump_pod}
WORKER_KEY=${worker_key_dst}
if [[ "\$*" == *ProxyCommand* ]]; then
  exec "\${REAL_SSH}" "\$@"
fi
exec "\${REAL_SSH}" \\
  -o "ProxyCommand=oc -n \${JUMP_NS} exec -i \${JUMP_POD} -- chroot /host /bin/bash -c 'exec 3<>/dev/tcp/%h/%p; cat <&3 & cat >&3; wait'" \\
  -i "\${WORKER_KEY}" \\
  -o BatchMode=yes \\
  -o StrictHostKeyChecking=no \\
  -o UserKnownHostsFile=/dev/null \\
  "\$@"
EOF
  chmod 755 "${wrapper_dir}/ssh"
  export PATH="${wrapper_dir}:${PATH}"

  echo "SSH jump proxy configured (mode=${mode})"

  worker_ip="$(oc get nodes -l node-role.kubernetes.io/worker= \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  if [[ -n "${worker_ip}" ]]; then
    echo "Verifying SSH via jump to a worker..."
    if ! ssh -o ConnectTimeout=20 "core@${worker_ip}" 'systemctl is-active kubelet' >/dev/null; then
      echo "ERROR: jump-proxied SSH to worker failed; kubelet-stop tests will fail" >&2
      return 1
    fi
    echo "Bastion SSH verification succeeded"
  else
    echo "WARNING: no worker address found for SSH verification" >&2
  fi
}

setup_ssh_bastion_proxy

echo "=== Operator status before tests ==="
oc get csv,subscription,pods -n openshift-workload-availability >/dev/null \
  && echo "Operators present in openshift-workload-availability" \
  || echo "WARNING: could not list operators" >&2

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
    # Treat Ready,SchedulingDisabled (cordoned) as healthy — remediation may
    # leave a node cordoned while kubelet is fine.
    not_ready="$(oc get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/ {print $1}' || true)"
    if [[ -n "${not_ready}" ]]; then
      echo "Nodes not Ready yet (attempt ${i}/90)"
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
"""Merge phased NHC junit/testrun XML; prefer failure over pass over skip."""

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

phases_dir = Path(sys.argv[1])
artifact_dir = Path(sys.argv[2])

# Higher rank wins when the same testcase appears in multiple phases.
RANK = {"failure": 3, "error": 3, "passed": 2, "skipped": 1}


def status(tc: ET.Element) -> str:
    """Return normalized junit status for a testcase element."""
    if tc.find("failure") is not None:
        return "failure"
    if tc.find("error") is not None:
        return "error"
    if tc.find("skipped") is not None:
        return "skipped"
    return "passed"


def case_key(tc: ET.Element) -> str:
    """Return a stable identity for a ginkgo/reportxml testcase."""
    return f"{tc.get('classname') or ''}\0{tc.get('name') or ''}"


def merge_files(paths, out_path: Path, root_tag: str) -> None:
    """Merge testcases from paths into out_path using RANK precedence."""
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
  local phase_slug rc
  phase_slug="$(echo "${phase_name}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_\{2,\}/_/g;s/^_//;s/_$//')"
  echo "=== Phase: ${phase_name} ==="
  echo "ECO_TEST_LABELS: ${labels}"
  # Keep set +e through return: with set -e, a non-zero return from this
  # function aborts the whole script even when the caller used set +e.
  set +e
  ECO_TEST_LABELS="${labels}" make run-tests
  rc=$?
  preserve_phase_reports "${phase_slug}"
  return "${rc}"
}

# Base excludes for this GA-subscribe job (never run upgrade/fresh-install here).
# Prefer ECO_TEST_LABELS from the job config so version-specific skips (e.g. CSV
# annotation mismatches on 5.0) apply in phased mode too.
nhc_base_exclude="${ECO_TEST_LABELS:-!tier:upgrade && !tier:upgrade-cluster && !tier:upgrade-operator && !tier:fresh-install}"

if [[ "${MEDIK8S_NHC_PHASED_RUN:-}" == "true" && "${ECO_TEST_FEATURES}" == "nhc-operator" ]]; then
  echo "MEDIK8S_NHC_PHASED_RUN=true: running NHC in phases (base → resiliency → 69711)"
  echo "NHC base label filter: ${nhc_base_exclude}"
  phase_rc=0
  set +e
  run_tests_with_labels "nhc-base (exclude resiliency + 69711)" \
    "${nhc_base_exclude} && !tier:resiliency && !test_id:69711"
  rc=$?
  set -e
  [[ "${rc}" -ne 0 ]] && phase_rc="${rc}"
  wait_cluster_settle "after nhc-base"
  set +e
  run_tests_with_labels "nhc-resiliency" \
    "${nhc_base_exclude} && tier:resiliency"
  rc=$?
  set -e
  [[ "${phase_rc}" -eq 0 && "${rc}" -ne 0 ]] && phase_rc="${rc}"
  wait_cluster_settle "after nhc-resiliency"
  # 69711 remediates a control-plane node; keep it last so cascade cannot
  # poison earlier phases.
  set +e
  run_tests_with_labels "nhc-69711 (control-plane remediation)" \
    "${nhc_base_exclude} && test_id:69711"
  rc=$?
  set -e
  [[ "${phase_rc}" -eq 0 && "${rc}" -ne 0 ]] && phase_rc="${rc}"
  merge_phased_junit_reports
  if [[ "${phase_rc}" -ne 0 ]]; then
    echo "ERROR: one or more NHC phases failed (first non-zero rc=${phase_rc})" >&2
    exit "${phase_rc}"
  fi
else
  make run-tests
fi

echo "=== system-tests complete ==="
