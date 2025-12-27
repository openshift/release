#!/usr/bin/env python3
"""
Resolve effective environment variables for OpenShift CI jobs.
Handles recursive resolution of steps, chains, and workflows with override tracking.
"""

import argparse
import json
import os
import sys
import yaml
from pathlib import Path
from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass
from enum import IntEnum


class Priority(IntEnum):
    """Environment variable priority levels (lower number = higher priority)"""
    CONFIG = 1
    WORKFLOW = 2
    CHAIN = 3
    STEP = 4


@dataclass
class EnvVar:
    """Environment variable with source tracking"""
    name: str
    value: str
    source: Priority
    source_file: str
    default_value: Optional[str] = None


class EffectiveEnvResolver:
    """Resolves effective environment variables for CI jobs"""

    def __init__(self, repo_root: str):
        self.repo_root = Path(repo_root)
        self.step_registry_dir = self.repo_root / "ci-operator" / "step-registry"
        self.env_map: Dict[str, EnvVar] = {}
        self.visited_components = set()

    def find_registry_file(self, filename: str) -> Optional[Path]:
        """Find a file in the step registry"""
        results = list(self.step_registry_dir.rglob(filename))
        return results[0] if results else None

    def add_env_var(self, name: str, value: str, source: Priority, source_file: str, is_default: bool = False):
        """
        Add environment variable to map following override rules:
        - If name not in map: add it
        - If name exists with lower priority (higher number): override it
        - Always track default values from steps
        """
        if name not in self.env_map:
            # New variable
            self.env_map[name] = EnvVar(name, value, source, source_file)
            if is_default:
                self.env_map[name].default_value = value
        elif self.env_map[name].source > source:
            # Higher priority override (lower priority number wins)
            old_default = self.env_map[name].default_value
            self.env_map[name] = EnvVar(name, value, source, source_file, old_default)
        elif is_default and self.env_map[name].default_value is None:
            # Record default value even if variable is already set
            self.env_map[name].default_value = value

    def extract_job_env(self, config_file: Path, job_name: str) -> Dict[str, str]:
        """Extract environment variables from job config"""
        with open(config_file) as f:
            config = yaml.safe_load(f)

        for test in config.get('tests', []):
            if test.get('as') == job_name:
                return test.get('steps', {}).get('env', {}) or {}
        return {}

    def extract_workflow_name(self, config_file: Path, job_name: str) -> Optional[str]:
        """Extract workflow name from job config"""
        with open(config_file) as f:
            config = yaml.safe_load(f)

        for test in config.get('tests', []):
            if test.get('as') == job_name:
                return test.get('steps', {}).get('workflow')
        return None

    def get_workflow_env(self, workflow_name: str) -> Dict[str, str]:
        """Get environment variables from workflow"""
        workflow_file = self.find_registry_file(f"{workflow_name}-workflow.yaml")
        if not workflow_file or not workflow_file.exists():
            return {}

        with open(workflow_file) as f:
            workflow = yaml.safe_load(f)
        return workflow.get('workflow', {}).get('steps', {}).get('env', {}) or {}

    def get_workflow_steps(self, workflow_name: str, phase: str) -> List[Tuple[str, str]]:
        """Get steps from workflow phase (pre/test/post)"""
        workflow_file = self.find_registry_file(f"{workflow_name}-workflow.yaml")
        if not workflow_file or not workflow_file.exists():
            return []

        with open(workflow_file) as f:
            workflow = yaml.safe_load(f)

        phase_steps = workflow.get('workflow', {}).get('steps', {}).get(phase, []) or []
        result = []
        for step in phase_steps:
            step_name = step.get('chain') or step.get('ref')
            step_as = step.get('as', step_name)
            if step_name:
                result.append((step_name, step_as))
        return result

    def get_chain_env(self, chain_name: str) -> Dict[str, str]:
        """Get environment variables from chain"""
        chain_file = self.find_registry_file(f"{chain_name}-chain.yaml")
        if not chain_file or not chain_file.exists():
            return {}

        with open(chain_file) as f:
            chain = yaml.safe_load(f)

        env_list = chain.get('chain', {}).get('env', []) or []
        return {item['name']: item.get('default', '') for item in env_list if 'name' in item}

    def get_chain_steps(self, chain_name: str) -> List[Tuple[str, str]]:
        """Get steps from chain"""
        chain_file = self.find_registry_file(f"{chain_name}-chain.yaml")
        if not chain_file or not chain_file.exists():
            return []

        with open(chain_file) as f:
            chain = yaml.safe_load(f)

        steps = chain.get('chain', {}).get('steps', []) or []
        result = []
        for step in steps:
            step_name = step.get('chain') or step.get('ref')
            step_as = step.get('as', step_name)
            if step_name:
                result.append((step_name, step_as))
        return result

    def get_step_env(self, step_name: str) -> Dict[str, str]:
        """Get environment variables from step (ref)"""
        step_file = self.find_registry_file(f"{step_name}-ref.yaml")
        if not step_file or not step_file.exists():
            return {}

        with open(step_file) as f:
            step = yaml.safe_load(f)

        env_list = step.get('ref', {}).get('env', []) or []
        return {item['name']: item.get('default', '') for item in env_list if 'name' in item}

    def resolve_component(self, component_name: str, component_type: str, priority: Priority):
        """
        Recursively resolve environment variables from a component.

        The algorithm processes components in order (pre -> test -> post for workflows,
        sequential for chains) and adds variables to the env_map only if they don't
        already exist with higher priority.
        """
        visit_key = f"{component_type}:{component_name}"
        if visit_key in self.visited_components:
            return
        self.visited_components.add(visit_key)

        if component_type == 'workflow':
            # Add workflow env vars
            env_vars = self.get_workflow_env(component_name)
            for name, value in env_vars.items():
                self.add_env_var(name, value, priority, f"{component_name}-workflow.yaml")

            # Process workflow phases in order: pre -> test -> post
            for phase in ['pre', 'test', 'post']:
                for step_name, step_as in self.get_workflow_steps(component_name, phase):
                    # Check if it's a chain or step
                    if self.find_registry_file(f"{step_name}-chain.yaml"):
                        self.resolve_component(step_name, 'chain', Priority.CHAIN)
                    elif self.find_registry_file(f"{step_name}-ref.yaml"):
                        self.resolve_component(step_name, 'ref', Priority.STEP)

        elif component_type == 'chain':
            # Add chain env vars
            env_vars = self.get_chain_env(component_name)
            for name, value in env_vars.items():
                self.add_env_var(name, value, priority, f"{component_name}-chain.yaml")

            # Process chain steps in order
            for step_name, step_as in self.get_chain_steps(component_name):
                if self.find_registry_file(f"{step_name}-chain.yaml"):
                    self.resolve_component(step_name, 'chain', Priority.CHAIN)
                elif self.find_registry_file(f"{step_name}-ref.yaml"):
                    self.resolve_component(step_name, 'ref', Priority.STEP)

        elif component_type == 'ref':
            # Add step env vars (these are defaults)
            env_vars = self.get_step_env(component_name)
            for name, value in env_vars.items():
                self.add_env_var(name, value, priority, f"{component_name}-ref.yaml", is_default=True)

    def resolve(self, config_file: Path, job_name: str) -> bool:
        """
        Resolve all environment variables for a job.

        Resolution order (bottom-up in terms of processing, but top-down for priority):
        1. Process workflow and all its dependencies (collects all possible vars)
        2. Apply job config overrides (highest priority - these always win)

        The add_env_var method ensures proper override behavior.
        """
        # Reset state
        self.env_map = {}
        self.visited_components = set()

        # Extract workflow name
        workflow_name = self.extract_workflow_name(config_file, job_name)
        if not workflow_name:
            print(f"Warning: Job '{job_name}' in {config_file} has no workflow", file=sys.stderr)
            return False

        # Step 1: Resolve workflow and all dependencies
        # This processes: workflow env -> chains -> steps (in execution order)
        self.resolve_component(workflow_name, 'workflow', Priority.WORKFLOW)

        # Step 2: Apply job config overrides (highest priority)
        job_env = self.extract_job_env(config_file, job_name)
        for name, value in job_env.items():
            self.add_env_var(name, value, Priority.CONFIG, config_file.name)

        return True

    def output_json(self, config_file: Path, job_name: str, filter_str: Optional[str] = None):
        """Output environment variables in JSON format"""
        # Extract version from filename
        filename = config_file.name
        if 'release-' in filename:
            version = filename.split('release-')[1].split('.yaml')[0].split('__')[0]
        else:
            version = 'main/master'

        workflow_name = self.extract_workflow_name(config_file, job_name)

        # Filter environment variables
        filtered_vars = []
        for name in sorted(self.env_map.keys()):
            if filter_str and filter_str.lower() not in name.lower():
                continue

            env_var = self.env_map[name]
            is_overridden = (env_var.default_value and
                           env_var.value != env_var.default_value and
                           env_var.source < Priority.STEP)

            filtered_vars.append({
                'name': name,
                'value': env_var.value,
                'source': env_var.source.name.lower(),
                'source_file': env_var.source_file,
                'default_value': env_var.default_value,
                'is_overridden': is_overridden
            })

        # Build overrides list
        overrides = []
        for var in filtered_vars:
            if var['is_overridden']:
                overrides.append({
                    'name': var['name'],
                    'value': var['value'],
                    'source': var['source'],
                    'default_value': var['default_value']
                })

        # Build JSON output
        output = {
            'job_name': job_name,
            'config_file': str(config_file.relative_to(self.repo_root)),
            'version': version,
            'workflow': workflow_name,
            'filter': filter_str,
            'total_count': len(self.env_map),
            'filtered_count': len(filtered_vars),
            'env_vars': filtered_vars,
            'overrides': overrides
        }

        print(json.dumps(output, indent=2))


def main():
    parser = argparse.ArgumentParser(
        description='Resolve effective environment variables for OpenShift CI jobs (JSON output)'
    )
    parser.add_argument('config_file', help='Path to CI config YAML file')
    parser.add_argument('job_name', help='Job name (value in "as" field)')
    parser.add_argument('--filter', help='Filter environment variable names (case insensitive)')
    parser.add_argument('--repo-root', help='Repository root directory',
                       default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

    args = parser.parse_args()

    config_file = Path(args.config_file).resolve()
    if not config_file.exists():
        print(f"Error: Config file not found: {config_file}", file=sys.stderr)
        sys.exit(1)

    resolver = EffectiveEnvResolver(args.repo_root)

    if resolver.resolve(config_file, args.job_name):
        resolver.output_json(config_file, args.job_name, args.filter)
    else:
        sys.exit(1)


if __name__ == '__main__':
    main()
