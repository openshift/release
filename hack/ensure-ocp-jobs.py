import argparse
import random

# pylint: disable=W0511
# TODO(muller): Switch to ruamel after https://github.com/openshift/release/pull/17710 lands
# import ruamel.yaml
import yaml


def main():
    # yaml = ruamel.yaml.YAML(typ='rt')
    yaml.preserve_quotes = True
    parser = argparse.ArgumentParser()
    parser.add_argument('--org', default="openshift")
    parser.add_argument('--repo')
    parser.add_argument('--no-e2e', dest="noe2e", default=False, action='store_true')
    parser.add_argument('--no-serial', dest="noserial", default=False, action='store_true')
    parser.add_argument('--no-upgrade', dest="noupgrade", default=False, action='store_true')
    parser.add_argument('--platform', choices=("agnostic", "aws", "gcp", "azure", 'vsphere'), default="agnostic")
    args = parser.parse_args()

    random.seed(f"{args.org}-{args.repo}")
    if args.platform == "agnostic":
        platform = random.choice(("aws", "gcp", "azure"))
    else:
        platform = args.platform

    if platform == "azure":
        cp = "azure4"
    else:
        cp = platform

    with open(f'ci-operator/config/{args.org}/{args.repo}/{args.org}-{args.repo}-master.yaml') as file:
        ciop_cfg = yaml.load(file)

    if "tests" not in ciop_cfg:
        ciop_cfg["tests"] = []

    if not args.noe2e:
        ciop_cfg["tests"].append(
            {
                "as": f"e2e-{args.platform}",
                "steps": {
                    "cluster_profile": cp,
                    "workflow": f"openshift-e2e-{platform}"
                }
            }
        )

    if not args.noserial:
        ciop_cfg["tests"].append(
            {
                "as": f"e2e-{args.platform}-serial",
                "steps": {
                    "cluster_profile": cp,
                    "workflow": f"openshift-e2e-{platform}-serial"
                }
            }
        )

    if not args.noupgrade:
        ciop_cfg["tests"].append(
            {
                "as": f"e2e-{args.platform}-upgrade",
                "steps": {
                    "cluster_profile": cp,
                    "workflow": f"openshift-upgrade-{platform}"
                }
            }
        )

    with open(f'ci-operator/config/{args.org}/{args.repo}/{args.org}-{args.repo}-master.yaml', "w") as file:
        yaml.dump(ciop_cfg, file)


if __name__ == "__main__":
    main()
