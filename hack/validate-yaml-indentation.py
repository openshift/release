#!/usr/bin/env python3
"""
Validate YAML file indentation to catch indentation issues early.

This script checks for:
- Consistent indentation (spaces vs tabs)
- Consistent indentation width (typically 2 spaces for YAML)
- Mixed indentation within files
- Trailing whitespace that could cause issues
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

import yaml


class YAMLIndentationError(Exception):
    """Custom exception for indentation errors."""


def detect_indentation_type(line):
    """Detect if a line uses spaces or tabs for indentation."""
    stripped = line.lstrip()
    if not stripped or stripped.startswith('#'):
        return None  # Empty or comment line
    indent = line[:len(line) - len(stripped)]
    if '\t' in indent:
        return 'tab'
    if ' ' in indent:
        return 'space'
    return None


def detect_indentation_width(lines):
    """Detect the indentation width (number of spaces) used in the file."""
    widths = set()
    for line in lines:
        stripped = line.lstrip()
        if not stripped or stripped.startswith('#'):
            continue
        indent = line[:len(line) - len(stripped)]
        if indent and ' ' in indent and '\t' not in indent:
            # Count spaces at the start
            space_count = len(indent)
            if space_count > 0:
                widths.add(space_count)

    # Common YAML indentation widths: 2, 4, 8
    # Prefer 2 spaces as it's most common in YAML
    if widths:
        # Find the most common width
        width_counts = {}
        for line in lines:
            stripped = line.lstrip()
            if not stripped or stripped.startswith('#'):
                continue
            indent = line[:len(line) - len(stripped)]
            if indent and ' ' in indent and '\t' not in indent:
                width = len(indent)
                width_counts[width] = width_counts.get(width, 0) + 1

        if width_counts:
            most_common = max(width_counts.items(), key=lambda x: x[1])
            return most_common[0]

    return None


def validate_yaml_syntax(file_path):
    """
    Validate YAML file can be parsed and has valid syntax.

    Args:
        file_path: Path to the YAML file

    Returns:
        Tuple of (list of errors, parsed data or None)
    """
    errors = []
    data = None

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()

        # Try to parse YAML
        try:
            data = yaml.safe_load(content)
        except yaml.YAMLError as e:
            error_msg = f"{file_path}: YAML syntax error"
            if hasattr(e, 'problem_mark'):
                mark = e.problem_mark
                error_msg += f" at line {mark.line + 1}, column {mark.column + 1}"
                if hasattr(e, 'problem'):
                    error_msg += f": {e.problem}"
            else:
                error_msg += f": {str(e)}"
            errors.append(error_msg)
            return errors, None

        # Check for common issues
        if data is None and content.strip():
            errors.append(f"{file_path}: YAML file is empty or contains only comments/null values")

    except UnicodeDecodeError as e:
        errors.append(f"{file_path}: File encoding error - {str(e)}")
    except (IOError, OSError) as e:
        errors.append(f"{file_path}: Error reading file - {str(e)}")

    return errors, data


def validate_yaml_structure(file_path, data):
    """
    Validate basic YAML structure and common field/value issues.

    Args:
        file_path: Path to the YAML file
        data: Parsed YAML data

    Returns:
        List of error messages
    """
    errors = []

    if data is None:
        return errors

    # Check for common structural issues
    if isinstance(data, dict):
        # Check for common typos in Prow job configs
        common_typos = {
            'presubmit': 'presubmits',
            'postsubmit': 'postsubmits',
            'periodic': 'periodics',
            'alwaysRun': 'always_run',
            'skipReport': 'skip_report',
        }

        for key in data.keys():
            if key in common_typos:
                errors.append(
                    f"{file_path}: Possible typo: '{key}' should be '{common_typos[key]}'?"
                )

        # Check for invalid value types in common fields
        type_checks = {
            'always_run': bool,
            'optional': bool,
            'decorate': bool,
            'skip_cloning': bool,
        }

        for field, expected_type in type_checks.items():
            if field in data:
                if not isinstance(data[field], expected_type):
                    errors.append(
                        f"{file_path}: Field '{field}' should be {expected_type.__name__}, got {type(data[field]).__name__}"
                    )

        # Recursively check nested structures
        for key, value in data.items():
            if isinstance(value, dict):
                nested_errors = validate_yaml_structure(f"{file_path} (key: {key})", value)
                errors.extend(nested_errors)
            elif isinstance(value, list):
                for i, item in enumerate(value):
                    if isinstance(item, dict):
                        nested_errors = validate_yaml_structure(f"{file_path} (list item {i})", item)
                        errors.extend(nested_errors)

    return errors


def fix_yaml_indentation(file_path, expected_width=2):
    """
    Fix YAML file indentation by loading and re-dumping with proper formatting.

    Args:
        file_path: Path to the YAML file
        expected_width: Expected indentation width in spaces (default: 2)

    Returns:
        True if file was modified, False otherwise
    """
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f)

        if data is None:
            return False

        # Write back with proper indentation
        with open(file_path, 'w', encoding='utf-8') as f:
            yaml.dump(data, f, default_flow_style=False, indent=expected_width,
                     sort_keys=False, allow_unicode=True, width=1000)

        return True
    except (IOError, OSError, yaml.YAMLError) as e:
        print(f"Error fixing {file_path}: {e}", file=sys.stderr)
        return False


def get_file_context(lines, line_num, context_lines=3):
    """Get context around a line number for better error messages."""
    start = max(0, line_num - context_lines - 1)
    end = min(len(lines), line_num + context_lines)
    context = []
    for i in range(start, end):
        marker = ">>>" if i == line_num - 1 else "   "
        context.append(f"{marker} {i+1:4d}| {lines[i].rstrip()}")
    return "\n".join(context)


def validate_yaml_indentation(file_path, expected_width=2, strict=True, show_context=False):
    """
    Validate YAML file indentation.

    Args:
        file_path: Path to the YAML file
        expected_width: Expected indentation width in spaces (default: 2)
        strict: If True, enforce exact indentation width
        show_context: If True, include context lines in error messages

    Returns:
        Tuple of (list of error messages, list of lines with errors)
    """
    errors = []
    error_lines = []

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except (IOError, OSError) as e:
        return ([f"Error reading file {file_path}: {e}"], [])

    if not lines:
        return ([], [])  # Empty file, nothing to check

    # Detect indentation type and width
    indentation_types = set()
    detected_width = detect_indentation_width(lines)

    # If we detected a consistent width different from expected, use it
    # This handles files that consistently use 4 spaces (like some Prow job files)
    if detected_width and detected_width in [2, 4, 8]:
        # Use detected width if it's a common YAML indentation width
        effective_width = detected_width
    else:
        effective_width = expected_width

    for line_num, line in enumerate(lines, 1):
        line_has_error = False

        # Check for tabs
        if '\t' in line:
            error_msg = f"{file_path}:{line_num}: Tab character found. YAML files should use spaces for indentation."
            if show_context:
                error_msg += f"\n{get_file_context(lines, line_num)}"
            errors.append(error_msg)
            error_lines.append(line_num)
            line_has_error = True

        # Check indentation type
        indent_type = detect_indentation_type(line)
        if indent_type:
            indentation_types.add(indent_type)

        # Check for trailing whitespace
        if line.rstrip() != line.rstrip('\n'):
            error_msg = f"{file_path}:{line_num}: Trailing whitespace found."
            if show_context:
                error_msg += f"\n{get_file_context(lines, line_num)}"
            errors.append(error_msg)
            if not line_has_error:
                error_lines.append(line_num)
            line_has_error = True

        # Check indentation width for non-empty, non-comment lines
        stripped = line.lstrip()
        if stripped and not stripped.startswith('#'):
            indent = line[:len(line) - len(stripped)]
            if indent and ' ' in indent and '\t' not in indent:
                indent_width = len(indent)
                # Check if indentation is a multiple of effective_width
                if strict and indent_width % effective_width != 0:
                    error_msg = f"{file_path}:{line_num}: Indentation width {indent_width} is not a multiple of {effective_width} spaces."
                    if show_context:
                        error_msg += f"\n  Suggested fix: Replace {indent_width} spaces with {effective_width * (indent_width // effective_width + (1 if indent_width % effective_width else 0))} spaces"
                        error_msg += f"\n{get_file_context(lines, line_num)}"
                    errors.append(error_msg)
                    if not line_has_error:
                        error_lines.append(line_num)

    # Check for mixed indentation types
    if len(indentation_types) > 1:
        error_msg = f"{file_path}: Mixed indentation types detected: {indentation_types}. Use consistent indentation."
        if show_context:
            error_msg += "\n  Suggested fix: Convert all tabs to spaces or use consistent indentation throughout"
        errors.append(error_msg)

    # Only warn about width mismatch if file is inconsistent
    # If file consistently uses a different width (2, 4, or 8), that's acceptable
    if detected_width and detected_width not in [2, 4, 8] and strict:
        if not errors:
            error_msg = f"{file_path}: Detected unusual indentation width {detected_width} spaces. Common widths are 2, 4, or 8 spaces."
            if show_context:
                error_msg += "\n  Suggested fix: Use standard indentation width (2 spaces recommended)"
            errors.append(error_msg)

    return errors, error_lines


def get_changed_yaml_files(base_dir=None):
    """Get YAML files changed in git (staged or working directory)."""
    try:
        # Get staged files
        result = subprocess.run(
            ['git', 'diff', '--cached', '--name-only', '--diff-filter=ACMR'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            check=False,
            cwd=base_dir or '.'
        )
        staged_files = [f.strip() for f in result.stdout.split('\n') if f.strip()]

        # Get unstaged files
        result = subprocess.run(
            ['git', 'diff', '--name-only', '--diff-filter=ACMR'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            check=False,
            cwd=base_dir or '.'
        )
        unstaged_files = [f.strip() for f in result.stdout.split('\n') if f.strip()]

        # Combine and filter YAML files
        all_changed = set(staged_files + unstaged_files)
        yaml_files = [f for f in all_changed if f.endswith(('.yaml', '.yml'))]

        return [os.path.abspath(f) for f in yaml_files if os.path.exists(f)]
    except (subprocess.SubprocessError, OSError):
        return []


def find_yaml_files(base_dir, exclude_patterns=None):
    """Find all YAML files in the directory tree."""
    if exclude_patterns is None:
        exclude_patterns = []

    yaml_files = []
    for root, dirs, files in os.walk(base_dir):
        # Skip hidden directories and common exclusions
        dirs[:] = [d for d in dirs if not d.startswith('.') and d not in ['node_modules', 'vendor']]

        for file in files:
            if file.endswith(('.yaml', '.yml')):
                file_path = os.path.join(root, file)
                # Check if file matches any exclude pattern
                should_exclude = False
                for pattern in exclude_patterns:
                    if pattern in file_path:
                        should_exclude = True
                        break
                if not should_exclude:
                    yaml_files.append(file_path)

    return yaml_files


def parse_arguments():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description='Validate YAML file indentation',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Validate all YAML files in current directory
  %(prog)s .

  # Validate specific file
  %(prog)s path/to/file.yaml

  # Validate with custom indentation width
  %(prog)s --width 4 path/to/file.yaml

  # Non-strict mode (warnings only)
  %(prog)s --no-strict path/to/file.yaml
        """
    )
    parser.add_argument(
        'path',
        help='Path to YAML file or directory containing YAML files'
    )
    parser.add_argument(
        '--width',
        type=int,
        default=2,
        help='Expected indentation width in spaces (default: 2)'
    )
    parser.add_argument(
        '--no-strict',
        action='store_true',
        help='Non-strict mode: only check for tabs and mixed indentation'
    )
    parser.add_argument(
        '--exclude',
        action='append',
        default=[],
        help='Pattern to exclude from validation (can be used multiple times)'
    )
    parser.add_argument(
        '--verbose',
        action='store_true',
        help='Verbose output'
    )
    parser.add_argument(
        '--fix',
        action='store_true',
        help='Automatically fix indentation issues (re-formats YAML files)'
    )
    parser.add_argument(
        '--git-diff',
        action='store_true',
        help='Only validate YAML files changed in git (staged or unstaged)'
    )
    parser.add_argument(
        '--show-context',
        action='store_true',
        help='Show context lines around errors for better debugging'
    )
    parser.add_argument(
        '--validate-syntax',
        action='store_true',
        default=True,
        help='Validate YAML syntax and structure (default: True)'
    )
    parser.add_argument(
        '--no-validate-syntax',
        dest='validate_syntax',
        action='store_false',
        help='Skip YAML syntax and structure validation'
    )
    parser.add_argument(
        '--use-yamllint',
        action='store_true',
        help='Also run yamllint for additional validation (if available)'
    )
    return parser.parse_args()


