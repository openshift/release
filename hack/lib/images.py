import json, sys, yaml, os;

base = sys.argv[1]
target_branch = sys.argv[2] if len(sys.argv) > 2 else "master"

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

    if branch != target_branch:
      continue

    if variant != "":
      continue

    cfg = yaml.load(open(os.path.join(root, name)))
    spec = cfg.get("tag_specification", {})
    if spec.get("name", "") != "origin-v4.0":
      continue

    for image in cfg.get("images", []):
      if image.get("optional", False):
        continue
      print("github.com/%s/%s: name=%s context=%s path=%s" % (org, repo, image["to"], image.get("context_dir", ""), image.get("dockerfile_path", "Dockerfile")))
