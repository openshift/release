#!/usr/bin/env python3

import os
import sys
import glob
import shutil
import ruamel.yaml as yaml

APPCI_REGISTRY = "registry.ci.openshift.org"
MAPPING_FILE_PREFIX = "mapping_"
DIR_PATH = "core-services/image-mirroring"
PERIODICS_FILE = "ci-operator/jobs/infra-image-mirroring-multi-arch.yaml"
ARCHITECTURES = {
    "arm64": "linux/arm64",
}

OWNERS = """approvers:
  - dptp
"""

README = """This folder holds the mappings of the image mirroring for the multi architecture.

Note that this folder is automatically generated.
"""


def generate_job(arch, os_filter):
    return f"""
agent: kubernetes
cluster: app.ci
cron: '@daily'
decorate: true
extra_refs:
- base_ref: master
  org: openshift
  repo: release
  workdir: true
labels:
  ci.openshift.io/area: supplemental-ci-images-{arch}
  ci.openshift.io/role: infra
name: periodic-image-mirroring-supplemental-ci-images-{arch}
spec:
  containers:
  - args:
    - --skip-missing=true
    - --filter-by-os={os_filter}
    - --skip-multiple-scopes
    command:
    - hack/image-mirroring/mirror-images.sh
    env:
    - name: ARCH
      value: {arch}
    - name: HOME
      value: /home/mirror
    image: registry.ci.openshift.org/ocp/4.12:cli
    imagePullPolicy: Always
    name: ""
    resources:
      requests:
        cpu: 500m
    volumeMounts:
    - mountPath: /home/mirror/.docker/config.json
      name: push
      readOnly: true
      subPath: .dockerconfigjson
  volumes:
  - name: push
    secret:
      secretName: registry-push-credentials-ci-central
"""


def generate_mappings():
    print("Removing all core-services/image-mirroring-* directories")
    for path in glob.glob('core-services/image-mirroring-*', recursive=False):
        try:
            shutil.rmtree(path, ignore_errors=False, onerror=None)
        except OSError as error:
            print(f"Error while deleting file {path}: {error}")

    for root, dirs, files in os.walk(DIR_PATH):
        if len(dirs) > 0:
            continue

        for name in files:
            if not name.startswith(MAPPING_FILE_PREFIX):
                continue
            filename = f"{root}/{name}"

            with open(filename, 'r', encoding="utf-8") as file:
                lines = file.readlines()
                for line in lines:
                    line = line.strip()
                    if len(line.strip()) == 0:
                        continue
                    # Ignore commented lines or if the mapping source is registry.ci.openshift.org
                    # to avoid mirroring from app.ci to an external source
                    if line.startswith("#") or line.startswith(APPCI_REGISTRY):
                        continue

                    source, dest = line.split()

                    if not dest.startswith(APPCI_REGISTRY):
                        # Since we already ignore lines that source is registry.ci.openshift.org,
                        # therefore the destination should be registry.ci.openshift.org, otherwise there
                        # is no point for the mapping to exist. That should be validated before we hit it here.
                        # Either way, it is good to have the check in this script, just in case....
                        print("BUG: where are we mirroring to?")
                        sys.exit(1)

                    for arch in ARCHITECTURES:
                        to_write_directory = f"{DIR_PATH}-{arch}"
                        if not os.path.exists(to_write_directory):
                            os.makedirs(to_write_directory)
                            generate_owners(to_write_directory)
                            generate_readme(to_write_directory)

                        to_write = f"{to_write_directory}/{name}"

                        _, namespace, image_name = dest.split("/")
                        namespace = f"{namespace}-{arch}"

                        new_dest = f"{APPCI_REGISTRY}/{namespace}/{image_name}"

                        print(f"Writing to {to_write}")
                        with open(to_write, 'a+', encoding="utf-8") as f:
                            f.write(f"{source} {new_dest}\n")


def generate_periodics():
    jobs = []
    for arch, os_filter in ARCHITECTURES.items():
        jobs.append(yaml.round_trip_load(generate_job(
            arch, os_filter), preserve_quotes=True))

    print(f"Generate periodics in {PERIODICS_FILE}")
    with open(PERIODICS_FILE, 'w', encoding="utf-8") as file:
        periodics = {"periodics": jobs}
        yaml.round_trip_dump(periodics, file, indent=2,
                             default_flow_style=False, explicit_start=False)


def generate_owners(path):
    with open(os.path.join(path, "OWNERS"), 'w', encoding="utf-8") as file:
        file.write(OWNERS)


def generate_readme(path):
    with open(os.path.join(path, "README.md"), 'w', encoding="utf-8") as file:
        file.write(README)


if __name__ == "__main__":
    generate_mappings()
    generate_periodics()