def get_yaml_files_to_validate(args):
    """Get list of YAML files to validate based on arguments."""
    path = Path(args.path)
    if not path.exists():
        print(f"Error: Path {args.path} does not exist", file=sys.stderr)
        sys.exit(1)

    if args.git_diff:
        yaml_files = get_changed_yaml_files(str(path) if path.is_dir() else None)
        if not yaml_files:
            if args.verbose:
                print("No changed YAML files found in git")
            sys.exit(0)
        if args.verbose:
            print(f"Found {len(yaml_files)} changed YAML file(s) in git")
    elif path.is_file():
        yaml_files = [str(path)]
    else:
        yaml_files = find_yaml_files(str(path), exclude_patterns=args.exclude)

    if not yaml_files:
        if args.verbose:
            print(f"No YAML files found in {args.path}")
        sys.exit(0)

    return yaml_files


def run_yamllint(yaml_file):
    """Run yamllint on a file if available."""
    errors = []
    try:
        result = subprocess.run(
            ['yamllint', '--strict', '-d', '{extends: default, rules: {indentation: disable, document-start: disable, comments: disable, line-length: disable}}', yaml_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            check=False
        )
        if result.returncode != 0:
            for line in result.stdout.split('\n'):
                if line.strip():
                    errors.append(f"{yaml_file}: yamllint: {line.strip()}")
    except (OSError, subprocess.SubprocessError):
        # yamllint not available, skip
        pass
    return errors


def validate_single_file(yaml_file, args):
    """Validate a single YAML file and return errors."""
    file_errors = []

    # Run yamllint if requested (complements our validation)
    if args.use_yamllint:
        yamllint_errors = run_yamllint(yaml_file)
        file_errors.extend(yamllint_errors)

    # Validate YAML syntax and structure first
    if args.validate_syntax:
        syntax_errors, parsed_data = validate_yaml_syntax(yaml_file)
        file_errors.extend(syntax_errors)

        # If syntax is valid, check structure
        if not syntax_errors and parsed_data is not None:
            structure_errors = validate_yaml_structure(yaml_file, parsed_data)
            file_errors.extend(structure_errors)

    # Validate indentation
    errors, _ = validate_yaml_indentation(
        yaml_file,
        expected_width=args.width,
        strict=not args.no_strict,
        show_context=args.show_context
    )
    file_errors.extend(errors)

    return file_errors, errors


def fix_file_if_needed(yaml_file, errors, args):
    """Fix file indentation if needed and return True if fixed."""
    if not args.fix or not errors:
        return False

    # Try to fix the file (only if syntax is valid)
    if args.validate_syntax:
        syntax_errors, _ = validate_yaml_syntax(yaml_file)
        if syntax_errors:
            return False

    if fix_yaml_indentation(yaml_file, expected_width=args.width):
        if args.verbose:
            print(f"Fixed indentation in {yaml_file}")
        return True
    return False


def print_error_summary(all_errors, args):
    """Print error summary and exit with appropriate code."""
    if all_errors:
        print("ERROR: YAML indentation validation failed:", file=sys.stderr)
        print("", file=sys.stderr)
        for error in all_errors:
            print(error, file=sys.stderr)
        print("", file=sys.stderr)
        print("Common fixes:", file=sys.stderr)
        print("  - Use spaces instead of tabs for indentation", file=sys.stderr)
        print("  - Use consistent indentation width (typically 2 spaces)", file=sys.stderr)
        print("  - Remove trailing whitespace", file=sys.stderr)
        print("  - Fix YAML syntax errors (unclosed quotes, invalid characters, etc.)", file=sys.stderr)
        print("  - Check field names for typos (e.g., 'presubmit' vs 'presubmits')", file=sys.stderr)
        print("  - Verify value types match expected types (e.g., boolean vs string)", file=sys.stderr)
        if not args.fix:
            print("  - Run with --fix to automatically fix indentation issues", file=sys.stderr)
            print("  - Or run: yq eval '.' file.yaml > file.yaml.fixed && mv file.yaml.fixed file.yaml", file=sys.stderr)
        sys.exit(1)


def main():
    args = parse_arguments()
    yaml_files = get_yaml_files_to_validate(args)

    if args.verbose:
        print(f"Checking {len(yaml_files)} YAML file(s)...")

    all_errors = []
    fixed_files = []

    for yaml_file in sorted(yaml_files):
        file_errors, errors = validate_single_file(yaml_file, args)

        if fix_file_if_needed(yaml_file, errors, args):
            fixed_files.append(yaml_file)
            # Re-validate to check if issues remain
            errors, _ = validate_yaml_indentation(
                yaml_file,
                expected_width=args.width,
                strict=not args.no_strict,
                show_context=args.show_context
            )
            file_errors = [e for e in file_errors if not e.startswith(f"{yaml_file}:") or "Indentation" not in e]
            file_errors.extend(errors)

        if file_errors:
            all_errors.extend(file_errors)
            if args.verbose:
                print(f"Found {len(file_errors)} error(s) in {yaml_file}")

    if fixed_files:
        print(f"Fixed indentation in {len(fixed_files)} file(s):", file=sys.stderr)
        for f in fixed_files:
            print(f"  - {f}", file=sys.stderr)
        print("", file=sys.stderr)

    print_error_summary(all_errors, args)

    if args.verbose:
        print(f"✓ All {len(yaml_files)} YAML file(s) passed indentation validation")
    sys.exit(0)


if __name__ == '__main__':
    main()
