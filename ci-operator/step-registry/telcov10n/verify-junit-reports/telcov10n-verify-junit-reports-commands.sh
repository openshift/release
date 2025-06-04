#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Fix user IDs in a container
~/fix_uid.sh

pip install --user junitparser

# Need to do this because of a bug in junitparser's verify subcommand which fails if there is only one test suite
# This can be removed when https://github.com/weiwei/junitparser/pull/142 is merged
cat << EOF_SCRIPT > fail_if_any_test_failed.py
import sys
import os
import glob
import json
from junitparser import JUnitXml, TestSuite

# Constants
SUCCESS_MESSAGE = "✅ All tests passed or were skipped"

def parse_known_failures() -> list:
    """
    Parse the KNOWN_FAILURES environment variable.
    Expected format: JSON array of test identifiers
    """
    known_failures_str = os.getenv('KNOWN_FAILURES', '[]')
    try:
        known_failures = json.loads(known_failures_str)
        if not isinstance(known_failures, list):
            print(f"Warning: KNOWN_FAILURES is not a list, treating as empty: {known_failures_str}")
            return []
        print(f"Known failures loaded: {len(known_failures)} test(s)")
        for failure in known_failures:
            print(f"  - {failure}")
        return known_failures
    except json.JSONDecodeError as e:
        print(f"Warning: Failed to parse KNOWN_FAILURES as JSON: {e}")
        print(f"KNOWN_FAILURES content: {known_failures_str}")
        return []

def is_known_failure(test_case_name, known_failures):
    """
    Check if a test case is in the known failures list.
    This supports both exact matches and partial matches.
    """
    if not known_failures:
        return False
    
    for known_failure in known_failures:
        # Support both string entries and dict entries with test_id
        if isinstance(known_failure, dict):
            test_id = known_failure.get('test_id', '')
        else:
            test_id = str(known_failure)
        
        # Check for exact match or if the known failure is contained in the test name
        if test_id == test_case_name or test_id in test_case_name:
            return True
    
    return False

def verify_junit_reports(directory) -> int:
    """
    Verify all JUnit XML reports in the given directory.
    Returns 1 if any test failed, 0 if all tests passed or were skipped.
    Skips tests that are listed in KNOWN_FAILURES.
    """
    if not os.path.exists(directory):
        print(f"Error: Directory {directory} does not exist")
        return 1
    
    # Parse known failures
    known_failures = parse_known_failures()
    
    # Find all XML files in the directory
    xml_pattern = os.path.join(directory, "*.xml")
    xml_files = glob.glob(xml_pattern)
    
    if not xml_files:
        print(f"Warning: No XML files found in {directory}")
        return 1
    
    print(f"Found {len(xml_files)} XML file(s) to verify:")
    for xml_file in xml_files:
        print(f"  - {os.path.basename(xml_file)}")
    
    failed_tests = 0
    skipped_known_failures = 0
    total_tests = 0
    
    for xml_file in xml_files:
        try:
            print(f"\nProcessing: {os.path.basename(xml_file)}")
            xml = JUnitXml.fromfile(xml_file)
            
            # Handle single testsuite case
            if isinstance(xml, TestSuite):
                xml = [xml]
            
            for suite in xml:
                suite_name = suite.name or "Unknown Suite"
                suite_tests = 0
                suite_failures = 0
                suite_known_failures = 0
                
                for case in suite:
                    total_tests += 1
                    suite_tests += 1
                    
                    if not case.is_passed and not case.is_skipped:
                        # Check if this is a known failure
                        if is_known_failure(case.name, known_failures):
                            skipped_known_failures += 1
                            suite_known_failures += 1
                            print(f"  SKIPPED (known failure): {case.name} in {suite_name}")
                        else:
                            failed_tests += 1
                            suite_failures += 1
                            print(f"  FAILED: {case.name} in {suite_name}")
                
                status_msg = f"  ✓ Suite '{suite_name}': {suite_tests} test(s)"
                if suite_failures == 0 and suite_known_failures == 0:
                    print(status_msg + " passed")
                elif suite_failures == 0:
                    print(status_msg + f" passed ({suite_known_failures} known failures skipped)")
                else:
                    failure_summary = f"{suite_failures} failed"
                    if suite_known_failures > 0:
                        failure_summary += f", {suite_known_failures} known failures skipped"
                    print(f"  ✗ Suite '{suite_name}': {failure_summary} out of {suite_tests} test(s)")
                    
        except Exception as e:
            print(f"Error parsing {xml_file}: {e}")
            return 1
    
    print(f"\n=== Summary ===")
    print(f"Total tests: {total_tests}")
    print(f"Failed tests: {failed_tests}")
    print(f"Known failures skipped: {skipped_known_failures}")
    
    if failed_tests > 0:
        print(f"❌ {failed_tests} test(s) failed")
        return 1
    else:
        success_msg = SUCCESS_MESSAGE
        if skipped_known_failures > 0:
            success_msg += f" ({skipped_known_failures} known failures ignored)"
        print(success_msg)
        return 0

if __name__ == "__main__":
    shared_dir = "${SHARED_DIR}"
    sys.exit(verify_junit_reports(shared_dir))
EOF_SCRIPT

python3 ./fail_if_any_test_failed.py
