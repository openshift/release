#!/usr/bin/env python3

import sys
import yaml

config = {}

with open(sys.argv[1]) as raw:
    config = yaml.load(raw)


def internal_hostnames_for_cluster():
    return ["image-registry.openshift-image-registry.svc.cluster.local:5000", "image-registry.openshift-image-registry.svc:5000"]

def internal_auths_for_cluster(cluster):
    auths = []
    for hostname in internal_hostnames_for_cluster():
        auths.append({
            "item": "build_farm",
            "registry_url": hostname,
            "auth_field": "token_image-puller_{}_reg_auth_value.txt".format(cluster),
        })
    return auths


def config_for_cluster(cluster):
    return {
        "from": {
            ".dockerconfigjson": {
                "dockerconfigJSON": internal_auths_for_cluster(cluster) + [
                {
                    "item": "cloud.openshift.com-pull-secret",
                    "registry_url": "cloud.openshift.com",
                    "auth_field": "auth",
                    "email_field": "email",
                },
                {
                    "item": "quay.io-pull-secret",
                    "registry_url": "quay.io",
                    "auth_field": "auth",
                    "email_field": "email",
                },
                {
                    "item": "registry.connect.redhat.com-pull-secret",
                    "registry_url": "registry.connect.redhat.com",
                    "auth_field": "auth",
                    "email_field": "email",
                },
                {
                    "item": "registry.redhat.io-pull-secret",
                    "registry_url": "registry.redhat.io",
                    "auth_field": "auth",
                    "email_field": "email",
                },
                {
                    "item": "build_farm",
                    "registry_url": "registry.svc.ci.openshift.org",
                    "auth_field": "token_image-puller_ci_reg_auth_value.txt",
                },
                {
                    "item": "build_farm",
                    "registry_url": "registry.ci.openshift.org",
                    "auth_field": "token_image-puller_app.ci_reg_auth_value.txt",
                },
                {
                    "item": "build_farm",
                    "registry_url": "registry.arm-build01.arm-build.devcluster.openshift.com",
                    "auth_field": "token_image-puller_arm01_reg_auth_value.txt",
                },
                {
                    "item": "build_farm",
                    "registry_url": "registry.build01.ci.openshift.org",
                    "auth_field": "token_image-puller_build01_reg_auth_value.txt",
                },
                {
                    "item": "build_farm",
                    "registry_url": "registry.build02.ci.openshift.org",
                    "auth_field": "token_image-puller_build02_reg_auth_value.txt",
                },
                {
                    "item": "build_farm",
                    "registry_url": "registry.build03.ci.openshift.org",
                    "auth_field": "token_image-puller_build03_reg_auth_value.txt",
                },
                {
                    "item": "build_farm",
                    "registry_url": "registry.apps.build01-us-west-2.vmc.ci.openshift.org",
                    "auth_field": "token_image-puller_vsphere_reg_auth_value.txt",
                }],
            },
        },
        "to": [{
            "cluster": cluster,
            "namespace": "ci",
            "name": "registry-pull-credentials-all",
            "type": "kubernetes.io/dockerconfigjson",
        },
        {
            "cluster": cluster,
            "namespace": "test-credentials",
            "name": "registry-pull-credentials-all",
            "type": "kubernetes.io/dockerconfigjson",
        }],
    }

clusters = ["app.ci", "build01", "build02", "build03", "vsphere"]
configs = dict(zip(clusters, [config_for_cluster(cluster) for cluster in clusters]))
found = dict(zip(clusters, [False for cluster in clusters]))

for i, secret in enumerate(config["secret_configs"]):
    for c in configs:
        if secret["to"] == configs[c]["to"]:
            found[configs[c]["to"][0]["cluster"]] = True
            config["secret_configs"][i] = configs[c]

for c in found:
    if not found[c]:
        config["secret_configs"].append(configs[c])

with open(sys.argv[1], "w") as raw:
    yaml.dump(config, raw)
