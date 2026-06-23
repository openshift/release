#!/bin/bash
# Verification script for sosreport step implementation
# Run this to verify all files are correct before committing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "========================================"
echo "Verifying sosreport Step Implementation"
echo "========================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass_count=0
fail_count=0

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((pass_count++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((fail_count++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Test 1: Check all files exist
echo "1. Checking required files..."
if [ -f "openshift-qe-sosreport-commands.sh" ]; then
    check_pass "openshift-qe-sosreport-commands.sh exists"
else
    check_fail "openshift-qe-sosreport-commands.sh missing"
fi

if [ -f "openshift-qe-sosreport-ref.yaml" ]; then
    check_pass "openshift-qe-sosreport-ref.yaml exists"
else
    check_fail "openshift-qe-sosreport-ref.yaml missing"
fi

if [ -f "openshift-qe-sosreport-ref.metadata.json" ]; then
    check_pass "openshift-qe-sosreport-ref.metadata.json exists"
else
    check_fail "openshift-qe-sosreport-ref.metadata.json missing"
fi

if [ -L "OWNERS" ]; then
    check_pass "OWNERS symlink exists"
else
    check_fail "OWNERS symlink missing"
fi

# Test 2: Check script syntax
echo ""
echo "2. Checking bash script syntax..."
if bash -n openshift-qe-sosreport-commands.sh 2>/dev/null; then
    check_pass "Bash syntax valid"
else
    check_fail "Bash syntax error"
    bash -n openshift-qe-sosreport-commands.sh
fi

# Test 3: Check file permissions
echo ""
echo "3. Checking file permissions..."
if [ -x "openshift-qe-sosreport-commands.sh" ]; then
    check_pass "Script is executable"
else
    check_fail "Script is not executable (chmod +x needed)"
fi

# Test 4: Check OWNERS symlink target
echo ""
echo "4. Checking OWNERS symlink..."
if [ -L "OWNERS" ]; then
    target=$(readlink OWNERS)
    if [ "$target" = "../OWNERS" ]; then
        check_pass "OWNERS symlink points to ../OWNERS"
    else
        check_fail "OWNERS symlink points to wrong target: $target"
    fi

    if [ -f "../OWNERS" ]; then
        check_pass "OWNERS target file exists"
    else
        check_fail "OWNERS target file (../OWNERS) does not exist"
    fi
fi

# Test 5: Check YAML structure
echo ""
echo "5. Checking YAML structure..."
if grep -q "^ref:" openshift-qe-sosreport-ref.yaml; then
    check_pass "YAML has 'ref:' key"
else
    check_fail "YAML missing 'ref:' key"
fi

if grep -q "as: openshift-qe-sosreport" openshift-qe-sosreport-ref.yaml; then
    check_pass "YAML has correct 'as:' value"
else
    check_fail "YAML has incorrect 'as:' value"
fi

if grep -q "commands: openshift-qe-sosreport-commands.sh" openshift-qe-sosreport-ref.yaml; then
    check_pass "YAML references correct command script"
else
    check_fail "YAML does not reference command script correctly"
fi

# Test 6: Check JSON structure
echo ""
echo "6. Checking JSON metadata..."
if python3 -m json.tool openshift-qe-sosreport-ref.metadata.json > /dev/null 2>&1; then
    check_pass "JSON is valid"
else
    check_fail "JSON is invalid"
fi

if grep -q '"openshift-qe"' openshift-qe-sosreport-ref.metadata.json; then
    check_pass "JSON has correct owner"
else
    check_fail "JSON missing correct owner"
fi

# Test 7: Check script content
echo ""
echo "7. Checking script content..."
if grep -q "#!/bin/bash" openshift-qe-sosreport-commands.sh; then
    check_pass "Script has bash shebang"
else
    check_fail "Script missing bash shebang"
fi

if grep -q "set -o nounset" openshift-qe-sosreport-commands.sh; then
    check_pass "Script has 'set -o nounset'"
else
    check_fail "Script missing 'set -o nounset'"
fi

if grep -q "SOS_REPORT_DIR" openshift-qe-sosreport-commands.sh; then
    check_pass "Script defines SOS_REPORT_DIR"
else
    check_fail "Script missing SOS_REPORT_DIR"
fi

if grep -q "collect_sosreport_from_node" openshift-qe-sosreport-commands.sh; then
    check_pass "Script has collect_sosreport_from_node function"
else
    check_fail "Script missing main collection function"
fi

# Test 8: Check environment variables in YAML
echo ""
echo "8. Checking environment variables..."
required_vars=("SOS_TIMEOUT" "SOS_NODE_SELECTOR" "SOS_MAX_PARALLEL" "SOS_COLLECT_ALL_NODES" "SOS_PLUGIN_FILTER")
for var in "${required_vars[@]}"; do
    if grep -q "name: $var" openshift-qe-sosreport-ref.yaml; then
        check_pass "YAML defines $var"
    else
        check_fail "YAML missing $var"
    fi
done

# Test 9: Shellcheck (if available)
echo ""
echo "9. Running shellcheck (if available)..."
if command -v shellcheck > /dev/null 2>&1; then
    if shellcheck openshift-qe-sosreport-commands.sh; then
        check_pass "Shellcheck passed"
    else
        check_warn "Shellcheck found issues (review recommended)"
    fi
else
    check_warn "Shellcheck not installed (skipped)"
fi

# Test 10: YAML lint (if available)
echo ""
echo "10. Running yamllint (if available)..."
if command -v yamllint > /dev/null 2>&1; then
    if yamllint -d relaxed openshift-qe-sosreport-ref.yaml; then
        check_pass "yamllint passed"
    else
        check_warn "yamllint found issues (review recommended)"
    fi
else
    check_warn "yamllint not installed (skipped)"
fi

# Summary
echo ""
echo "========================================"
echo "Verification Summary"
echo "========================================"
echo -e "${GREEN}Passed:${NC} $pass_count"
if [ $fail_count -gt 0 ]; then
    echo -e "${RED}Failed:${NC} $fail_count"
else
    echo -e "${GREEN}Failed:${NC} $fail_count"
fi

echo ""
if [ $fail_count -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed! Ready for git commit.${NC}"
    exit 0
else
    echo -e "${RED}✗ Some checks failed. Please fix issues before committing.${NC}"
    exit 1
fi
