#!/usr/bin/env python3
"""
Test script to verify validation in GCP Secret Manager names.
"""

# pylint: disable=E0401, C0413

import click

from ..util import validate_collection, validate_secret_name, validate_group_name


def test_validation(validator_func, test_cases, validator_name):
    """Test a validation function with various inputs."""
    print(f"\n{'='*60}")
    print(f"Testing {validator_name}")
    print(f"{'='*60}")

    passed = 0
    failed = 0

    for test_input, should_pass in test_cases:
        try:
            validator_func(None, None, test_input)
            if should_pass:
                passed += 1
            else:
                failed += 1
                print(f"✗ FAIL: '{test_input}' -> should have been rejected but was accepted")
        except (click.BadParameter, click.ClickException) as e:
            if not should_pass:
                passed += 1
            else:
                failed += 1
                print(f"✗ FAIL: '{test_input}' -> should have been accepted but was rejected: {e.message}")

    total = passed + failed
    if failed == 0:
        print(f"✓ All {total} tests passed")
    else:
        print(f"\n{passed}/{total} tests passed, {failed} failed")


def main():
    print("\n" + "="*60)
    print("GCP Secret Manager Validation Tests")
    print("="*60)

    collection_tests = [
        ("aws-credentials", True),
        ("test-platform", True),
        ("my-collection", True),
        ("test123", True),
        ("aws_credentials", True),
        ("test_platform_infra", True),
        ("my_test-collection", True),
        ("a_b_c", True),
        ("test_123", True),
        ("a", True),
        ("_test", False),
        ("test_", False),
        ("test__value", False),
        ("__test__", False),
        ("test@value", False),
        ("TEST", False),
        ("test.value", False),
        ("_test.value", False),
        ("__value", False),
        ("a__", False),
        ("__-a", False),
    ]

    secret_tests = [
        ("aws-credentials", True),
        ("MySecret", True),
        ("test123", True),
        ("AWS_CREDENTIALS", True),
        ("my_secret", True),
        ("Test_Platform_Infra", True),
        ("A_B_C", True),
        ("X", True),
        ("_test", False),
        ("test_", False),
        ("test__value", False),
        ("__test__", False),
        ("test@value", False),
        ("test.value", False),
        ("test value", False),
        ("test/value", False),
    ]

    group_tests = [
        ("default", True),
        ("aws/prod", True),
        ("test-platform", True),
        ("my_group", True),
        ("test_platform/sub_team", True),
        ("aws_creds/prod-env", True),
        ("a_b/c_d", True),
        ("group1/group2/group3", True),
        ("_test", False),
        ("test_", False),
        ("test__value", False),
        ("_group/sub", False),
        ("group/sub_", False),
        ("group__sub", False),
        ("TEST", False),
        ("test@value", False),
    ]

    test_validation(validate_collection, collection_tests, "validate_collection")
    test_validation(validate_secret_name, secret_tests, "validate_secret_name")
    test_validation(validate_group_name, group_tests, "validate_group_name")

    print("\n" + "="*60)
    print("Testing complete!")
    print("="*60 + "\n")


if __name__ == "__main__":
    main()
