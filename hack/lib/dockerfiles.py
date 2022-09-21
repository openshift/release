import json, sys, yaml, os;

def branch_to_stream(branch, variant):
  if branch == "master":
    if variant == "rhel":
      return ("ocp", "4.0")
    return ("openshift", "origin-v4.0")
  if branch.startswith("release-"):
    version = branch[len("release-"):]
    if variant == "rhel":
      return ("ocp", version)
    return ("openshift", "origin-v"+version)

def branch_tag_spec(existing, branch, variant):
  ns, name = branch_to_stream(branch, variant)
  existing["namespace"] = ns
  existing["name"] = name
  return existing

def branch_to_builder(existing, variant):
  if existing:
    if variant == "rhel":
      existing["namespace"] = "ocp"
      existing["name"] = "builder"
  return existing

base = sys.argv[1]
for root, dirs, files in os.walk(base):
  rel = root[len(base):]
  parts = rel.split("/")
  repo_prefix = "-".join(parts[:len(parts)]) + "-"
  if len(parts) > 1:
    org, repo = parts[0], parts[1]
  last = parts[len(parts)-1]
  for name in files:
    filename, ext = os.path.splitext(name)
    if ext != ".yaml":
      continue
    if not filename.startswith(repo_prefix):
      continue
    branch_modifier = filename[len(repo_prefix):]
    parts = branch_modifier.split("_")
    if len(parts) > 1:
      branch, variant = parts
    else:
      branch, variant = branch_modifier, ""

    if branch != "master":
      continue

    if variant != "":
      continue

    new_cfg = {"images": []}
    cfg = yaml.load(open(os.path.join(root, name)))

    if not "images" in cfg:
      #print("no images: %s %s %s %s" % (org, repo, branch, variant))
      continue
    if not "tag_specification" in cfg:
      continue
    if not ("build_root" in cfg and "image_stream_tag" in cfg["build_root"]):
      continue

    spec = cfg["tag_specification"]
    if spec["namespace"] != "openshift" or not spec["name"].startswith("origin-"):
      continue
    spec.pop("cluster", "")
    new_cfg["tag_specification"] = branch_tag_spec(spec, branch, "rhel")

    builder = cfg["build_root"]["image_stream_tag"]
    if builder["tag"] != "golang-1.10":
      continue
    builder = branch_to_builder(builder, "rhel")
    builder.pop("cluster", "")
    new_cfg["build_root"] = {"image_stream_tag": builder}
    new_cfg["resources"] = cfg["resources"]

    if "canonical_go_repository" not in cfg:
      cfg["canonical_go_repository"] = "github.com/%s/%s" % (org, repo)
    new_cfg["canonical_go_repository"] = cfg["canonical_go_repository"]

    for image in cfg["images"]:
      if "optional" in image:
        continue
      if not "dockerfile_path" in image:
        image["dockerfile_path"] = "Dockerfile"
      image.pop("inputs", "")

      if "context_dir" in image:
        src_dockerfile = os.path.join(org, repo, image["context_dir"], image["dockerfile_path"])
      else:
        src_dockerfile = os.path.join(org, repo, image["dockerfile_path"])        

      image_from = image["from"]
      if "base_images" in cfg and image_from in cfg["base_images"]:
        base_image = cfg["base_images"][image_from]
        if "base_images" not in new_cfg:
          new_cfg["base_images"] = {}
        new_cfg["base_images"][image_from] = branch_tag_spec(base_image, branch, "rhel")
      else:
        base_image = branch_tag_spec({"tag": image_from}, branch, "rhel")
      base_image.pop("cluster", "")
      image["dockerfile_path"] += ".rhel7"

      if len(sys.argv) > 2:
        if not os.path.isfile(os.path.join(sys.argv[2], src_dockerfile)):
          continue
        # if os.path.isfile(os.path.join(sys.argv[2], src_dockerfile + ".rhel7")):
        #   continue

        existing = open(os.path.join(sys.argv[2], src_dockerfile)).readlines()
        lines = ["%s" % line for line in existing]
        extra = [
          "",
          "FROM registry.ci.openshift.org/%s/%s:%s AS builder" % (builder["namespace"], builder["name"], builder["tag"]),
          "WORKDIR /go/src/%s" % cfg["canonical_go_repository"],
          "COPY . .",
          "RUN # go build -o BINARY ./PATH",
          "",
          "FROM registry.ci.openshift.org/%s/%s:%s" % (base_image["namespace"], base_image["name"], base_image["tag"]),
          "RUN INSTALL_PKGS=\" \\",
          "      \\",
          "      \" && \\",
          "    yum install -y $INSTALL_PKGS && \\",
          "    rpm -V $INSTALL_PKGS && \\",
          "    yum clean all",
          "COPY --from=builder # ./BINARY /usr/bin/BINARY",
        ]
        lines += [line + "\n" for line in extra]

        with open(os.path.join(sys.argv[2], src_dockerfile + ".rhel7"), 'w') as f:
          f.write("".join(lines))
          f.close()
        #print("".join(lines))

      new_cfg["images"].append(image)

    if len(new_cfg["images"]) == 0:
      continue

    print("%s %s %s %s:" % (org, repo, branch, variant))
    out = yaml.dump(new_cfg, default_flow_style=False)
    with open(os.path.join(base, org, repo, "%s-%s-%s_%s.yaml" % (org, repo, branch, "rhel")), 'w') as f:
      f.write(out)
      f.close
