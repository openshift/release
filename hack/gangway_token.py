#!/usr/bin/env python3
import argparse
import os

def build_yaml(group_name: str) -> str:
    return f"""apiVersion: v1
kind: Namespace
metadata:
  name: {group_name}
  annotations:
    openshift.io/description: Service Accounts for {group_name}
    openshift.io/display-name: {group_name} CI
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: periodic-job-bot
  namespace: {group_name}
---
apiVersion: v1
kind: Secret
metadata:
  name: api-token-secret
  namespace: {group_name}
  annotations:
    kubernetes.io/service-account.name: periodic-job-bot
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-owner
  namespace: {group_name}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["api-token-secret"]
    verbs:
      - get
      - create
      - update
      - patch
      - delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: secret-owner-{group_name}
  namespace: {group_name}
subjects:
  - kind: Group
    apiGroup: rbac.authorization.k8s.io
    name: {group_name}
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: secret-owner
"""

def main():
    parser = argparse.ArgumentParser(description="Generate Openshift YAML for gangway token owner setup.")
    parser.add_argument("-g", "--group", dest="group", required=True, help="Name of the group/namespace (e.g. logging-qe)")
    parser.add_argument("-o", "--output", default=None, help="Output file path (defaults to clusters/app.ci/gangway-tokens/{group}/admin_rbac.yaml)")
    args = parser.parse_args()

    group = args.group
    repo_root = os.getcwd()

    if args.output:
        out_path = args.output
    else:
        out_dir = os.path.join(repo_root, "clusters", "app.ci", "gangway-tokens", group)
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, "admin_rbac.yaml")

    yaml_content = build_yaml(group)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(yaml_content)
    print(f"Generated YAML file at: {out_path}")

    gangway_path = os.path.join(repo_root, "clusters", "app.ci", "prow", "03_deployment", "gangway.yaml")
    entry = (
        f"  - kind: ServiceAccount\n"
        f"    namespace: {group}\n"
        f"    name: periodic-job-bot\n"
    )

    if os.path.exists(gangway_path):
        with open(gangway_path, 'r', encoding="utf-8") as gw_file:
            content = gw_file.read()

        if f"namespace: {group}" in content:
            print(f"Entry for namespace '{group}' already exists in: {gangway_path}. Skipping append.")
        else:
            with open(gangway_path, "a", encoding="utf-8") as gw_file:
                gw_file.write(entry)
            print(f"Appended ServiceAccount entry to: {gangway_path}")
    else:
        print(f"Warning: {gangway_path} not found. Skipping append step.")

if __name__ == "__main__":
    main()
