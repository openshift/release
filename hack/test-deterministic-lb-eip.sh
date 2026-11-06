#!/bin/bash
# Run locally with: bash hack/test-deterministic-lb-eip.sh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$repo_root/ci-operator/step-registry/hypershift/deterministic-lb-eip-lib/hypershift-deterministic-lb-eip-lib-commands.sh"
reserve="$repo_root/ci-operator/step-registry/hypershift/reserve-deterministic-lb-eip/hypershift-reserve-deterministic-lb-eip-commands.sh"
release="$repo_root/ci-operator/step-registry/hypershift/release-deterministic-lb-eip/hypershift-release-deterministic-lb-eip-commands.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/bin"
cat > "$test_dir/bin/aws" <<'PY'
#!/usr/bin/env python3
import json
import os
import re
import sys


def load():
    """Load the mock EC2 state from AWS_MOCK_STATE."""
    with open(os.environ["AWS_MOCK_STATE"]) as fh:
        return json.load(fh)


def save(state):
    """Persist the mock EC2 state to AWS_MOCK_STATE."""
    with open(os.environ["AWS_MOCK_STATE"], "w") as fh:
        json.dump(state, fh)


def opt(args, name):
    """Return the value following the first occurrence of name."""
    try:
        return args[args.index(name) + 1]
    except (ValueError, IndexError):
        return None


def opts(args, name):
    """Return the values following every occurrence of name."""
    return [args[i + 1] for i, value in enumerate(args) if value == name]


def main():
    """Run the mocked AWS CLI used by the EIP step tests."""
    args = sys.argv[1:]
    try:
        ec2 = args.index("ec2")
    except ValueError:
        return 0
    command = args[ec2 + 1]
    rest = args[ec2 + 2:]
    state = load()
    allocations = state.setdefault("allocations", {})

    if command == "allocate-address":
        tag_spec = opt(rest, "--tag-specifications") or ""
        tags = dict(re.findall(r"Key=([^,}]+),Value=([^,}]+)", tag_spec))
        number = len(allocations) + 1
        allocation_id = f"eipalloc-{number}"
        public_ip = f"192.0.2.{10 + number}"
        allocations[allocation_id] = {
            "public_ip": public_ip,
            "association": None,
            "tags": tags,
        }
        save(state)
        print(f"{allocation_id} {public_ip}")
        return 0

    if command == "describe-addresses":
        if os.environ.get("AWS_MOCK_FAIL_DESCRIBE"):
            print("simulated DescribeAddresses failure", file=sys.stderr)
            return 1

        selected = []
        allocation_id = opt(rest, "--allocation-ids")
        if allocation_id:
            if allocation_id in allocations:
                selected = [(allocation_id, allocations[allocation_id])]
        else:
            run_id = None
            for value in opts(rest, "--filters"):
                match = re.match(r"Name=tag:HypershiftE2ERun,Values=(.+)", value)
                if match:
                    run_id = match.group(1)
            for key, value in allocations.items():
                if run_id is None or value["tags"].get("HypershiftE2ERun") == run_id:
                    selected.append((key, value))

        query = opt(rest, "--query")
        if query == "Addresses[].AllocationId":
            print("\n".join(key for key, _ in selected))
        elif query == "Addresses[0].PublicIp":
            print(selected[0][1]["public_ip"] if selected else "None")
        elif query == "Addresses[0].AssociationId":
            association = selected[0][1]["association"] if selected else None
            print(association if association else "None")
        elif query == "Addresses[0].Tags[?Key==`HypershiftE2ERun`].Value | [0]":
            tag = selected[0][1]["tags"].get("HypershiftE2ERun") if selected else None
            print(tag if tag else "None")
        else:
            print(f"unsupported describe query: {query}", file=sys.stderr)
            return 1
        return 0

    if command == "release-address":
        allocations.pop(opt(rest, "--allocation-id"), None)
        save(state)
        return 0

    print(f"unsupported command: {command}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
PY
chmod +x "$test_dir/bin/aws"
cat > "$test_dir/bin/oc" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$test_dir/bin/oc"

export PATH="$test_dir/bin:$PATH"
export AWS_MOCK_STATE="$test_dir/state.json"
export MGMT_REGION="us-east-1"
export MGMT_PUBLIC_SUBNET="subnet-test"
export AWS_SHARED_CREDENTIALS_FILE="/dev/null"
printf '{"allocations":{}}' > "$AWS_MOCK_STATE"

ensure_lib() {
    local shared_dir="$1"
    mkdir -p "$shared_dir"
    SHARED_DIR="$shared_dir" bash "$lib" >/dev/null
}

run_reserve() {
    local run_id="$1" shared_dir="$2"
    ensure_lib "$shared_dir"
    PROW_JOB_ID="$run_id" SHARED_DIR="$shared_dir" bash "$reserve" >"$shared_dir/reserve.log"
}

run_release() {
    local run_id="$1" shared_dir="$2"
    ensure_lib "$shared_dir"
    PROW_JOB_ID="$run_id" SHARED_DIR="$shared_dir" bash "$release" >"$shared_dir/release.log"
}

allocation_id() {
    sed -n 's/^export EIP_ALLOCATION_ID=//p' "$1/eip.env"
}

state_has() {
    python3 - "$1" "$AWS_MOCK_STATE" <<'PY'
import json
import sys
with open(sys.argv[2]) as fh:
    allocations = json.load(fh)["allocations"]
print("true" if sys.argv[1] in allocations else "false")
PY
}

shared="$test_dir/shared"
mkdir -p "$shared/a" "$shared/b" "$shared/c" "$shared/d" "$shared/a2"

# Two independent executions get distinct allocations. Releasing A must not
# release B, and vice versa.
run_reserve run-a "$shared/a"
A="$(allocation_id "$shared/a")"
run_reserve run-b "$shared/b"
B="$(allocation_id "$shared/b")"
[[ -n "$A" && -n "$B" && "$A" != "$B" ]]
[[ "$(state_has "$A")" == "true" && "$(state_has "$B")" == "true" ]]

run_release run-a "$shared/a"
[[ "$(state_has "$A")" == "false" ]]
[[ "$(state_has "$B")" == "true" ]]
run_release run-b "$shared/b"
[[ "$(state_has "$B")" == "false" ]]

# Recover an allocation made before eip.env was written.
run_reserve run-c "$shared/c"
C="$(allocation_id "$shared/c")"
rm "$shared/c/eip.env"
run_release run-c "$shared/c"
[[ "$(state_has "$C")" == "false" ]]

# No local record and no allocation for this execution: leave another run's
# allocation untouched.
run_reserve run-d "$shared/d"
D="$(allocation_id "$shared/d")"
run_release run-a2 "$shared/a2"
[[ "$(state_has "$D")" == "true" ]]

# A failed lookup is a failure, not "nothing to release".
if AWS_MOCK_FAIL_DESCRIBE=1 run_release run-a2 "$shared/a2" >/dev/null 2>&1; then
    echo "release unexpectedly succeeded when DescribeAddresses failed" >&2
    exit 1
fi

echo "deterministic LB EIP regression checks passed"
