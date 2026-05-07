#!/usr/bin/env python3
"""
Script to find jobs that mount "gcs-credentials" volumes but are missing proper volume declarations.
"""

import os
import yaml
import sys

def check_file_for_volume_issues(filepath):
    """Check a single YAML file for gcs-credentials volume mount/declaration mismatches."""
    issues = []
    
    try:
        with open(filepath, 'r') as f:
            content = yaml.safe_load(f)
    except Exception as e:
        print(f"Error reading {filepath}: {e}")
        return []
    
    if not content:
        return []
    
    # Find all job specifications (presubmits, postsubmits, periodics)
    job_types = ['presubmits', 'postsubmits', 'periodics']
    
    for job_type in job_types:
        if job_type in content:
            repos = content[job_type]
            if isinstance(repos, dict):
                for repo_name, jobs in repos.items():
                    if isinstance(jobs, list):
                        job_list = jobs
                    else:
                        continue
                        
                    for job in job_list:
                        if 'spec' not in job or 'containers' not in job['spec']:
                            continue
                        
                        job_name = job.get('name', 'unnamed')
                        
                        # Check each container in the job spec
                        for container_idx, container in enumerate(job['spec']['containers']):
                            if 'volumeMounts' not in container:
                                continue
                            
                            # Find gcs-credentials volume mounts
                            gcs_volume_mounts = []
                            for mount in container['volumeMounts']:
                                if mount.get('name') == 'gcs-credentials':
                                    gcs_volume_mounts.append(mount)
                            
                            if not gcs_volume_mounts:
                                continue  # No gcs-credentials mounts in this container
                            
                            # Check if corresponding volume declaration exists
                            volumes = job['spec'].get('volumes', [])
                            gcs_volume_declared = False
                            for volume in volumes:
                                if volume.get('name') == 'gcs-credentials':
                                    gcs_volume_declared = True
                                    break
                            
                            if not gcs_volume_declared:
                                issues.append({
                                    'file': filepath,
                                    'job_name': job_name,
                                    'job_type': job_type,
                                    'repo': repo_name,
                                    'container_index': container_idx,
                                    'mount_paths': [mount.get('mountPath', 'unknown') for mount in gcs_volume_mounts],
                                    'issue': 'gcs-credentials volume mount found but no corresponding volume declaration'
                                })
    
    return issues

def main():
    """Main function to check all job files."""
    jobs_dir = "/home/sninganu/prow_NPT/release/ci-operator/jobs"
    all_issues = []
    
    # Walk through all job files
    for root, dirs, files in os.walk(jobs_dir):
        for file in files:
            if file.endswith('.yaml'):
                filepath = os.path.join(root, file)
                issues = check_file_for_volume_issues(filepath)
                all_issues.extend(issues)
    
    # Print results
    if not all_issues:
        print("No issues found! All gcs-credentials volume mounts have corresponding volume declarations.")
        return 0
    
    print(f"Found {len(all_issues)} jobs with missing gcs-credentials volume declarations:\n")
    
    for issue in all_issues:
        print(f"File: {issue['file']}")
        print(f"  Job: {issue['job_name']} ({issue['job_type']})")
        print(f"  Repository: {issue['repo']}")
        print(f"  Container: {issue['container_index']}")
        print(f"  Mount paths: {', '.join(issue['mount_paths'])}")
        print(f"  Issue: {issue['issue']}")
        print()
    
    # Group by file for summary
    files_with_issues = {}
    for issue in all_issues:
        filepath = issue['file']
        if filepath not in files_with_issues:
            files_with_issues[filepath] = []
        files_with_issues[filepath].append(issue['job_name'])
    
    print(f"\nSummary: {len(files_with_issues)} files with issues:")
    for filepath, job_names in files_with_issues.items():
        print(f"  {filepath}: {len(job_names)} jobs")
    
    return 1

if __name__ == "__main__":
    sys.exit(main())