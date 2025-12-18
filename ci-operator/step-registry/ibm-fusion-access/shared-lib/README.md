# IBM Fusion Access Shared Library

This step generates a shared library of bash functions for JUnit XML test result reporting, used across all IBM Fusion Access test steps.

## Purpose

- **Centralize JUnit XML reporting functions**: Provides common functions for test result reporting
- **Ensure consistency**: All IBM Fusion Access tests use the same reporting format
- **Reduce duplication**: Eliminates the need to duplicate JUnit XML code in each test step
- **Follow best practices**: Implements OCP CI standard patterns for test result reporting
- **Enable integration**: Supports Prow/Spyglass visualization and component readiness dashboards

## Output

The shared library is written to:

```bash
${SHARED_DIR}/common-fusion-access-bash-functions.sh
```

## Functions Provided

### 1. `add_test_result()`

Adds a test case result to the JUnit XML output.

**Parameters:**
- `$1` - `test_name`: Name of the test case (use snake_case, e.g., `test_operator_installation`)
- `$2` - `test_status`: Test result, must be `"passed"` or `"failed"`
- `$3` - `test_duration`: Duration in seconds (integer)
- `$4` - `test_message`: Error message for failed tests (optional, provide detailed failure reason)
- `$5` - `test_classname`: Test class name (optional, defaults to `"FusionAccessTests"`, use PascalCase)

**Global Variables Modified:**
- `TESTS_TOTAL`: Incremented by 1
- `TESTS_PASSED`: Incremented by 1 if test passed
- `TESTS_FAILED`: Incremented by 1 if test failed
- `TEST_CASES`: Appended with test case XML

**Example:**
```bash
TEST1_START=$(date +%s)
TEST1_STATUS="failed"
TEST1_MESSAGE=""

if perform_test; then
  echo "  ✅ Test passed"
  TEST1_STATUS="passed"
else
  echo "  ❌ Test failed"
  TEST1_MESSAGE="Failed to perform test: specific reason"
fi

TEST1_DURATION=$(($(date +%s) - TEST1_START))
add_test_result "test_operation" "$TEST1_STATUS" "$TEST1_DURATION" "$TEST1_MESSAGE" "FusionAccessOperatorTests"
```

### 2. `generate_junit_xml()`

Generates the final JUnit XML test results report. Should be called at the end of test execution (typically via a trap on EXIT).

**Required Global Variables:**
- `JUNIT_RESULTS_FILE`: Path to output XML file (e.g., `"${ARTIFACT_DIR}/junit_fusion_access_tests.xml"`)
- `TEST_START_TIME`: Start time of test suite (unix timestamp from `$(date +%s)`)
- `TESTS_TOTAL`: Total number of tests executed (integer)
- `TESTS_FAILED`: Number of failed tests (integer)
- `TESTS_PASSED`: Number of passed tests (integer)
- `TEST_CASES`: Accumulated test case XML (string)

**Optional Global Variables:**
- `JUNIT_SUITE_NAME`: Name of the test suite (default: `"IBM Fusion Access Tests"`)
- `JUNIT_EXIT_ON_FAILURE`: Exit with error if tests failed (default: `"true"`, set to `"false"` to suppress)
- `SHARED_DIR`: Directory for sharing artifacts between steps (results copied here if exists)

**Output:**
- JUnit XML file at `${JUNIT_RESULTS_FILE}`
- Copy in `${SHARED_DIR}` (if available)
- Console test summary

## Usage in Test Steps

### 1. Add this step as a dependency

In your test workflow, ensure this step runs before your test steps:

```yaml
test:
- ref: ibm-fusion-access-shared-lib
- ref: your-test-step
```

### 2. Source the shared library

Add this line after your script header:

```bash
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Source the shared library
source "${SHARED_DIR}/common-fusion-access-bash-functions.sh"
```

### 3. Initialize required variables

Before using the functions, initialize all required variables:

```bash
# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_<descriptive_test_name>_tests.xml"
JUNIT_SUITE_NAME="IBM Fusion Access <Test Category> Tests"
TEST_START_TIME=$(date +%s)
TESTS_TOTAL=0
TESTS_FAILED=0
TESTS_PASSED=0
TEST_CASES=""
```

### 4. Set up trap

**CRITICAL**: The trap must be set AFTER sourcing the shared library:

```bash
trap generate_junit_xml EXIT
```

### 5. Use in test cases

```bash
# Test 1: Example test
echo ""
echo "🧪 Test 1: Example test description..."
TEST1_START=$(date +%s)
TEST1_STATUS="failed"
TEST1_MESSAGE=""

# Test logic
if perform_test_action; then
  echo "  ✅ Test passed"
  TEST1_STATUS="passed"
else
  echo "  ❌ Test failed"
  TEST1_MESSAGE="Specific failure reason"
fi

# Record result
TEST1_DURATION=$(($(date +%s) - TEST1_START))
add_test_result "test_example_action" "$TEST1_STATUS" "$TEST1_DURATION" "$TEST1_MESSAGE"
```

