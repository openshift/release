#!/bin/bash
# ---------------------------------------------------------------------------
# Run PTP CI tests inside a telco-runner container against an existing cluster.
#
# Builds a local telco-runner image (if needed) and launches the CI test
# script inside it with your KUBECONFIG mounted in. This matches the real
# CI environment and avoids macOS compatibility issues.
#
# Setup:
#   ln -sf $(realpath run-in-container.sh) ~/bin/ptp-ci
#
# Usage:
#   ptp-ci --mode oc
#   ptp-ci --test-repo https://github.com/myuser/ptp-operator.git --test-branch my-fix
#   ptp-ci --build-image          # force rebuild the telco-runner image
#   ptp-ci --version 4.22 --downstream --mode bc
#   ptp-ci --remote user@myhost.example.com --mode oc
#
# Prerequisites:
#   - podman (with podman machine running on macOS)
#   - KUBECONFIG for the target cluster
# ---------------------------------------------------------------------------

set -euo pipefail

# Resolve symlinks to find the real script directory
_self="${BASH_SOURCE[0]}"
while [[ -L "$_self" ]]; do
  _link="$(readlink "$_self")"
  if [[ "$_link" == /* ]]; then _self="$_link"; else _self="$(dirname "$_self")/$_link"; fi
done
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"

IMAGE_NAME="ptp-ci-runner:latest"

# ---- Defaults (override with flags or env vars) ----
: "${T5CI_VERSION:=5.0}"
: "${T5CI_DEPLOY_UPSTREAM:=true}"
: "${KUBECONFIG:=$HOME/.kube/kubeconfig.hv11}"
: "${REMOTE_HOST:=kni@hv11.telco5gran.eng.rdu2.redhat.com}"
: "${TEST_REPO:=https://github.com/k8snetworkplumbingwg/ptp-operator.git}"
: "${TEST_BRANCH:=main}"
: "${PTP_REPO:=}"
: "${PTP_UNDER_TEST_BRANCH:=}"
: "${DAEMON_REPO:=}"
: "${CEP_REPO:=}"
: "${TEST_MODES_OVERRIDE:=}"
: "${SKIP_BUILD_IMAGES:=true}"
: "${SKIP_DEPLOY:=true}"
: "${SKIP_WAIT:=true}"
BUILD_IMAGE=false

# ---- Parse flags ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)          T5CI_VERSION="$2"; shift 2 ;;
    --kubeconfig)       KUBECONFIG="$2"; shift 2 ;;
    --upstream)         T5CI_DEPLOY_UPSTREAM=true; shift ;;
    --downstream)       T5CI_DEPLOY_UPSTREAM=false; shift ;;
    --test-repo)        TEST_REPO="$2"; shift 2 ;;
    --test-branch)      TEST_BRANCH="$2"; shift 2 ;;
    --ptp-repo)         PTP_REPO="$2"; shift 2 ;;
    --ptp-branch)       PTP_UNDER_TEST_BRANCH="$2"; shift 2 ;;
    --mode)             TEST_MODES_OVERRIDE="$2"; shift 2 ;;
    --skip-build)       SKIP_BUILD_IMAGES="$2"; shift 2 ;;
    --skip-deploy)      SKIP_DEPLOY="$2"; shift 2 ;;
    --skip-wait)        SKIP_WAIT="$2"; shift 2 ;;
    --build-and-deploy) SKIP_BUILD_IMAGES=false; SKIP_DEPLOY=false; shift ;;
    --build-image)      BUILD_IMAGE=true; shift ;;
    --remote)           REMOTE_HOST="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^# --/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---- Detect architecture ----
# Go/ginkgo crash under QEMU x86_64 emulation on ARM Macs.
# On ARM, all podman operations run on a remote x86_64 host via SSH.
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == "arm64" || "$HOST_ARCH" == "aarch64" ]]; then
  USE_REMOTE=true
  PODMAN="ssh $REMOTE_HOST podman"
else
  USE_REMOTE=false
  PODMAN="podman"
fi

# ---- Get telco-runner image: pull first, build as fallback ----
REMOTE_IMAGE="registry.ci.openshift.org/ci/telco-runner:latest"
if [[ "$BUILD_IMAGE" == "true" ]]; then
  echo "Building telco-runner image (--build-image forced)..."
  if [[ "$USE_REMOTE" == "true" ]]; then
    REMOTE_BUILD_DIR="$(ssh "$REMOTE_HOST" mktemp -d /tmp/ptp-ci-build.XXXXXX)"
    scp -q "$SCRIPT_DIR/Dockerfile.telco-runner" "$REMOTE_HOST:$REMOTE_BUILD_DIR/"
    ssh "$REMOTE_HOST" "cd $REMOTE_BUILD_DIR && podman build --no-cache -t $IMAGE_NAME -f Dockerfile.telco-runner . && rm -rf $REMOTE_BUILD_DIR"
  else
    podman build --no-cache -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile.telco-runner" "$SCRIPT_DIR" --platform linux/amd64
  fi
elif ! $PODMAN image exists "$IMAGE_NAME" 2>/dev/null; then
  echo "Pulling telco-runner image from CI registry..."
  if $PODMAN pull "$REMOTE_IMAGE" 2>/dev/null && $PODMAN tag "$REMOTE_IMAGE" "$IMAGE_NAME" 2>/dev/null; then
    echo "Image pulled: $IMAGE_NAME"
  else
    echo "Pull failed (auth or network issue). Building locally..."
    if [[ "$USE_REMOTE" == "true" ]]; then
      REMOTE_BUILD_DIR="/tmp/ptp-ci-build-$$"
      ssh "$REMOTE_HOST" "mkdir -p $REMOTE_BUILD_DIR"
      scp -q "$SCRIPT_DIR/Dockerfile.telco-runner" "$REMOTE_HOST:$REMOTE_BUILD_DIR/"
      ssh "$REMOTE_HOST" "cd $REMOTE_BUILD_DIR && podman build -t $IMAGE_NAME -f Dockerfile.telco-runner . && rm -rf $REMOTE_BUILD_DIR"
    else
      podman build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile.telco-runner" "$SCRIPT_DIR" --platform linux/amd64
    fi
    echo "Image built: $IMAGE_NAME"
  fi
fi

# ---- Prepare artifacts directory ----
ARTIFACTS_DIR="${HOME}/ptp-ci-results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ARTIFACTS_DIR"

# ---- Build the env vars to pass into the container ----
ENV_ARGS=(
  -e "T5CI_VERSION=${T5CI_VERSION}"
  -e "T5CI_DEPLOY_UPSTREAM=${T5CI_DEPLOY_UPSTREAM}"
  -e "TEST_REPO=${TEST_REPO}"
  -e "TEST_BRANCH=${TEST_BRANCH}"
)
[[ -n "$PTP_REPO" ]] && ENV_ARGS+=(-e "PTP_REPO=${PTP_REPO}")
[[ -n "$PTP_UNDER_TEST_BRANCH" ]] && ENV_ARGS+=(-e "PTP_UNDER_TEST_BRANCH=${PTP_UNDER_TEST_BRANCH}")
[[ -n "$DAEMON_REPO" ]] && ENV_ARGS+=(-e "DAEMON_REPO=${DAEMON_REPO}")
[[ -n "$CEP_REPO" ]] && ENV_ARGS+=(-e "CEP_REPO=${CEP_REPO}")

# ---- Build the container entrypoint script ----
# This script runs inside the container, sets up SHARED_DIR/ARTIFACT_DIR,
# and then sources the CI commands script.
ENTRYPOINT_SCRIPT="${ARTIFACTS_DIR}/entrypoint.sh"
cat > "$ENTRYPOINT_SCRIPT" << 'ENTRY'
#!/bin/bash
set -euo pipefail

export SHARED_DIR=/tmp/shared
export ARTIFACT_DIR=/tmp/artifacts
CI_SCRIPT=/tmp/ci-commands.sh
mkdir -p "$SHARED_DIR" "$ARTIFACT_DIR"

# Copy mounted kubeconfig and CI script to writable locations
cp /kubeconfig "$SHARED_DIR/kubeconfig"
cp /ci-script/telco5g-ptp-tests-commands.sh "$CI_SCRIPT"
export KUBECONFIG="$SHARED_DIR/kubeconfig"

# Source Go and prevent GOTOOLCHAIN auto-download (crashes under QEMU).
# The CI's run-functests.sh hardcodes "source $HOME/golang-1.22.4", so we
# overwrite that file to point to the latest Go version available.
if [[ -f "$HOME/golang-1.25.0" ]]; then
  cp "$HOME/golang-1.25.0" "$HOME/golang-1.22.4"
  source "$HOME/golang-1.22.4"
else
  source "$HOME/golang-1.22.4"
fi
export GOTOOLCHAIN=local

ENTRY

# Add skip logic — all sed commands operate on the writable copy
if [[ "$SKIP_BUILD_IMAGES" == "true" ]]; then
  cat >> "$ENTRYPOINT_SCRIPT" << 'SKIP_BUILD'
sed -i 's/^build_images$/echo "[SKIP] build_images"/' "$CI_SCRIPT"
SKIP_BUILD
fi

if [[ "$SKIP_DEPLOY" == "true" ]]; then
  cat >> "$ENTRYPOINT_SCRIPT" << 'SKIP_DEPLOY'
sed -i '/^echo "Cloning ptp-operator/,/^retry_with_timeout.*rollout status.*linuxptp-daemon/s/^/#SKIP# /' "$CI_SCRIPT"
sed -i '/^# Enable PTP events/,/^fi$/s/^/#SKIP# /' "$CI_SCRIPT"
sed -i '/^mkdir ~\/bin$/,/^oc version --client$/s/^/#SKIP# /' "$CI_SCRIPT"
SKIP_DEPLOY
fi

if [[ "$SKIP_WAIT" == "true" ]]; then
  cat >> "$ENTRYPOINT_SCRIPT" << 'SKIP_WAIT'
sed -i 's/^sleep 300.*$/sleep 5/' "$CI_SCRIPT"
SKIP_WAIT
fi

# Override TEST_MODES if specified
if [[ -n "${TEST_MODES_OVERRIDE:-}" ]]; then
  IFS=',' read -ra modes <<< "$TEST_MODES_OVERRIDE"
  modes_str=$(printf '"%s" ' "${modes[@]}")
  cat >> "$ENTRYPOINT_SCRIPT" << MODES
# Patch: override TEST_MODES
sed -i 's/TEST_MODES=("tgm" "tbc" "dualfollower" "dualnicbc" "dualnicbcha" "bc" "oc")/TEST_MODES=(${modes_str})/' "\$CI_SCRIPT"
MODES
fi

[[ -n "${TEST_MODES_OVERRIDE:-}" ]] && ENV_ARGS+=(-e "TEST_MODES_OVERRIDE=${TEST_MODES_OVERRIDE}")

# Add the actual execution
cat >> "$ENTRYPOINT_SCRIPT" << 'RUN'

# Run the CI script (writable copy)
cd /tmp
exec bash "$CI_SCRIPT"
RUN

chmod +x "$ENTRYPOINT_SCRIPT"

echo "==========================================================="
echo " PTP CI Container Runner"
echo "==========================================================="
echo " T5CI_VERSION:    $T5CI_VERSION"
echo " UPSTREAM:        $T5CI_DEPLOY_UPSTREAM"
echo " KUBECONFIG:      $KUBECONFIG"
echo " TEST_REPO:       $TEST_REPO"
echo " TEST_BRANCH:     $TEST_BRANCH"
echo " SKIP_BUILD:      $SKIP_BUILD_IMAGES"
echo " SKIP_DEPLOY:     $SKIP_DEPLOY"
echo " Image:           $IMAGE_NAME"
echo " Artifacts:       $ARTIFACTS_DIR"
echo "==========================================================="

# ---- Run the container ----
if [[ "$USE_REMOTE" == "true" ]]; then
  echo "Running container on remote x86_64 host: $REMOTE_HOST"

  REMOTE_DIR="/tmp/ptp-ci-$(date +%s)"
  ssh "$REMOTE_HOST" "mkdir -p $REMOTE_DIR/artifacts"
  scp -q "$KUBECONFIG" "$REMOTE_HOST:$REMOTE_DIR/kubeconfig"
  scp -q "$ENTRYPOINT_SCRIPT" "$REMOTE_HOST:$REMOTE_DIR/entrypoint.sh"
  scp -rq "$SCRIPT_DIR/telco5g-ptp-tests-commands.sh" "$REMOTE_HOST:$REMOTE_DIR/"

  # Build image on remote if needed
  if ! ssh "$REMOTE_HOST" "podman image exists $IMAGE_NAME 2>/dev/null"; then
    echo "Building telco-runner image on remote host..."
    scp -q "$SCRIPT_DIR/Dockerfile.telco-runner" "$REMOTE_HOST:$REMOTE_DIR/"
    ssh "$REMOTE_HOST" "cd $REMOTE_DIR && podman build -t $IMAGE_NAME -f Dockerfile.telco-runner ."
  fi

  # Run on remote
  ENV_STR=""
  for e in "${ENV_ARGS[@]}"; do ENV_STR+=" $e"; done
  ssh -t "$REMOTE_HOST" "podman run --rm -it \
    -v $REMOTE_DIR/kubeconfig:/kubeconfig:ro \
    -v $REMOTE_DIR/telco5g-ptp-tests-commands.sh:/ci-script/telco5g-ptp-tests-commands.sh:ro \
    -v $REMOTE_DIR/entrypoint.sh:/entrypoint.sh:ro \
    -v $REMOTE_DIR/artifacts:/tmp/artifacts \
    $ENV_STR \
    $IMAGE_NAME \
    bash /entrypoint.sh" || true
  status=${PIPESTATUS[0]:-$?}

  # Copy artifacts back
  scp -rq "$REMOTE_HOST:$REMOTE_DIR/artifacts/*" "$ARTIFACTS_DIR/" 2>/dev/null || true
  echo "Remote artifacts: $REMOTE_HOST:$REMOTE_DIR/artifacts/"
else
  podman run --rm -it \
    -v "$KUBECONFIG":/kubeconfig:ro \
    -v "$SCRIPT_DIR":/ci-script:ro \
    -v "$ENTRYPOINT_SCRIPT":/entrypoint.sh:ro \
    -v "$ARTIFACTS_DIR":/tmp/artifacts \
    "${ENV_ARGS[@]}" \
    "$IMAGE_NAME" \
    bash /entrypoint.sh || true
  status=${PIPESTATUS[0]:-$?}
fi

echo ""
echo "==========================================================="
echo " Results"
echo "==========================================================="
echo " Exit code: $status"
echo " Artifacts: $ARTIFACTS_DIR/"
echo " JUnit:     $(ls "$ARTIFACTS_DIR"/test_results_*.xml 2>/dev/null | tr '\n' ' ')"
echo "==========================================================="

exit "$status"
