#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

benchmark_artifacts="${ARTIFACT_DIR:?}/mega-benchmark"
mkdir -p "${benchmark_artifacts}"
test "$(git rev-parse HEAD)" = '4ce838f7293c12e6a65f994aa493ac63e3cc2dbb'
test "$(git rev-parse 'HEAD^{tree}')" = 'cfcaa53d8891a7454fad7bdc31cda36a2a150ef9'
git diff --exit-code HEAD --
git ls-files -z > "${benchmark_artifacts}/tracked-files.nul"
test "$(sha256sum "${benchmark_artifacts}/tracked-files.nul" | cut -d ' ' -f 1)" = 'fb95b7390af2c4570a47d29949c0c41294874d72e9365c32938937a13e4a5d4d'
test "$(sha256sum .mega-linter.yml | cut -d ' ' -f 1)" = 'fa366563324d52f28b95b48e6a4d965340645ae88d3d9f6a0acb0d4fad03f6e4'
cp .mega-linter.yml "${benchmark_artifacts}/mega-linter.yml"
cp .yamllint.yml "${benchmark_artifacts}/yamllint.yml"
git ls-files -z | xargs -0 sha256sum > "${benchmark_artifacts}/tracked-content-before.sha256"
printf 'MEGA_BENCHMARK_HOST_CPUS=%s\n' "$(getconf _NPROCESSORS_ONLN)"
# Record container lifecycle events without changing the lint command.
cat > "${benchmark_artifacts}/containers.conf" <<EOF
[engine]
events_logger = "file"
events_logfile_path = "${benchmark_artifacts}/podman-events.log"
EOF
export CONTAINERS_CONF_OVERRIDE="${benchmark_artifacts}/containers.conf"
podman info --format json > "${benchmark_artifacts}/podman-info.json"
python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["host"]["eventLogger"] == "file" else 1)' < "${benchmark_artifacts}/podman-info.json"
printf 'MEGA_BENCHMARK_PULL_START=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
podman pull 'docker.io/oxsecurity/megalinter-ci_light@sha256:54e221da51b3fb959dfd4fc5e21920e0a0fa339ba68e0e9162b894a01a52ed34'
podman tag 'docker.io/oxsecurity/megalinter-ci_light@sha256:54e221da51b3fb959dfd4fc5e21920e0a0fa339ba68e0e9162b894a01a52ed34' docker.io/oxsecurity/megalinter-ci_light:v9
podman image inspect docker.io/oxsecurity/megalinter-ci_light:v9 > "${benchmark_artifacts}/image-inspect.json"
test "$(podman image inspect --format '{{.Digest}}' docker.io/oxsecurity/megalinter-ci_light:v9)" = 'sha256:54e221da51b3fb959dfd4fc5e21920e0a0fa339ba68e0e9162b894a01a52ed34'
image_id="$(podman image inspect --format '{{.Id}}' docker.io/oxsecurity/megalinter-ci_light:v9)"
test "${image_id#sha256:}" = '78f492279a9f2e23e2f59f94a9b03ceadeb33b5fd12818e4a65af2aa41be8af0'
printf 'MEGA_BENCHMARK_PULL_END=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
cat > /tmp/mega-process-inventory.py <<'MEGA_PROCESS_OBSERVER'
#!/usr/bin/env python3
"""Observe actual long-lived MegaLinter argv without changing its invocation.

python3 /tmp/mega-process-inventory.py --output "$ARTIFACT_DIR/mega-benchmark/process-inventory.json" --ready-file /tmp/mega-observer.ready &
observer=$!; ... run unchanged make ...; kill -TERM "$observer"; wait "$observer"

Writes only its output and optional readiness file. Reads Linux /proc cmdline,
stat and cwd; never reads environ or process memory. SIGTERM/SIGINT flush output
and exit 0. Use --duration for a bounded observer instead. A successful observer
exit is not proof of full capture: the analyzer requires both linter inventories
and exact agreement with actual MegaLinter file counts.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import posixpath
import re
import signal
import threading
import time

SCHEMA = "mega-process-inventory/v1"
KEYS = {"shellcheck": "BASH_SHELLCHECK", "yamllint": "YAML_YAMLLINT"}
NOISE = {".git", "megalinter-reports", "mega-linter-reports"}


def identify(argv):
    if not argv:
        return None
    executable = posixpath.basename(argv[0])
    if executable in KEYS:
        return KEYS[executable], 1
    if re.fullmatch(r"python(?:\d+(?:\.\d+)*)?", executable) and len(argv) > 1:
        if posixpath.basename(argv[1]) == "yamllint":
            return KEYS["yamllint"], 2
        if len(argv) > 2 and argv[1:3] == ["-m", "yamllint"]:
            return KEYS["yamllint"], 3
    return None


def normalized_file(argument, cwd):
    value = argument.replace("\\", "/")
    if not value or value == "-":
        return None
    if not value.startswith("/"):
        if not cwd:
            return None
        value = posixpath.join(cwd, value)
    value = posixpath.normpath(value)
    if not value.startswith("/tmp/lint/"):
        return None
    value = value[len("/tmp/lint/"):]
    if any(part in NOISE for part in value.split("/")):
        return None
    return value


def files_from_argv(key, argv, offset, cwd):
    # Exact option arities for the two observed CLI tools. Attached values and
    # --option=value cannot become file operands. In particular, YAML -c config
    # is excluded even though its value is itself a YAML path in the workspace.
    value_options = {"-c", "--config-file", "-d", "--config-data", "-f", "--format"} if key == "YAML_YAMLLINT" else {"-s", "--shell", "-e", "--exclude", "-i", "--include", "-P", "--source-path", "-f", "--format", "-S", "--severity", "-o", "--enable", "--rcfile", "-W", "--wiki-link-count"}
    result, rejected, operands, skip, options = [], [], [], False, True
    for argument in argv[offset:]:
        if skip:
            skip = False
            continue
        if options and argument == "--":
            options = False
            continue
        if options and argument in value_options:
            skip = True
            continue
        if options and argument.startswith("-") and argument != "-":
            continue
        operands.append(argument)
        path = normalized_file(argument, cwd)
        if path is None:
            rejected.append(argument)
        else:
            result.append(path)
    return sorted(set(result)), operands, rejected


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", required=True)
    parser.add_argument("--ready-file")
    parser.add_argument("--interval", type=float, default=0.25)
    parser.add_argument("--duration", type=float, help="Optional maximum observation duration in seconds")
    args = parser.parse_args()
    if args.interval <= 0 or (args.duration is not None and args.duration <= 0):
        parser.error("interval and duration must be positive")
    output = pathlib.Path(args.output).absolute()
    if str(output).startswith(("/tmp/lint/", "/github/workspace/")):
        parser.error("observer output must be outside the lint workspace")
    output.parent.mkdir(parents=True, exist_ok=True)
    stopped = threading.Event()
    stop_signal = []
    def stop(number, _frame):
        stop_signal.append(number)
        stopped.set()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    start, started = time.monotonic(), now()
    observations, errors = {}, {}
    polls = 0
    # Ready is emitted only after handlers/output directory are initialized.
    if args.ready_file:
        ready = pathlib.Path(args.ready_file)
        ready.parent.mkdir(parents=True, exist_ok=True)
        ready.write_text(str(os.getpid()) + "\n")
    while not stopped.is_set():
        tick = time.monotonic()
        polls += 1
        try:
            entries = os.scandir("/proc")
            with entries:
                for entry in entries:
                    if not entry.name.isdigit():
                        continue
                    proc = pathlib.Path("/proc") / entry.name
                    try:
                        raw = (proc / "cmdline").read_bytes()
                        argv = [value.decode("utf-8", "surrogateescape") for value in raw.rstrip(b"\0").split(b"\0")] if raw else []
                        identity = identify(argv)
                        if identity is None:
                            continue
                        key, offset = identity
                        stat = (proc / "stat").read_text()
                        start_ticks = stat[stat.rfind(")") + 2:].split()[19]
                        token = (int(entry.name), start_ticks, hashlib.sha256(raw).hexdigest())
                        timestamp = now()
                        if token in observations:
                            observations[token]["last_seen"] = timestamp
                            observations[token]["samples"] += 1
                            continue
                        cwd = os.readlink(proc / "cwd")
                        files, operands, rejected = files_from_argv(key, argv, offset, cwd)
                        observations[token] = {"pid": int(entry.name), "process_start_ticks": start_ticks, "linter": key,
                            "argv": argv, "argv_sha256": token[2], "cwd": cwd, "first_seen": timestamp, "last_seen": timestamp, "samples": 1,
                            "file_operands": operands, "files": files, "rejected_operands": rejected,
                            "file_count": len(files), "argv_complete": bool(files) and not rejected}
                    except (FileNotFoundError, ProcessLookupError):
                        continue
                    except (PermissionError, OSError, ValueError, IndexError) as error:
                        label = type(error).__name__ + ": " + str(error)
                        errors[label] = errors.get(label, 0) + 1
        except OSError as error:
            errors[str(error)] = errors.get(str(error), 0) + 1
        if args.duration is not None and time.monotonic() - start >= args.duration:
            break
        stopped.wait(max(0, args.interval - (time.monotonic() - tick)))
    captured = sorted(observations.values(), key=lambda row: (row["linter"], row["pid"], row["first_seen"]))
    linters = {}
    for key in KEYS.values():
        rows = [row for row in captured if row["linter"] == key and row["file_operands"]]
        files = sorted({path for row in rows for path in row["files"]})
        linters[key] = {"files": files, "file_count": len(files), "process_count": len(rows),
            "all_argv_complete": bool(rows) and all(row["argv_complete"] for row in rows),
            "files_sha256": hashlib.sha256(json.dumps(files, separators=(",", ":")).encode()).hexdigest()}
    result = {"schema": SCHEMA, "observer_pid": os.getpid(), "started": started, "finished": now(),
        "interval_seconds": args.interval, "polls": polls, "stop_signals": stop_signal,
        "scope": "actual shellcheck/yamllint process file operands under /tmp/lint; config option arguments excluded",
        "coverage_complete": all(row["all_argv_complete"] and row["file_count"] > 0 for row in linters.values()),
        "linters": linters, "observations": captured, "read_errors": errors}
    temporary = output.with_name(output.name + ".tmp." + str(os.getpid()))
    temporary.write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
    os.replace(temporary, output)
    if args.ready_file:
        pathlib.Path(args.ready_file).unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

MEGA_PROCESS_OBSERVER
observer_ready="/tmp/mega-observer.${BASHPID}.ready"
python3 /tmp/mega-process-inventory.py --output "${benchmark_artifacts}/process-inventory.json" --ready-file "${observer_ready}" &
observer_pid=$!
lint_start=''
finish() {
    status=$?
    lint_end="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    printf 'MEGA_BENCHMARK_LINT_END=%s\n' "${lint_end}"
    trap - EXIT
    set +o errexit
    kill -TERM "${observer_pid}"
    wait "${observer_pid}"
    observer_status=$?
    git diff --exit-code HEAD -- > "${benchmark_artifacts}/tracked-diff.patch"
    diff_status=$?
    sha256sum --check "${benchmark_artifacts}/tracked-content-before.sha256" > "${benchmark_artifacts}/tracked-content-check.log"
    content_status=$?
    events_status=not-started
    if [ -n "${lint_start}" ]; then
        podman events --stream=false --since "${lint_start}" --until "${lint_end}" --format json > "${benchmark_artifacts}/container-events.json" 2> "${benchmark_artifacts}/container-events.stderr"
        events_status=$?
    fi
    printf 'container_events_exit=%s\n' "${events_status}" > "${benchmark_artifacts}/container-events-status.txt"
    printf 'lint_exit=%s\nobserver_exit=%s\ntracked_diff_exit=%s\ntracked_content_exit=%s\n' "${status}" "${observer_status}" "${diff_status}" "${content_status}" > "${benchmark_artifacts}/exit-status.txt"
    if (( observer_status != 0 || diff_status != 0 || content_status != 0 )); then
        exit 1
    fi
    exit "${status}"
}
trap finish EXIT
while [ ! -f "${observer_ready}" ]; do
    kill -0 "${observer_pid}"
    sleep 0.05
done
export AZURE_TOKEN_CREDENTIALS=prod
unset GOFLAGS
lint_start="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
printf 'MEGA_BENCHMARK_LINT_START=%s\n' "${lint_start}"
make mega-lint CONTAINER_RUNTIME=podman 2>&1 | tee "${benchmark_artifacts}/make-mega-lint.log"