## Complete Example

```bash
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "************ Example IBM Fusion Access Test ************"

# Source shared library
source "${SHARED_DIR}/common-fusion-access-bash-functions.sh"

# Initialize JUnit XML variables
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_example_tests.xml"
JUNIT_SUITE_NAME="IBM Fusion Access Example Tests"
TEST_START_TIME=$(date +%s)
TESTS_TOTAL=0
TESTS_FAILED=0
TESTS_PASSED=0
TEST_CASES=""

# Set trap to generate XML on exit
trap generate_junit_xml EXIT

# Test 1: Check operator installation
echo ""
echo "🧪 Test 1: Verify operator installation..."
TEST1_START=$(date +%s)
TEST1_STATUS="failed"
TEST1_MESSAGE=""

if oc get deployment -n ibm-fusion-access fusion-access-operator >/dev/null 2>&1; then
  echo "  ✅ Operator deployment found"
  TEST1_STATUS="passed"
else
  echo "  ❌ Operator deployment not found"
  TEST1_MESSAGE="IBM Fusion Access operator deployment not found in namespace ibm-fusion-access"
fi

TEST1_DURATION=$(($(date +%s) - TEST1_START))
add_test_result "test_operator_installation" "$TEST1_STATUS" "$TEST1_DURATION" "$TEST1_MESSAGE"

# Test 2: Check CRDs
echo ""
echo "🧪 Test 2: Verify CRDs are installed..."
TEST2_START=$(date +%s)
TEST2_STATUS="failed"
TEST2_MESSAGE=""

if oc get crd fusionaccess.fusion.ibm.com >/dev/null 2>&1; then
  echo "  ✅ FusionAccess CRD found"
  TEST2_STATUS="passed"
else
  echo "  ❌ FusionAccess CRD not found"
  TEST2_MESSAGE="FusionAccess CRD not found"
fi

TEST2_DURATION=$(($(date +%s) - TEST2_START))
add_test_result "test_crd_installation" "$TEST2_STATUS" "$TEST2_DURATION" "$TEST2_MESSAGE"

# The trap will automatically call generate_junit_xml on exit
```

## Integration Points

- **ARTIFACT_DIR**: JUnit XML files are saved here for CI artifact collection
- **SHARED_DIR**: Results are copied here for data router reporter integration
- **Prow/Spyglass**: Enables test result visualization in Prow UI
- **Component Readiness Dashboard**: Supports automated result aggregation

## Best Practices

### Naming Conventions

- **Test names**: Use `snake_case` (e.g., `test_operator_installation`)
- **Test class names**: Use `PascalCase` (e.g., `FusionAccessOperatorTests`)
- **JUnit XML files**: Use descriptive names (e.g., `junit_fusion_access_operator_tests.xml`)

### Test Structure

1. **Initialize status to "failed"**: Always start with failure assumption
2. **Set to "passed" on success**: Only mark as passed when verification succeeds
3. **Capture error messages**: Provide detailed failure reasons for debugging
4. **Calculate durations**: Use actual execution time, don't hardcode
5. **Preserve console output**: Keep emojis and clear formatting for human readability

### Error Handling

```bash
# ✅ GOOD - Default to failed, set to passed on success
TEST_STATUS="failed"
TEST_MESSAGE=""

if perform_action; then
  TEST_STATUS="passed"
else
  TEST_MESSAGE="Detailed error message"
fi

# ❌ BAD - No error message capture
TEST_STATUS="failed"
if perform_action; then
  TEST_STATUS="passed"
fi
```

## References

- [OCP CI JUnit XML Test Results Patterns](.cursor/rules/ocp-ci-junit-xml-test-results-patterns.mdc)
- [JUnit XML Schema](https://www.ibm.com/docs/en/developer-for-zos/9.1.1?topic=formats-junit-xml-format)
- [OCP CI Test Platform Documentation](https://docs.ci.openshift.org/)

## Related Steps

- `interop-tests-deploy-fusion-access` - Uses this library for deployment tests
- `interop-tests-ibm-fusion-access-tests` - Uses this library for functional tests
- `interop-tests-verify-shared-storage` - Uses this library for storage verification tests

## Maintenance

When updating this shared library:

1. **Test changes locally**: Validate bash syntax with `bash -n`
2. **Update documentation**: Keep this README and ref.yaml documentation in sync
3. **Consider backward compatibility**: Changes affect all IBM Fusion Access test steps
4. **Test with existing steps**: Verify existing test steps still work
5. **Document breaking changes**: Clearly communicate any API changes

## Questions or Issues?

Contact the CSPI QE OCP LP team (see OWNERS file) for questions or issues with this shared library.

