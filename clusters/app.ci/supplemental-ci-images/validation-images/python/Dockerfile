FROM python:3.14-slim

# git is required by hack/validate-yaml-indentation.sh to determine which files
# a pull request changed.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir pyyaml ruamel.yaml pylint
