#!/bin/bash
# Orion Regulus - Dynamic fingerprint-based regression detection for Regulus tests
#
# This step clones the Regulus repo and uses its ORION/analyze-batch.py directly.
# The ORION directory is the single source of truth for the batch analysis logic.
#
# Workflow:
# 1. Set up Python virtualenv
# 2. Clone and install Orion (cloud-bulldozer/orion CLI tool)
# 3. Clone Regulus repo (use ORION/ subdirectory)
# 4. Install ORION dependencies
# 5. Run prow-entry.sh (bridges Prow env vars to analyze-batch.py)
#
set -o nounset
set -o pipefail

MAX_RETRIES=5

echo "=================================="
echo "Orion Regulus - Dynamic Regression Detection"
echo "=================================="
echo ""

python --version
pushd /tmp

# ── Set up Python virtual environment ─────────────────────────────────────────
echo "Setting up Python virtual environment..."
python -m virtualenv ./venv_orion_regulus
source ./venv_orion_regulus/bin/activate

# ── Clone and install Orion CLI ───────────────────────────────────────────────
if [[ "$ORION_TAG" == "latest" ]]; then
    LATEST_TAG=$(git ls-remote --tags "${ORION_REPO}" | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
else
    LATEST_TAG="$ORION_TAG"
fi

echo "Cloning Orion from ${ORION_REPO} (tag: ${LATEST_TAG})..."
for attempt in $(seq 1 "$MAX_RETRIES"); do
  rm -rf orion
  if git clone -q --branch "$LATEST_TAG" "$ORION_REPO" --depth 1; then
    echo "Successfully cloned Orion"
    break
  fi
  if [[ "$attempt" -eq "$MAX_RETRIES" ]]; then
    echo "ERROR: git clone orion failed after $MAX_RETRIES attempts" >&2
    exit 1
  fi
  echo "git clone failed (attempt $attempt/$MAX_RETRIES), retrying in 10s..." >&2
  sleep 10
done

pushd orion
pip install -q --retries "$MAX_RETRIES" -r requirements.txt
pip install -q --retries "$MAX_RETRIES" .
popd

# ── Clone Regulus repo ──────────────────────────────────────────────
echo "Cloning Regulus from ${REGULUS_REPO} (branch: ${REGULUS_BRANCH})..."
for attempt in $(seq 1 "$MAX_RETRIES"); do
  rm -rf regulus
  if git clone -q --branch "${REGULUS_BRANCH}" "${REGULUS_REPO}" --depth 1 regulus; then
    echo "Successfully cloned Regulus"
    break
  fi
  if [[ "$attempt" -eq "$MAX_RETRIES" ]]; then
    echo "ERROR: git clone Regulus failed after $MAX_RETRIES attempts" >&2
    exit 1
  fi
  echo "git clone failed (attempt $attempt/$MAX_RETRIES), retrying in 10s..." >&2
  sleep 10
done

# ── Install ORION dependencies ────────────────────────────────────
pushd regulus/ORION
pip install -q --retries "$MAX_RETRIES" requests pyyaml
echo "✅ Dependencies installed"

# ── Run prow-entry.sh ─────────────────────────────────────────────────────────
echo ""
echo "=================================="
echo "Running Orion Regulus Analysis"
echo "=================================="
echo ""

./scripts/prow-entry.sh
analysis_exit_status=$?

popd
popd

exit $analysis_exit_status
