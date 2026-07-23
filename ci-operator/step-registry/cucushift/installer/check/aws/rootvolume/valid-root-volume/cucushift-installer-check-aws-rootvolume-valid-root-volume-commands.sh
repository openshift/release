#!/bin/bash

# OCP-86185 - AWS gp3 Root Volume Throughput Boundary Validation

set -o errexit
set -o pipefail
set -o nounset

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

# Get SSH public key and pull secret
SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

WORK_DIR="/tmp/test-gp3-boundary"
CONFIG_DIR="${WORK_DIR}"
CONFIG="${CONFIG_DIR}/install-config.yaml"
BACKUP_DIR="${CONFIG_DIR}/backups"
mkdir -p "${CONFIG_DIR}" "${BACKUP_DIR}"

PASSED=0
FAILED=0

# Create base install-config.yaml
cat > "${CONFIG}" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  aws:
    region: ${REGION}
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF

# Backup base config
cp "${CONFIG}" "${BACKUP_DIR}/base-install-config.yaml"

# Print openshift-install version for debugging
openshift-install version

# Test Step 1: Below minimum boundary (124)
echo "Step 1: Test just below minimum boundary (124)"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step1-patch.yaml" << EOF
platform:
  aws:
    defaultMachinePlatform:
      rootVolume:
        type: gp3
        size: 120
        throughput: 124
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step1-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput must be between 125.*2000"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 2: Above maximum boundary (2001)
echo "Step 2: Test just above maximum boundary (2001)"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step2-patch.yaml" << EOF
platform:
  aws:
    defaultMachinePlatform:
      rootVolume:
        type: gp3
        size: 120
        throughput: 2001
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step2-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput must be between 125.*2000"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 3: Throughput zero
echo "Step 3: Test throughput value zero"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step3-patch.yaml" << EOF
platform:
  aws:
    defaultMachinePlatform:
      rootVolume:
        type: gp3
        size: 120
        throughput: 0
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step3-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput must be between 125.*2000"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 4: Negative throughput value
echo "Step 4: Test negative throughput value"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step4-patch.yaml" << EOF
platform:
  aws:
    defaultMachinePlatform:
      rootVolume:
        type: gp3
        size: 120
        throughput: -100
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step4-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput must be between 125.*2000"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 5: Invalid throughput type (string)
echo "Step 5: Test invalid throughput type (string)"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step5-patch.yaml" << EOF
platform:
  aws:
    defaultMachinePlatform:
      rootVolume:
        type: gp3
        size: 120
        throughput: "500"
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step5-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "cannot unmarshal string.*throughput"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 6: Unsupported volume type with throughput
echo "Step 6: Test unsupported volume type with throughput"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step6-patch.yaml" << EOF
platform:
  aws:
    defaultMachinePlatform:
      rootVolume:
        type: gp2
        size: 120
        throughput: 500
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step6-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput not supported for type gp2"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 7: Control plane below minimum boundary
echo "Step 7: Test split configuration below minimum boundary (control plane)"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step7-patch.yaml" << EOF
controlPlane:
  platform:
    aws:
      rootVolume:
        type: gp3
        size: 150
        throughput: 50
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step7-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput must be between 125.*2000"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 8: Control plane above maximum boundary
echo "Step 8: Test split configuration above maximum boundary (control plane)"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step8-patch.yaml" << EOF
controlPlane:
  platform:
    aws:
      rootVolume:
        type: gp3
        size: 150
        throughput: 5000
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step8-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput must be between 125.*2000"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 9: Compute below minimum boundary
echo "Step 9: Test split configuration below minimum boundary (compute)"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step9-patch.yaml" << EOF
compute:
  - name: worker
    platform:
      aws:
        rootVolume:
          type: gp3
          size: 120
          throughput: 50
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step9-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput must be between 125.*2000"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 10: Compute above maximum boundary
echo "Step 10: Test split configuration above maximum boundary (compute)"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step10-patch.yaml" << EOF
compute:
  - name: worker
    platform:
      aws:
        rootVolume:
          type: gp3
          size: 120
          throughput: 5000
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step10-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput must be between 125.*2000"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 11: Control plane unsupported volume type
echo "Step 11: Test split configuration with unsupported volume type (control plane)"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step11-patch.yaml" << EOF
controlPlane:
  platform:
    aws:
      rootVolume:
        type: gp2
        size: 150
        throughput: 500
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step11-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput not supported for type gp2"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 12: Compute unsupported volume type
echo "Step 12: Test split configuration with unsupported volume type (compute)"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step12-patch.yaml" << EOF
compute:
  - name: worker
    platform:
      aws:
        rootVolume:
          type: gp2
          size: 120
          throughput: 500
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step12-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput not supported for type gp2"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 13: Compute throughput zero without volume type
echo "Step 13: Test throughput zero without volume type (compute)"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step13-patch.yaml" << EOF
compute:
  - name: worker
    platform:
      aws:
        rootVolume:
          size: 120
          throughput: 0
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step13-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput must be between 125.*2000"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 14: Control plane throughput zero without volume type
echo "Step 14: Test throughput zero without volume type (control plane)"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step14-patch.yaml" << EOF
controlPlane:
  platform:
    aws:
      rootVolume:
        size: 150
        throughput: 0
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step14-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput must be between 125.*2000"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Test Step 15: Edge compute pool throughput without volume type
echo "Step 15: Test throughput without volume type for edge compute pool"
cp "${BACKUP_DIR}/base-install-config.yaml" "${CONFIG}"
cat > "${CONFIG_DIR}/step15-patch.yaml" << EOF
compute:
  - architecture: amd64
    hyperthreading: Enabled
    name: edge
    platform:
      aws:
        rootVolume:
          size: 120
          throughput: 1200
    replicas: 1
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_DIR}/step15-patch.yaml"
set +e
output=$(openshift-install create manifests --dir "${CONFIG_DIR}" 2>&1)
exit_code=$?
echo "${output}"
if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qi "throughput not supported for type gp2"; then
    echo "  PASSED"
    ((PASSED++))
else
    echo "  FAILED"
    ((FAILED++))
fi
set -e

# Print summary
echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Total: $((PASSED + FAILED))"
echo "Passed: ${PASSED}"
echo "Failed: ${FAILED}"
echo "=========================================="

# Cleanup
rm -rf "${CONFIG_DIR}"

if [[ ${FAILED} -eq 0 ]]; then
    exit 0
else
  exit 1
fi
