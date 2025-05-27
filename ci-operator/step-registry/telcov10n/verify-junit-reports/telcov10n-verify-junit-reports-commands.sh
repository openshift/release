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
from junitparser import JUnitXml, TestSuite

def verify_junit_reports(directory):
    """
    Verify all JUnit XML reports in the given directory.
    Returns 1 if any test failed, 0 if all tests passed or were skipped.
    """
    if not os.path.exists(directory):
        print(f"Error: Directory {directory} does not exist")
        return 1
    
    # Find all XML files in the directory
    xml_pattern = os.path.join(directory, "*.xml")
    xml_files = glob.glob(xml_pattern)
    
    if not xml_files:
        print(f"Warning: No XML files found in {directory}")
        return 0
    
    print(f"Found {len(xml_files)} XML file(s) to verify:")
    for xml_file in xml_files:
        print(f"  - {os.path.basename(xml_file)}")
    
    failed_tests = 0
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
                
                for case in suite:
                    total_tests += 1
                    suite_tests += 1
                    
                    if not case.is_passed and not case.is_skipped:
                        failed_tests += 1
                        suite_failures += 1
                        print(f"  FAILED: {case.name} in {suite_name}")
                
                if suite_failures == 0:
                    print(f"  ✓ Suite '{suite_name}': {suite_tests} test(s) passed")
                else:
                    print(f"  ✗ Suite '{suite_name}': {suite_failures}/{suite_tests} test(s) failed")
                    
        except Exception as e:
            print(f"Error parsing {xml_file}: {e}")
            return 1
    
    print(f"\n=== Summary ===")
    print(f"Total tests: {total_tests}")
    print(f"Failed tests: {failed_tests}")
    
    if failed_tests > 0:
        print(f"❌ {failed_tests} test(s) failed")
        return 1
    else:
        print("✅ All tests passed or were skipped")
        return 0

if __name__ == "__main__":
    shared_dir = "${SHARED_DIR}"
    sys.exit(verify_junit_reports(shared_dir))
EOF_SCRIPT

python3 ./fail_if_any_test_failed.py
